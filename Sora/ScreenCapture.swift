import CoreMedia
import Foundation
import ReplayKit

/// 画面キャプチャの設定です。
public struct ScreenCaptureSettings {
  /// 送信する映像フレームレートの目標値です。
  /// 固定レートではなく上限値となります。また高負荷時はレートを下回る可能性があります。
  /// 1 以上を指定します。入力フレームが高頻度な場合は古いフレームを間引きます。
  /// 指定できる最大値は 120 です。これより大きな値は 120 に丸められます。
  /// 既定値は `15` です。
  ///
  /// フレーム送信間隔は PTS に依存して変動します。
  public var targetFPS: Int

  /// 映像フレーム送信前に `CMSampleBuffer` を加工するためのクロージャーです。
  /// `nil` を返すと該当フレームを破棄します。
  ///
  /// このクロージャーは SDK 内部の送信キュー (`sendVideoFrameQueue`) 上で呼ばれます。
  /// `targetFPS` による間引きで破棄されるフレームと、送信処理中のために破棄されるフレーム、
  /// キャプチャ停止中と切断中のフレームでは呼ばれません。送信キューへ投入された後でも、
  /// capture ID の照合 (停止・再開始の競合) と `VideoFrame` への変換に失敗した場合は
  /// 破棄されるため、呼ばれたフレームが必ず送信されるわけではありません。
  ///
  /// 引数の `CMSampleBuffer` と戻り値の `CMSampleBuffer` の所有権は SDK に委ねられます。
  /// 戻り値の buffer が保持する pixel buffer は SDK が送信のために retain するため、
  /// 利用側で解放や再利用の同期を行う必要はありません。戻り値を返した後にその buffer を
  /// 書き換えないでください (送信中のフレームが変更されると映像が壊れます)。
  public var videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?

  /// 画面キャプチャ実行中に発生したエラー通知コールバックです。
  /// 通知専用のため、このコールバック呼び出しではキャプチャ停止を行いません。
  /// 停止が必要な場合は利用側で `MediaChannel.stopScreenCapture()` を呼び出してください。
  public var onRuntimeError: ((Error) -> Void)?

  /// 初期化します。
  ///
  /// - Parameters:
  ///   - targetFPS: 送信する映像フレームレートの目標値
  ///   - videoSampleBufferTransformer: 映像フレーム送信前の加工処理
  ///   - onRuntimeError: 画面キャプチャ実行中エラーの通知コールバック
  ///     - 通知専用のため、このコールバック呼び出しではキャプチャ停止を行いません
  ///     - 停止が必要な場合は利用側で `MediaChannel.stopScreenCapture()` を呼び出してください
  public init(
    targetFPS: Int = 15,
    videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil,
    onRuntimeError: ((Error) -> Void)? = nil
  ) {
    self.targetFPS = min(max(1, targetFPS), 120)
    self.videoSampleBufferTransformer = videoSampleBufferTransformer
    self.onRuntimeError = onRuntimeError
  }
}

/// process-wide の ReplayKit recorder に対する操作順と所有者を管理します。
///
/// `RPScreenRecorder.shared()` は接続間で共有されるため、controller ごとのキューでは
/// 別接続の start / stop が競合します。すべての操作を 1 本のキューへ集約し、
/// owner ID が一致する controller だけが recorder を停止できるようにします。
///
/// `@unchecked Sendable` の根拠は次のとおりです。不変条件を破る公開経路はありません。
///
/// - `operationQueue` / `shared` / `lock` は不変値です。
/// - `ownerID` / `quarantined` は `lock` で保護し、読み書きはすべて `lock` の区間内で行います。
/// - `shared` は process-wide の単一 instance で、生成後の差し替えは行いません。
final class ScreenCaptureRecorderCoordinator: @unchecked Sendable {
  static let shared = ScreenCaptureRecorderCoordinator()

  private let operationQueue = SerializedAsyncOperationQueue()
  private let lock = NSLock()
  private var ownerID: UUID?
  private var quarantined = false

