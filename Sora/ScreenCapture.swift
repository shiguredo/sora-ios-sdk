import CoreMedia
import Foundation
import ReplayKit

/// 画面キャプチャの設定です。
public struct ScreenCaptureSettings {
  /// 送信する映像フレームレートの目標値です。
  /// 1 以上を指定します。入力フレームが高頻度な場合は古いフレームを間引きます。
  /// 既定値は `15` です。
  public var targetFPS: Int

  /// 映像フレーム送信前に `CMSampleBuffer` を加工するためのクロージャーです。
  /// `nil` を返すと該当フレームを破棄します。
  public var videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?

  /// 画面キャプチャ実行中に発生したエラー通知コールバックです。
  public var onRuntimeError: ((Error) -> Void)?

  /// 初期化します。
  ///
  /// - Parameters:
  ///   - targetFPS: 送信する映像フレームレートの目標値
  ///   - videoSampleBufferTransformer: 映像フレーム送信前の加工処理
  ///   - onRuntimeError: 画面キャプチャ実行中エラーの通知コールバック
  public init(
    targetFPS: Int = 15,
    videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil,
    onRuntimeError: ((Error) -> Void)? = nil
  ) {
    self.targetFPS = max(1, targetFPS)
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
  // 画面フレーム送信を常に 1 件だけに限定するためのセマフォ
  // 低遅延維持のため、送信処理中に到着したフレームは待たずに破棄します。
  // さらに targetFPS に基づく間引きも行い、キュー滞留を防ぎます
  private let sendVideoFrameSemaphore = DispatchSemaphore(value: 1)
  private let lock = NSLock()

  private var captureState: CaptureState = .stopped
  private var settings = ScreenCaptureSettings()
  private var senderStream: MediaStream?
  private var lastSentVideoPresentationTimestamp: CMTime?
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
      // MainActor への切り替え中に stopCapture が先行する可能性がありますが、
      // completionHandler 側で captureID を照合して旧世代の start 完了を無効化します。
      Task { @MainActor in
        // 本 API は画面映像のみを送信対象としており、 ReplayKit 経路でのマイク / カメラ入力は使用しません。
        self.recorder.isMicrophoneEnabled = false
        self.recorder.isCameraEnabled = false
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
        // start の世代に紐づく設定をここで確定します。
        // 後続世代の start が走った場合は captureID で旧世代コールバックを無効化します。
        self.settings = settings
        self.lastSentVideoPresentationTimestamp = nil
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
        lastSentVideoPresentationTimestamp = nil
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
        lastSentVideoPresentationTimestamp = nil
        activeCaptureID = nil
        return true
      }
    }
  }

  // キャプチャーした画面フレームを映像フレームに変換してストリーム送出します。
  // targetFPS に基づいて PTS 間引きを行い、送信対象フレームを制御します。
  // さらに送信処理中に到着したフレームは待たずに破棄し、キュー滞留と遅延増加を防ぎます。
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

    // PTS を取得して、targetFPS との比較から、今回のフレームを送信するか判定します
    let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard shouldSendVideoFrame(presentationTimestamp: presentationTimestamp) else {
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
      // sendVideoFrameSemaphore カウントを +1 して次のフレームを処理できるようにします
      defer { self?.sendVideoFrameSemaphore.signal() }

      // 非同期 stopCapture で captureState が変更される可能性があるためここでチェックします
      guard let self, self.isReadyToSend() else {
        return
      }

      self.markVideoFrameSent(presentationTimestamp: presentationTimestamp)

      var sampleBufferToSend = sampleBuffer
      if let transformedBuffer = context.videoSampleBufferTransformer?(sampleBuffer) {
        sampleBufferToSend = transformedBuffer
      } else if context.videoSampleBufferTransformer != nil {
        return
      }

      guard let videoFrame = VideoFrame(from: sampleBufferToSend) else {
        Logger.debug(type: .mediaChannel, message: "failed to create VideoFrame from sampleBuffer")
        return
      }

      context.senderStream.send(videoFrame: videoFrame)
    }
  }

  // 前回送信したフレームのタイムスタンプと targetFPS から今回フレームを送信するかを判定します
  private func shouldSendVideoFrame(presentationTimestamp: CMTime) -> Bool {
    withLock {
      // presentationTimestamp が取れない場合にドロップすると画面停止や過剰なドロップになりうるため
      // 判断できない場合は捨てないようにしている
      guard presentationTimestamp.isValid, !presentationTimestamp.isIndefinite else {
        return true
      }
      guard
        let lastSentVideoPresentationTimestamp,
        lastSentVideoPresentationTimestamp.isValid,
        !lastSentVideoPresentationTimestamp.isIndefinite
      else {
        return true
      }

      // 間引くフレームの判定を行う
      let targetFPS = min(max(1, settings.targetFPS), Int(Int32.max))
      let minInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
      let elapsed = CMTimeSubtract(presentationTimestamp, lastSentVideoPresentationTimestamp)
      return CMTimeCompare(elapsed, minInterval) >= 0
    }
  }

  // 送信したフレームの PTS を保持します
  private func markVideoFrameSent(presentationTimestamp: CMTime) {
    withLock {
      guard presentationTimestamp.isValid, !presentationTimestamp.isIndefinite else {
        return
      }
      lastSentVideoPresentationTimestamp = presentationTimestamp
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
