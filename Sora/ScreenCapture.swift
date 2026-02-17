import CoreMedia
import Foundation
import ReplayKit

/// 画面キャプチャの設定です。
public struct ScreenCaptureSettings {
  /// ReplayKit のマイク入力を有効化するかどうか。
  /// 既定値は `false` です。
  public var isMicrophoneEnabled: Bool

  /// ReplayKit のカメラ入力を有効化するかどうか。
  /// 既定値は `false` です。
  public var isCameraEnabled: Bool

  /// 映像フレーム送信前に `CMSampleBuffer` を加工するためのクロージャーです。
  /// `nil` を返すと該当フレームを破棄します。
  public var videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?

  /// 画面キャプチャ実行中に発生したエラー通知コールバックです。
  public var onRuntimeError: ((Error) -> Void)?

  /// 初期化します。
  ///
  /// - Parameters:
  ///   - isMicrophoneEnabled: ReplayKit のマイク入力を有効化するかどうか
  ///   - isCameraEnabled: ReplayKit のカメラ入力を有効化するかどうか
  ///   - videoSampleBufferTransformer: 映像フレーム送信前の加工処理
  ///   - onRuntimeError: 画面キャプチャ実行中エラーの通知コールバック
  public init(
    isMicrophoneEnabled: Bool = false,
    isCameraEnabled: Bool = false,
    videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil,
    onRuntimeError: ((Error) -> Void)? = nil
  ) {
    self.isMicrophoneEnabled = isMicrophoneEnabled
    self.isCameraEnabled = isCameraEnabled
    self.videoSampleBufferTransformer = videoSampleBufferTransformer
    self.onRuntimeError = onRuntimeError
  }
}

// スクリーンキャプチャーのコントローラークラスです。
// 内部でロックと専用キューにより排他制御を行うため、 @unchecked Sendable を付与します。
final class ScreenCaptureController: @unchecked Sendable {
  // キャプチャー状況の列挙型
  private enum CaptureState {
    case stopped
    case starting
    case running
    case stopping
  }

  private struct CaptureContext {
    let senderStream: MediaStream
    let videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?
  }

  private weak var mediaChannel: MediaChannel?
  // ReplayKit のレコーダーです
  private let recorder = RPScreenRecorder.shared()
  // 画面フレームを順序保証して送信するためのキュー
  private let sendVideoFrameQueue = DispatchQueue(
    label: "jp.shiguredo.sora.screenCapture.sendVideoFrameQueue")
  // 画面フレーム送信を常に1件だけに限定するためのセマフォ
  private let sendVideoFrameSemaphore = DispatchSemaphore(value: 1)
  private let lock = NSLock()

  private var captureState: CaptureState = .stopped
  private var settings = ScreenCaptureSettings()
  private var senderStream: MediaStream?
  // startCapture の非同期完了を世代管理するための ID です。
  // start/stop が前後したときに、古い start 完了コールバックを無効化します。
  private var captureID: UInt64 = 0
  private var activeCaptureID: UInt64?

  init(mediaChannel: MediaChannel) {
    self.mediaChannel = mediaChannel
  }