  /// 直前の ReplayKit 操作が完了した後に処理を実行します。
  @discardableResult
  func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    operationQueue.enqueue(operation)
  }

  /// recorder が未使用の場合に owner を予約します。
  func acquire(ownerID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard self.ownerID == nil, !quarantined else {
      return false
    }
    self.ownerID = ownerID
    return true
  }

  /// 指定した owner が現在の recorder 所有者かを返します。
  func isOwner(_ ownerID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.ownerID == ownerID
  }

  /// 指定した owner が保持する recorder を解放します。
  func release(ownerID: UUID) {
    lock.lock()
    if self.ownerID == ownerID {
      self.ownerID = nil
    }
    lock.unlock()
  }

  /// stop 後の recorder 状態を反映します。
  ///
  /// 実際に停止していない場合は owner を保持した隔離状態とし、別接続の取得を拒否します。
  func finishStop(ownerID: UUID, recorderStopped: Bool) {
    lock.lock()
    guard self.ownerID == ownerID else {
      lock.unlock()
      return
    }
    if recorderStopped {
      self.ownerID = nil
      quarantined = false
    } else {
      quarantined = true
    }
    lock.unlock()
  }

  /// recorder の隔離状態をテストから確認します。
  var isQuarantined: Bool {
    lock.lock()
    defer { lock.unlock() }
    return quarantined
  }
}

/// 画面キャプチャのコントローラーです。
///
/// `@unchecked Sendable` の根拠は次のとおりです。不変条件を破る公開経路はありません。
///
/// - `recorder` / `recorderOwnerID` / `recorderCoordinator` / `sendVideoFrameQueue` /
///   `sendVideoFrameSemaphore` / `lock` は不変値です。
/// - `mediaChannel` は弱参照で、接続の所有権は `MediaChannel` 側にあります。
/// - `captureState` / `settings` / `senderStream` / `lastSentVideoPresentationTimestamp` /
///   `lastSentVideoUptime` / `captureID` / `activeCaptureID` / `recorderCaptureID` /
///   `recorderStopTask` / `mediaChannelConnectionRequired` は `lock` で保護し、
///   読み書きはすべて `withLock` の区間内で行います。
/// - 送信対象の capture ID と sender stream は `activeCaptureAndStream()` が同じ `lock` 区間で
///   取得します (不変条件は同関数の doc を参照)。
/// - ReplayKit callback と recorder の完了 callback は `Task { @MainActor in ... }` から呼ばれ、
///   controller の状態の読み書きはすべて `lock` の区間内で行います。
final class ScreenCaptureController: @unchecked Sendable {
  // キャプチャー状況の列挙型
  private enum CaptureState {
    case stopped
    case starting
    case running
    case stopping
    case cleanupFailed
  }

  /// ReplayKit が渡した `CMSampleBuffer` の所有権を保持する内部ラッパーです。
  ///
  /// `handleSampleBuffer` が受け取った buffer を `CMSampleBufferCreateCopy` で複製し、
  /// 1 回だけ送信キューへ所有権ごと移動するために使用します。
  ///
  /// `@unchecked Sendable` の根拠は次の 2 点だけです。
  ///
  /// - Create ルールで得た `CMSampleBuffer` オブジェクトの所有権が単一の所有者に移り、
  ///   その所有者だけがオブジェクトを読む (コピー元のオブジェクトは参照カウントの増減以外に触らない)。
  ///   参照カウントの増減は Core Foundation が排他する。
  /// - 値を保持する `ScreenCaptureOwnedFrame` は生成側 (ReplayKit callback の executor) から
  ///   消費側 (`sendVideoFrameQueue`) へ所有権ごと移動し、移動後は生成側が値を参照しない。
  ///   移動は 1 回だけで、複数の executor が同じ値を同時に読まない。
  ///
  /// `CMSampleBufferCreateCopy` は image buffer (画素データ) を共有するため、この型が保証するのは
  /// `CMSampleBuffer` オブジェクトの所有権だけであり、画素データの不変性は保証しません。
  struct ScreenCaptureOwnedSampleBuffer: @unchecked Sendable {
    /// 所有権を持つ sample buffer です。
    let sampleBuffer: CMSampleBuffer

    /// 渡された sample buffer の浅いコピーを作ります。
    ///
    /// `CMSampleBufferCreateCopy` が失敗した場合は `nil` を返します。この失敗は通常の入力では
    /// 発生せず、失敗させる入力も特定できないためユニットテストでは再現できません。
    /// 呼び出し元は `nil` の場合に取得済みの permit を返却してフレームを破棄します。
    init?(_ sampleBuffer: CMSampleBuffer) {
      var copiedBuffer: CMSampleBuffer?
      let status = CMSampleBufferCreateCopy(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sampleBuffer,
        sampleBufferOut: &copiedBuffer)
      guard status == noErr, let copiedBuffer else {
        return nil
      }
      self.sampleBuffer = copiedBuffer
    }
  }