  // 画面キャプチャを開始します
  func startCapture(settings: ScreenCaptureSettings, senderStream: MediaStream) async throws {
    let captureID = try beginStartCapture(settings: settings, senderStream: senderStream)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      Task { @MainActor in
        self.recorder.isMicrophoneEnabled = settings.isMicrophoneEnabled
        self.recorder.isCameraEnabled = settings.isCameraEnabled
        self.recorder.startCapture(
          handler: { [weak self] sampleBuffer, sampleBufferType, error in
            self?.handleSampleBuffer(
              sampleBuffer: sampleBuffer,
              sampleBufferType: sampleBufferType,
              error: error
            )
          },
          completionHandler: { [weak self] error in
            guard let self else {
              continuation.resume(
                throwing: SoraError.mediaChannelError(
                  reason: "ScreenCaptureController is unavailable"
                )
              )
              return
            }

            switch self.completeStartCapture(captureID: captureID, error: error) {
            case .success:
              continuation.resume(returning: ())
            case .failed(let error):
              continuation.resume(throwing: error)
            case .cancelled:
              Task { [weak self] in
                await self?.stopCapture()
              }
              continuation.resume(
                throwing: SoraError.mediaChannelError(reason: "screen capture start was cancelled")
              )
            }
          })
      }
    }
  }

  // 画面キャプチャを停止します
  func stopCapture() async {
    guard beginStopCapture() else {
      return
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      Task { @MainActor in
        self.recorder.stopCapture { _ in
          self.withLock {
            self.captureState = .stopped
          }
          continuation.resume(returning: ())
        }
      }
    }
  }

  // 切断時に呼び出される stopCapture です。
  // 呼び出し元で完了待ちをする必要はありません。
  func stopCaptureForDisconnect() {
    Task { [weak self] in
      await self?.stopCapture()
    }
  }

  // MARK: - Private

  private enum StartCaptureResult {
    case success
    case failed(Error)
    case cancelled
  }

  private func withLock<T>(_ block: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try block()
  }

  // startCapture 前に state チェック、更新を行います
  private func beginStartCapture(settings: ScreenCaptureSettings, senderStream: MediaStream) throws
    -> UInt64
  {
    try withLock {
      switch captureState {
      case .running:
        throw SoraError.mediaChannelError(reason: "screen capture is already running")
      case .starting, .stopping:
        throw SoraError.mediaChannelError(reason: "screen capture operation is in progress")
      case .stopped:
        captureID += 1
        activeCaptureID = captureID
        self.settings = settings
        self.senderStream = senderStream
        captureState = .starting
        return captureID
      }
    }
  }

  // startCapture のコールバックが返ってきた後に state 更新等を行います
  private func completeStartCapture(captureID: UInt64, error: Error?) -> StartCaptureResult {
    withLock {
      // startCapture 終了前に stopCapture が実行された場合はキャンセルします
      // この時 activeCaptureID は nil となっています
      guard activeCaptureID == captureID else {
        return .cancelled
      }

      if let error {
        captureState = .stopped
        senderStream = nil
        activeCaptureID = nil
        return .failed(error)
      }

      captureState = .running
      return .success
    }
  }

  // stopCapture 実行前に state チェック等を行います
  private func beginStopCapture() -> Bool {
    withLock {
      switch captureState {
      case .stopped, .stopping:
        return false
      case .starting, .running:
        captureState = .stopping
        senderStream = nil
        activeCaptureID = nil
        return true
      }
    }
  }

  // キャプチャーした画面フレームを映像フレームに変換してストリーム送出します
  // sendVideoFrameQueue でフレームの順序保証して送信します
  // またキューが詰まるとメモリ使用量と遅延が増加していくため、sendVideoFrameSemaphore で
  // 同時に処理できるフレームを1件に限定し、詰まったら待たずに破棄するようにしています。
  private func handleSampleBuffer(
    sampleBuffer: CMSampleBuffer,
    sampleBufferType: RPSampleBufferType,
    error: Error?
  ) {
    if let error {
      let onRuntimeError = withLock { settings.onRuntimeError }
      onRuntimeError?(error)
      return
    }

    guard sampleBufferType == .video else {
      return
    }

    guard let context = captureContext() else {
      return
    }

    // 即取得できなければフレーム詰まりを回避するためにこのフレームは破棄します
    guard sendVideoFrameSemaphore.wait(timeout: .now()) == .success else {
      return
    }
    sendVideoFrameQueue.async { [weak self] in
      // sendVideoFrameSemaphore カウントを -1 して次のフレームを処理できるようにします
      defer { self?.sendVideoFrameSemaphore.signal() }

      // 非同期 stopCapture で captureState が変更される可能性があるためここでチェックします
      guard let self, self.isReadyToSend() else {
        return
      }

      var sampleBufferToSend = sampleBuffer
      if let transformedBuffer = context.videoSampleBufferTransformer?(sampleBuffer) {
        sampleBufferToSend = transformedBuffer
      } else if context.videoSampleBufferTransformer != nil {
        return
      }

      guard let videoFrame = VideoFrame(from: sampleBufferToSend) else {
        return
      }

      context.senderStream.send(videoFrame: videoFrame)
    }
  }

  private func captureContext() -> CaptureContext? {
    withLock {
      guard captureState == .running else {
        return nil
      }
      guard let senderStream else {
        return nil
      }
      return CaptureContext(
        senderStream: senderStream,
        videoSampleBufferTransformer: settings.videoSampleBufferTransformer
      )
    }
  }

  // ストリーム送出できる状態かチェックします
  private func isReadyToSend() -> Bool {
    withLock {
      guard captureState == .running else {
        return false
      }
      guard mediaChannel?.state == .connected else {
        return false
      }
      return true
    }
  }
}