  /// 送信キューへ渡す payload です。
  ///
  /// 送信キューがキャプチャする値はこの型だけに限定し、OS が渡した `CMSampleBuffer` や
  /// `CaptureContext` を escaping closure へ持ち込みません。
  ///
  /// `@unchecked Sendable` の根拠は `ScreenCaptureOwnedSampleBuffer` と同じ 2 点です。
  /// この値は生成側から送信キューへ 1 回だけ移動し、移動後は生成側が参照しません。
  struct ScreenCaptureOwnedFrame: @unchecked Sendable {
    /// この frame を取得した時点の capture ID です。
    /// 停止・再開始の競合で旧 capture のフレームを送信しないために使用します。
    let captureID: UInt64
    /// frame の presentation timestamp です。間引き判定と送信記録に使用します。
    let presentationTimestamp: CMTime
    /// SDK が所有権を持つ sample buffer です。
    let sampleBuffer: ScreenCaptureOwnedSampleBuffer
    /// この frame を取得した時点の世代の transformer です。
    ///
    /// 停止・再開始をまたいだ旧世代の frame には、その frame の世代の transformer を適用します
    /// (enqueue 時の snapshot)。`nil` の場合は元の sample buffer をそのまま送信します。
    let videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?
  }

  /// ReplayKit の完了コールバック時点のエラーと実際の録画状態
  private struct RecorderOperationResult: @unchecked Sendable {
    let error: Error?
    let isRecording: Bool
  }

  /// ReplayKit の開始 API を呼んだか、呼ぶ前から別用途で録画中だったかを表します。
  private enum RecorderStartResult: @unchecked Sendable {
    case alreadyRecording
    case completed(RecorderOperationResult)
  }

  private weak var mediaChannel: MediaChannel?
  // ReplayKit のレコーダーです
  private let recorder = RPScreenRecorder.shared()
  // 共有 recorder に対する、この controller 固有の所有者 ID
  private let recorderOwnerID = UUID()
  // process-wide の ReplayKit 操作と所有者を管理する coordinator
  private let recorderCoordinator: ScreenCaptureRecorderCoordinator
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
  private var lastSentVideoUptime: TimeInterval?
  // startCapture の非同期完了を世代管理するための ID です。
  // start/stop が前後したときに、古い start 完了コールバックを無効化します。
  private var captureID: UInt64 = 0
  private var activeCaptureID: UInt64?
  // ReplayKit の start が成功し、対応する stop が必要な capture ID
  private var recorderCaptureID: UInt64?
  // stop の完了待ちを、同時に停止する呼び出しと切断処理で共有する Task
  private var recorderStopTask: Task<Void, Never>?

  init(
    mediaChannel: MediaChannel,
    recorderCoordinator: ScreenCaptureRecorderCoordinator = .shared
  ) {
    self.mediaChannel = mediaChannel
    self.recorderCoordinator = recorderCoordinator
  }

  // 画面キャプチャを開始します
  func startCapture(
    settings: ScreenCaptureSettings,
    senderStream: MediaStream,
    authorization: VideoSourceCoordinator.Reservation,
    videoSourceCoordinator: VideoSourceCoordinator
  ) async throws {
    guard videoSourceCoordinator.isValid(authorization) else {
      throw SoraError.mediaChannelError(reason: "screen capture start was cancelled")
    }
    let captureID = try beginStartCapture(settings: settings, senderStream: senderStream)

    // beginStartCapture と並行して停止または切断された場合は、ReplayKit の操作を始めない。
    guard videoSourceCoordinator.isValid(authorization) else {
      let error = SoraError.mediaChannelError(reason: "screen capture start was cancelled")
      _ = completeStartCapture(captureID: captureID, error: error)
      throw error
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      recorderCoordinator.enqueue { [self] in
        // start のキュー投入前に stop が完了した場合は、ReplayKit の開始自体を行わない。
        guard shouldIssueRecorderStart(captureID: captureID),
          videoSourceCoordinator.isValid(authorization)
        else {
          let error = SoraError.mediaChannelError(reason: "screen capture start was cancelled")
          _ = completeStartCapture(captureID: captureID, error: error)
          continuation.resume(
            throwing: error
          )
          return
        }

        // ReplayKit の recorder は process-wide で共有されるため、別 controller が
        // 使用中の場合は OS の start API を呼ばずに決定的に拒否する。
        guard recorderCoordinator.acquire(ownerID: recorderOwnerID) else {
          let error = SoraError.mediaChannelError(
            reason: "screen capture is owned by another connection")
          _ = completeStartCapture(captureID: captureID, error: error)
          continuation.resume(throwing: error)
          return
        }

        let recorderStartResult = await startRecorderCaptureIfIdle()
        guard case .completed(let recorderResult) = recorderStartResult else {
          recorderCoordinator.release(ownerID: recorderOwnerID)
          let error = SoraError.mediaChannelError(
            reason: "screen capture recorder is already used outside this connection")
          _ = completeStartCapture(captureID: captureID, error: error)
          continuation.resume(throwing: error)
          return
        }

        var error = recorderResult.error
        if error == nil, !recorderResult.isRecording {
          error = SoraError.mediaChannelError(
            reason: "screen capture start succeeded without an active recorder")
        }

        if error == nil {
          recordRecorderStart(captureID: captureID)
        } else {
          // start の失敗時は isRecording だけでは SDK の所有権を証明できない。
          // ホストアプリが同じ recorder を使用している可能性があるため停止せず予約を解放する。
          if recorderResult.isRecording {
            Logger.warn(
              type: .mediaChannel,
              message: "screen capture start failed while the recorder is active")
          }
          recorderCoordinator.release(ownerID: recorderOwnerID)
        }

        switch completeStartCapture(captureID: captureID, error: error) {
        case .success:
          continuation.resume(returning: ())
        case .failed(let error):
          continuation.resume(throwing: error)
        case .cancelled:
          // stop は同じ operation queue に投入されており、この start 完了後に
          // recorderCaptureID を確認して ReplayKit を停止する。
          continuation.resume(
            throwing: SoraError.mediaChannelError(reason: "screen capture start was cancelled")
          )
        }
      }
    }
  }

  // 画面キャプチャを停止します
  func stopCapture() async {
    guard let task = scheduleStopCapture() else {
      return
    }
    await task.value
  }

  /// `scheduleStopCapture()` で論理停止を確定した後、必要な ReplayKit 停止を実行します。
  private func stopRecorderCaptureAfterBegin() async {
    let hasRecorderCapture = withLock { recorderCaptureID != nil }
    let shouldStopRecorder = hasRecorderCapture && recorderCoordinator.isOwner(recorderOwnerID)
    let recorderStopped: Bool
    if shouldStopRecorder {
      let recorderResult = await stopRecorderCapture()
      if let error = recorderResult.error {
        Logger.error(
          type: .mediaChannel,
          message: "failed to stop screen capture: \(error.localizedDescription)"
        )
      }
      if recorderResult.isRecording {
        Logger.error(
          type: .mediaChannel,
          message: "screen capture recorder is still running after stop")
      }
      recorderCoordinator.finishStop(
        ownerID: recorderOwnerID,
        recorderStopped: !recorderResult.isRecording)
      recorderStopped = !recorderResult.isRecording
    } else if hasRecorderCapture {
      // 開始成功を記録済みなのに所有者でない場合は、別用途の recorder を停止しない。
      // 所有状態が解消するまで再試行できるよう、クリーンアップ失敗として保持する。
      recorderStopped = false
    } else {
      recorderCoordinator.release(ownerID: recorderOwnerID)
      recorderStopped = true
    }
    completeStopCapture(recorderStopped: recorderStopped)
  }

  // ReplayKit の停止結果を反映し、未停止なら同じ controller から再試行できる状態を保持します。
  private func completeStopCapture(recorderStopped: Bool) {
    withLock {
      captureState = recorderStopped ? .stopped : .cleanupFailed
      if recorderStopped {
        recorderCaptureID = nil
      }
      recorderStopTask = nil
    }
  }

  // 切断時に呼び出される stopCapture です。
  // 公開切断 callback より前に ReplayKit の停止を完了するため、呼び出し元へ Task を返します。
  @discardableResult
  func stopCaptureForDisconnect() -> Task<Void, Never>? {
    // MediaChannel の deinit から呼ばれた場合も、ここでフレーム送出を同期的に無効化する。
    scheduleStopCapture()
  }

  // 画面キャプチャが動作中かどうかを返します。
  // starting / running / stopping / cleanupFailed を動作中として扱います。
  func isCaptureActive() -> Bool {
    withLock {
      captureState != .stopped
    }
  }

  // MARK: - Private

  // completeStartCapture の戻り値として使用する。テストから比較するため internal とする。
  enum StartCaptureResult {
    case success
    case failed(Error)
    case cancelled
  }

  private func withLock<T>(_ block: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try block()
  }

  /// 論理停止を同期的に確定し、共有 recorder の停止 Task を返します。
  ///
  /// すでに停止中の場合は同じ Task を返すため、通常停止と切断が競合しても
  /// 公開切断 callback は先行する停止処理の完了を待てます。
  private func scheduleStopCapture() -> Task<Void, Never>? {
    withLock {
      switch captureState {
      case .stopped:
        return nil
      case .stopping:
        return recorderStopTask
      case .starting, .running, .cleanupFailed:
        captureState = .stopping
        senderStream = nil
        lastSentVideoPresentationTimestamp = nil
        lastSentVideoUptime = nil
        activeCaptureID = nil

        // operation closure が ReplayKit の停止コールバックまで controller を強参照する。
        // MediaChannel への参照は weak のため循環参照にはならない。
        let task = recorderCoordinator.enqueue { [self] in
          await stopRecorderCaptureAfterBegin()
        }
        recorderStopTask = task
        return task
      }
    }
  }

  /// 遅延した start 操作が、現在も同じ capture の開始要求に対応するかを確認します。
  /// 本番の operation queue とテストの競合イベント列から呼び出します。
  func shouldIssueRecorderStart(captureID: UInt64) -> Bool {
    withLock {
      captureState == .starting && activeCaptureID == captureID
    }
  }

  /// ReplayKit の start 成功を記録し、後続の stop が OS 停止を必要とすることを示します。
  private func recordRecorderStart(captureID: UInt64) {
    withLock {
      recorderCaptureID = captureID
    }
  }

  /// 別用途の録画が動作していない場合だけ ReplayKit の開始 API を呼びます。
  private func startRecorderCaptureIfIdle() async -> RecorderStartResult {
    await withCheckedContinuation { continuation in
      Task { @MainActor in
        // 設定変更より前に確認し、ホストアプリが所有する録画へ干渉しない。
        guard !self.recorder.isRecording else {
          continuation.resume(returning: .alreadyRecording)
          return
        }

        // 本 API は画面映像のみを送信対象としており、ReplayKit 経路でのマイク / カメラ入力は使用しません。
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
          completionHandler: { error in
            Task { @MainActor in
              continuation.resume(
                returning: .completed(
                  RecorderOperationResult(
                    error: error,
                    isRecording: self.recorder.isRecording)))
            }
          })
      }
    }
  }

  /// ReplayKit の画面キャプチャを停止し、完了時のエラーを返します。
  private func stopRecorderCapture() async -> RecorderOperationResult {
    await withCheckedContinuation { continuation in
      Task { @MainActor in
        self.recorder.stopCapture { error in
          Task { @MainActor in
            continuation.resume(
              returning: RecorderOperationResult(
                error: error,
                isRecording: self.recorder.isRecording))
          }
        }
      }
    }
  }

  // startCapture 前に state チェック、更新を行います
  // 本番では startCapture() からのみ呼ばれる。
  // テストからイベント列 (start / stop / restart) を入力するため internal とする。
  // (completeStartCapture() と対で呼ぶ必要がある。単体で呼ぶと state が .starting で止まる)
  func beginStartCapture(settings: ScreenCaptureSettings, senderStream: MediaStream) throws
    -> UInt64
  {
    try withLock {
      switch captureState {
      case .running:
        throw SoraError.mediaChannelError(reason: "screen capture is already running")
      case .starting, .stopping, .cleanupFailed:
        throw SoraError.mediaChannelError(reason: "screen capture operation is in progress")
      case .stopped:
        captureID += 1
        activeCaptureID = captureID
        // start の世代に紐づく設定をここで確定します。
        // 後続世代の start が走った場合は captureID で旧世代コールバックを無効化します。
        self.settings = settings
        self.lastSentVideoPresentationTimestamp = nil
        self.lastSentVideoUptime = nil
        self.senderStream = senderStream
        captureState = .starting
        return captureID
      }
    }
  }

  // startCapture のコールバックが返ってきた後に state 更新等を行います
  // 本番では startCapture() の完了コールバックからのみ呼ばれる。
  // テストからイベント列 (start / complete / stop / restart) を入力するため internal とする。
  // (beginStartCapture() と対で呼ぶ必要がある。単体で呼ぶと state が不正になる)
  func completeStartCapture(captureID: UInt64, error: Error?) -> StartCaptureResult {
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
        lastSentVideoUptime = nil
        activeCaptureID = nil
        return .failed(error)
      }

      captureState = .running
      return .success
    }
  }

  // キャプチャした画面フレームを映像フレームに変換してストリーム送出します。
  // targetFPS に基づいて PTS 間引きを行い、送信対象フレームを制御します。
  // さらに送信処理中に到着したフレームは待たずに破棄し、キュー滞留と遅延増加を防ぎます。
  // onRuntimeError は通知専用で、エラー発生時の停止処理を含みません。
  // キャプチャを停止するには stopCapture を実行する必要があります。
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

    // OS が渡した sample buffer はここで複製し、queue へは所有権を持つ表現だけを渡します。
    enqueueOwnedFrame(
      sampleBuffer: sampleBuffer,
      presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }

  /// キャプチャしたフレームを送信キューへ投入します。
  ///
  /// 本番では `handleSampleBuffer` からのみ呼ばれる。テストから間引き・ semaphore の取得失敗・
  /// 停止中の各経路を入力するため internal とする。
  ///
  /// permit の返却はこのメソッドの中で完結します。enqueue しなかった場合はこのメソッドが
  /// signal し、enqueue した場合は送信キュー上の `processOwnedFrame` が signal します。
  ///
  /// - Returns: 送信キューへ enqueue した場合は `true`、フレームを破棄した場合は `false`。
  @discardableResult
  func enqueueOwnedFrame(
    sampleBuffer: CMSampleBuffer,
    presentationTimestamp: CMTime
  ) -> Bool {
    // capture ID は停止・再開始の競合で旧 capture のフレームを送信しないために、
    // 間引き判定より前に固定します。activeCaptureIDForRunningCapture() は
    // 「captureState == .running かつ activeCaptureID != nil」を 1 つの lock 区間で判定します。
    // ここで nil になるのは停止がこの区間の直前で確定した場合だけであり、スレッドの
    // タイミングに依存するためユニットテストでは再現できません。permit はまだ取得していないため
    // 返却するものはありません。
    guard let captureID = activeCaptureIDForRunningCapture() else {
      return false
    }

    // 引数の PTS と targetFPS との比較から、今回のフレームを送信するか判定します
    guard shouldSendVideoFrame(presentationTimestamp: presentationTimestamp) else {
      return false
    }

    // 即取得できなければフレーム詰まりを回避するためにこのフレームは破棄します
    guard tryAcquireSendFlight() else {
      return false
    }

    // ここから先でフレームを破棄する場合は、取得済みの permit を必ず返却します。
    // 返却しないと sendVideoFrameSemaphore が 0 のままになり、以降のフレームが全て破棄されます。
    // このコピー失敗は通常の入力では発生しないため、ユニットテストでは再現できません。
    guard let ownedSampleBuffer = ScreenCaptureOwnedSampleBuffer(sampleBuffer) else {
      Logger.debug(type: .mediaChannel, message: "failed to copy sampleBuffer for screen capture")
      sendVideoFrameSemaphore.signal()
      return false
    }

    // transformer もこの時点で snapshot します。停止・再開始をまたいだ旧世代の frame に
    // 新世代の transformer を適用しないためです (改修前の CaptureContext と同じ粒度)。
    let transformer = withLock { settings.videoSampleBufferTransformer }
    // この時点から queue が処理する値は ScreenCaptureOwnedFrame だけになります。
    // OS が渡した sample buffer はこの closure から参照しません。
    // permit の返却は processOwnedFrame の defer が行うため、この closure では signal しません。
    let ownedFrame = ScreenCaptureOwnedFrame(
      captureID: captureID,
      presentationTimestamp: presentationTimestamp,
      sampleBuffer: ownedSampleBuffer,
      videoSampleBufferTransformer: transformer)
    sendVideoFrameQueue.async { [weak self] in
      self?.processOwnedFrame(ownedFrame)
    }
    return true
  }

  /// 所有権を持つ frame を送信します。
  ///
  /// `sendVideoFrameSemaphore` は取得せず、呼び出し元 (本番の queue closure または
  /// `performSend`) が取得済みであることを前提とします。signal はこのメソッドの `defer` で
  /// 1 回だけ行います。
  ///
  /// 接続状態の確認は `mediaChannelConnectionRequired` で制御します。本番の queue closure は
  /// この値が `true` のまま実行し、テストは `performSend` または
  /// `setMediaChannelConnectionRequiredForTesting(_:)` で無効化します。
  func processOwnedFrame(_ ownedFrame: ScreenCaptureOwnedFrame) {
    // この frame の処理で消費した permit を返却します
    defer { sendVideoFrameSemaphore.signal() }

    // captureState を確認します。`.running` でなければ transformer を実行せずに破棄します。
    guard isCaptureStateRunning() else {
      return
    }

    // 接続状態を確認します。切断処理と capture の停止は別々に進むため、切断済みなら
    // transformer を実行せずに破棄します。改修前の isReadyToSend と同じ位置 (transformer の前) です。
    // テストは接続を行わないため、接続状態の確認を無効化できるようにしています。
    if requiresMediaChannelConnection, !isMediaChannelConnected() {
      return
    }

    // transformer は改修前と同じく送信キューの executor 上で実行します。
    // 適用する transformer は payload が固定した世代のものです。
    // transformer が未設定の場合は元の buffer をそのまま使い、nil を返した場合だけ破棄します。
    var sampleBufferToSend = ownedFrame.sampleBuffer.sampleBuffer
    if let transformer = ownedFrame.videoSampleBufferTransformer {
      guard let transformedBuffer = transformer(sampleBufferToSend) else {
        return
      }
      sampleBufferToSend = transformedBuffer
    }

    guard let videoFrame = VideoFrame(from: sampleBufferToSend) else {
      Logger.debug(type: .mediaChannel, message: "failed to create VideoFrame from sampleBuffer")
      return
    }

    // 送信直前に capture ID と送信先 stream を照合する。送信準備中 (transformer 実行・
    // VideoFrame 生成など) に stop / restart が完了した場合、旧 capture のフレームを送信しない
    // (captureState の確認だけでは、stop / restart 後の .running で旧 capture の frame を
    // 識別できない)
    guard let (activeCaptureID, senderStream) = activeCaptureAndStream(),
      activeCaptureID == ownedFrame.captureID
    else {
      return
    }

    // 送信直前のみ PTS / uptime を記録する (ID 照合を通過しなかった stale frame の破棄で
    // throttle 状態を汚染しない)
    markVideoFrameSent(presentationTimestamp: ownedFrame.presentationTimestamp)
    senderStream.send(videoFrame: videoFrame)
  }

  /// flight を取得してから `processOwnedFrame` を実行します。テスト専用の seam です。
  ///
  /// 本番の送信キューは `enqueueOwnedFrame` が取得した flight を `processOwnedFrame` へ
  /// 引き継ぐため、このメソッドは呼びません。テストから送信経路を直接駆動するために internal とします。
  /// テストは `MediaChannel` を接続しないため、呼び出し前に
  /// `setMediaChannelConnectionRequiredForTesting(false)` を設定しておく必要があります。
  ///
  /// - Returns: flight を取得して `processOwnedFrame` を実行した場合は `true`、
  ///   取得できずにフレームを破棄した場合は `false`。
  @discardableResult
  func performSend(ownedFrame: ScreenCaptureOwnedFrame) -> Bool {
    guard tryAcquireSendFlight() else {
      return false
    }
    processOwnedFrame(ownedFrame)
    return true
  }

  /// 送信キューへ投入した frame の処理完了を待ちます。テスト専用の seam です。
  ///
  /// 送信キューは serial なので、`sync {}` は先行して enqueue された frame の処理と
  /// `processOwnedFrame` の `defer` signal の完了を待ちます。したがって permit の会計は
  /// `sync {}` の前後で変わりません。このメソッドを送信キュー自身の executor から呼ぶと
  /// 自己デッドロックするため、テストの executor からのみ呼びます。
  func drainSendVideoFrameQueue() {
    sendVideoFrameQueue.sync {}
  }

  /// `sendVideoFrameSemaphore` を即時取得します。取得できた場合だけ `true` を返します。
  ///
  /// 本番では `enqueueOwnedFrame` から、テストでは「送信中の flight を再現する」ために呼びます。
  /// テストが `true` を受け取った場合は、`tryAcquireSendFlightRelease()` で返却してください。
  @discardableResult
  func tryAcquireSendFlight() -> Bool {
    sendVideoFrameSemaphore.wait(timeout: .now()) == .success
  }

  /// テストが `tryAcquireSendFlight()` で保持した flight を返却します。
  ///
  /// 本番の送信キューは `processOwnedFrame` の `defer` で返却するため、このメソッドは呼びません。
  func tryAcquireSendFlightRelease() {
    sendVideoFrameSemaphore.signal()
  }

  // 前回送信したフレームの PTS と targetFPS から今回フレームを送信するかを判定します
  // PTS が利用できない場合は単調時刻でフォールバック判定します
  func shouldSendVideoFrame(presentationTimestamp: CMTime) -> Bool {
    withLock {
      // PTS が無効な場合は単調時刻で間引きます。
      guard presentationTimestamp.isValid, !presentationTimestamp.isIndefinite else {
        return shouldSendVideoFrameWithUptime()
      }
      guard
        let lastSentVideoPresentationTimestamp,
        lastSentVideoPresentationTimestamp.isValid,
        !lastSentVideoPresentationTimestamp.isIndefinite
      else {
        return shouldSendVideoFrameWithUptime()
      }

      // 間引くフレームの判定を行う
      let targetFPS = min(max(1, settings.targetFPS), 120)
      let minInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
      let elapsed = CMTimeSubtract(presentationTimestamp, lastSentVideoPresentationTimestamp)
      if !elapsed.isValid || elapsed.isIndefinite || CMTimeCompare(elapsed, .zero) < 0 {
        return shouldSendVideoFrameWithUptime()
      }
      return CMTimeCompare(elapsed, minInterval) >= 0
    }
  }

  private func shouldSendVideoFrameWithUptime() -> Bool {
    guard let lastSentVideoUptime else {
      return true
    }
    let targetFPS = min(max(1, settings.targetFPS), 120)
    let minInterval = 1.0 / Double(targetFPS)
    let elapsed = ProcessInfo.processInfo.systemUptime - lastSentVideoUptime
    return elapsed >= minInterval
  }

  // 送信したフレームの PTS と単調時刻を保持します
  private func markVideoFrameSent(presentationTimestamp: CMTime) {
    withLock {
      lastSentVideoUptime = ProcessInfo.processInfo.systemUptime
      guard presentationTimestamp.isValid, !presentationTimestamp.isIndefinite else {
        lastSentVideoPresentationTimestamp = nil
        return
      }
      lastSentVideoPresentationTimestamp = presentationTimestamp
    }
  }

  /// 最後に送信した frame の presentation timestamp を返します。
  ///
  /// 保持するのは payload が持つ transform 前の PTS であり、transformer が返した buffer の
  /// PTS とは異なる場合があります。テストから timestamp の更新有無を確認するため internal とする。
  var lastSentVideoPresentationTimestampForTesting: CMTime? {
    withLock { lastSentVideoPresentationTimestamp }
  }

  /// 送信直前の接続状態の確認を要求するかどうかです。
  ///
  /// 本番では常に `true` とし、`MediaChannel` の接続状態を確認します。テストは
  /// `setMediaChannelConnectionRequiredForTesting(_:)` または `performSend` で無効化します。
  /// `NSLock` で保護し、送信キューとテストの両方から読めるようにします。
  private var mediaChannelConnectionRequired = true

  /// 接続状態の確認を要求するかどうかを設定します。
  ///
  /// 接続を行わずに送信経路を駆動するテストと、接続状態の確認が frame を破棄することを
  /// 確認するテストのために internal とする。本番では常に `true` のままで、この setter は呼びません。
  func setMediaChannelConnectionRequiredForTesting(_ required: Bool) {
    withLock {
      mediaChannelConnectionRequired = required
    }
  }

  /// 送信直前の接続状態の確認が必要かどうかを返します。
  private var requiresMediaChannelConnection: Bool {
    withLock { mediaChannelConnectionRequired }
  }

  /// 現在の capture (`activeCaptureID`) が指定した capture ID と一致するかを返します。
  ///
  /// 本番の送信経路は `processOwnedFrame` が `activeCaptureAndStream` で同じ判定を行う。
  /// テストから世代の進み方を確認するため internal とする。
  func isActiveCaptureID(_ captureID: UInt64) -> Bool {
    withLock {
      return activeCaptureID == captureID
    }
  }

  /// 送信対象の capture ID と送信先 stream を同じ lock 区間で返します。
  ///
  /// `.running` へ遷移するのは completeStartCapture 成功時のみで、その時点で
  /// `activeCaptureID` と `senderStream` は必ず非 nil となります (不変条件)。
  /// また `scheduleStopCapture` は `activeCaptureID` と `senderStream` を同じ lock 区間で
  /// nil にします。この 2 つを別々の区間で読むと、capture A の frame を capture B の
  /// stream へ送る組み合わせが成立し得るため、必ず同じ区間で取得します。
  private func activeCaptureAndStream() -> (UInt64, MediaStream)? {
    withLock {
      guard captureState == .running, let activeCaptureID else {
        return nil
      }
      guard let senderStream else {
        return nil
      }
      return (activeCaptureID, senderStream)
    }
  }

  /// `.running` 中の capture ID を返します。停止中は `nil` を返します。
  ///
  /// `enqueueOwnedFrame` が frame を queue へ渡す前に、その時点の世代を payload へ固定するために使います。
  private func activeCaptureIDForRunningCapture() -> UInt64? {
    withLock {
      guard captureState == .running, let activeCaptureID else {
        return nil
      }
      return activeCaptureID
    }
  }

  /// captureState が `.running` かどうかだけを判定します。
  ///
  /// 接続状態を見ないため、送信キューを持たないテストからも送信経路を駆動できます。
  /// 送信経路はこの判定と `isMediaChannelConnected()` を別々に呼びます。
  private func isCaptureStateRunning() -> Bool {
    withLock { captureState == .running }
  }

  /// mediaChannel が接続中かどうかだけを判定します。
  ///
  /// 切断処理と capture の停止は別々に進むため、送信直前にも接続状態を確認します。
  /// テストから接続状態の判定を確認するため internal とする。
  func isMediaChannelConnected() -> Bool {
    withLock { mediaChannel?.state == .connected }
  }
}
