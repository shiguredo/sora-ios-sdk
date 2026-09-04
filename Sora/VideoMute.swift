import AVFoundation
import Foundation

// 公開 API の CameraSettings に Sendable を要求せず、
// actor 境界を越えるために必要な値だけを内部でスナップショット化します。
struct CameraSettingsSnapshot: Sendable {
  let resolution: CameraSettings.Resolution
  let frameRate: Int
  let positionRawValue: Int

  init(_ cameraSettings: CameraSettings) {
    resolution = cameraSettings.resolution
    frameRate = cameraSettings.frameRate
    positionRawValue = cameraSettings.position.rawValue
  }

  var position: AVCaptureDevice.Position {
    AVCaptureDevice.Position(rawValue: positionRawValue) ?? .unspecified
  }
}

// 公開 API の MediaStream に Sendable を要求せず、
// actor 境界で参照を受け渡すための内部ラッパーです。
// 注意: MediaStream 自体は Sendable ではないため、
// ここでの `@unchecked Sendable` は同時アクセスが起きない前提に依存します。
struct SenderStreamBox: @unchecked Sendable {
  let stream: MediaStream
}

// カメラ操作の所有者を識別する lease です。
// MediaChannel の解放後に非同期 cleanup が実行されても別インスタンスと衝突しないよう、
// オブジェクトのメモリアドレスではなく UUID で論理接続を識別します。
// 破棄状態は lease 自身が保持するため、共有 Actor に接続ごとの墓石を残しません。
final class VideoHardMuteLease: @unchecked Sendable, Hashable {
  private let id: UUID
  private let lock = NSLock()
  private var revoked = false

  init(id: UUID = UUID()) {
    self.id = id
  }

  static func == (lhs: VideoHardMuteLease, rhs: VideoHardMuteLease) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  /// 新しい操作または進行中の操作で利用できるかを返します。
  var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !revoked
  }

  /// 進行中および遅延到着する操作を無効化します。
  func revoke() {
    lock.lock()
    revoked = true
    lock.unlock()
  }

  /// 破棄予約済みかをテストから確認します。
  var isRevoked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return revoked
  }
}

/// 映像ハードミュート操作と lease 解放の完了順を管理します。
///
/// Actor は `await` 中に再入できるため、単純な処理中フラグだけでは `release()` が
/// 進行中操作より先に完了します。この tracker は lease を直ちに破棄しつつ、同じ lease の
/// camera cleanup が終わるまで解放側を待機させます。
final class VideoHardMuteOperationTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var activeLease: VideoHardMuteLease?
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingReleaseObservers: [CheckedContinuation<Void, Never>] = []

  /// 新しい操作を開始します。
  func begin(lease: VideoHardMuteLease) throws {
    lock.lock()
    defer { lock.unlock() }

    guard activeLease == nil else {
      throw SoraError.mediaChannelError(reason: "video hard mute operation is in progress")
    }
    guard lease.isValid else {
      throw SoraError.mediaChannelError(
        reason: "video hard mute operation was cancelled")
    }
    activeLease = lease
  }

  /// 操作完了を記録し、同じ lease の解放待ちをすべて再開します。
  func finish(lease: VideoHardMuteLease) {
    let waiters: [CheckedContinuation<Void, Never>]

    lock.lock()
    guard activeLease == lease else {
      lock.unlock()
      return
    }
    activeLease = nil
    waiters = releaseWaiters
    releaseWaiters.removeAll()
    lock.unlock()

    for waiter in waiters {
      waiter.resume()
    }
  }

  /// lease を直ちに破棄し、同じ lease の進行中操作が完了するまで待機します。
  func revokeAndWaitForCompletion(lease: VideoHardMuteLease) async {
    lease.revoke()
    await withCheckedContinuation { continuation in
      lock.lock()
      guard activeLease == lease else {
        lock.unlock()
        continuation.resume()
        return
      }
      releaseWaiters.append(continuation)
      let observers = pendingReleaseObservers
      pendingReleaseObservers.removeAll()
      lock.unlock()
      for observer in observers {
        observer.resume()
      }
    }
  }

  /// 解放処理が進行中操作の完了待ちへ入るまで、テストから待機します。
  func waitUntilReleaseIsPending() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard releaseWaiters.isEmpty else {
        lock.unlock()
        continuation.resume()
        return
      }
      pendingReleaseObservers.append(continuation)
      lock.unlock()
    }
  }

  /// 解放待ちの数をテストから確認します。
  var pendingReleaseCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return releaseWaiters.count
  }
}

// 映像ハードミュートの同時呼び出しによるレースコンディション防止を目的とした Actor です
// MediaChannel.setVideoHardMute(_:) での使用を想定しています
actor VideoHardMuteActor {
  // ハードミュートで停止したキャプチャを取消時に restart するための保持キャプチャラー
  // 保存状態は所有者 (lease) に紐付き、別接続からは取得できない
  private struct StoredCapturer {
    let lease: VideoHardMuteLease
    let capturer: CameraVideoCapturer
    // 停止時の送信ストリーム。復帰時に同一ストリームへ戻すために保持する
    let stream: MediaStream
  }

  // await をまたぐ操作完了と lease 解放を同期する tracker
  private let operationTracker: VideoHardMuteOperationTracker
  // 通常のカメラ操作を含め、実デバイスの操作完了まで process-wide で直列化する coordinator
  private let cameraCaptureCoordinator: CameraVideoCaptureCoordinator
  private var storedCapturer: StoredCapturer?

  init(
    operationTracker: VideoHardMuteOperationTracker = VideoHardMuteOperationTracker(),
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared
  ) {
    self.operationTracker = operationTracker
    self.cameraCaptureCoordinator = cameraCaptureCoordinator
  }

  /// ハードミュートを有効化/無効化します
  ///
  /// - Parameters:
  ///  - mute: `true` で有効化、`false` で無効化
  ///  - lease: カメラ操作の所有者を示す lease
  ///  - senderStream: 送信ストリーム
  ///  - cameraSettings: カメラ設定
  /// - Throws:
  ///   - 既に処理実行中の場合は `SoraError.mediaChannelError`
  ///   - カメラ操作の失敗時は `SoraError.cameraError`
  func setMute(
    mute: Bool,
    lease: VideoHardMuteLease,
    senderStream: SenderStreamBox,
    cameraSettings: CameraSettingsSnapshot
  ) async throws {
    try operationTracker.begin(lease: lease)
    defer { operationTracker.finish(lease: lease) }

    // 破棄予約済みの lease では操作を開始しない。
    try checkNotRevoked(lease: lease)

    // 保存状態の所有権チェック
    // 別接続が保存した capturer をこの接続が取得または上書きできないようにする
    if let storedCapturer, storedCapturer.lease != lease {
      throw SoraError.mediaChannelError(
        reason: "camera is owned by another connection")
    }

    // ミュートを有効化します
    if mute {
      guard let currentCapturer = await currentCameraVideoCapturer() else {
        // キャプチャ未起動の場合は停止対象がないため、冪等として成功扱いにします
        return
      }
      // 動作中のカメラがこの接続の senderStream に紐付いていることを確認する。
      // (別接続が使用中のカメラを停止しないため。CameraVideoCapturer.current は
      // 全接続で共有される static のため、stream の一致が必要)
      guard currentCapturer.stream === senderStream.stream else {
        throw SoraError.mediaChannelError(
          reason: "camera is owned by another connection")
      }
      // stop の前に再確認する (await 中に release された場合)
      try checkNotRevoked(lease: lease)
      try await stopCameraVideoCapture(
        currentCapturer,
        senderStream: senderStream)
      // stop 完了後に再確認する (保存を中止する)
      try checkNotRevoked(lease: lease)
      // ミュート無効化する際にキャプチャラーを使用するため保持しておきます
      // 停止時の送信ストリームも保持し、復帰時に同一ストリームへ戻せるようにします
      storedCapturer = StoredCapturer(
        lease: lease,
        capturer: currentCapturer,
        stream: senderStream.stream
      )
      return
    }

    // ミュートを無効化します
    // 現在のキャプチャラーが自分の senderStream のものであれば、
    // 既に再開済みとして成功扱いにします。ただし CameraVideoCapturer.current は
    // 全接続で共有される static のため、別接続のカメラが動作している場合は
    // 自分のカメラとして成功扱いしない。
    let currentCapturer = await currentCameraVideoCapturer()
    if let currentCapturer {
      // 現在動作しているカメラが、自分が停止時に保存した stream (storedCapturer.stream) に
      // 紐づく場合のみ「自分のカメラが再開済み」と見なす。
      if currentCapturer.stream === storedCapturer?.stream {
        if storedCapturer?.capturer === currentCapturer {
          return
        }
      }
      // 別接続のカメラが動作している場合や、別の capturer に差し替わっている場合は、
      // この接続が保存した capturer の restart を継続できる場合のみ進む
      if storedCapturer?.lease != lease {
        throw SoraError.mediaChannelError(
          reason: "camera is owned by another connection")
      }
    }
    // current の取得後に再確認する (await 中に release された場合)
    try checkNotRevoked(lease: lease)

    // 前回停止時のキャプチャラーが保持できていれば restart、なければ start します
    if let storedCapturer {
      try await restartCameraVideoCapture(
        storedCapturer.capturer,
        senderStream: senderStream)
      // restart 完了後に再確認する。revoke 済みだった場合はカメラを停止する
      try await checkNotRevokedAfterRestart(
        capturer: storedCapturer.capturer,
        senderStream: senderStream,
        lease: lease)
      return
    }
    // 別 lease が保存状態を持つ間に、start 経路で共有カメラを起動しない
    // (guard で all storedCapturer == nil を確認済み)
    let startedCapturer = try await startCameraVideoCapture(
      cameraSettings: cameraSettings,
      senderStream: senderStream)
    // start 完了後に再確認する。revoke 済みだった場合はカメラを停止する
    try await checkNotRevokedAfterStart(
      capturer: startedCapturer,
      senderStream: senderStream,
      lease: lease)
  }

  // 接続切断時に、その接続が所有する保存状態を破棄します。
  // 別接続がこの接続の capturer を取得できないようにするために使用します。
  // 破棄予約も行い、await 中の setMute が復帰後に保存や再開を行わないようにする。
  // 進行中操作がある場合は、その操作が rollback / stop を終えるまで戻らない。
  func release(lease: VideoHardMuteLease) async {
    if storedCapturer?.lease == lease {
      storedCapturer = nil
    }
    await operationTracker.revokeAndWaitForCompletion(lease: lease)
  }

  /// 指定した lease に破棄予約が記録済みかをテストから確認します。
  func isReleased(lease: VideoHardMuteLease) -> Bool {
    lease.isRevoked
  }

  // 破棄予約 (revocation) を検知したかを確認します。
  // 不一致ならエラーを返す (カメラ操作はまだ行っていない場合)
  private func checkNotRevoked(
    lease: VideoHardMuteLease
  ) throws {
    guard lease.isValid else {
      throw SoraError.mediaChannelError(
        reason: "video hard mute operation was cancelled")
    }
  }

  // restart 後に破棄予約を検知した場合、カメラを停止してからエラーを返します。
  // (停止しないと、破棄された接続の stream へカメラが送信し続けるため)
  private func checkNotRevokedAfterRestart(
    capturer: CameraVideoCapturer,
    senderStream: SenderStreamBox,
    lease: VideoHardMuteLease
  ) async throws {
    guard !lease.isValid else {
      return
    }
    // 再開した capturer を停止する (zombie 化を防ぐ)
    try await stopCameraVideoCapture(
      capturer,
      senderStream: senderStream)
    throw SoraError.mediaChannelError(
      reason: "video hard mute operation was cancelled")
  }

  // start 後に破棄予約を検知した場合、カメラを停止してからエラーを返します。
  // (別接続の current capturer を停止しないよう、起動した capturer 自体を指定する)
  private func checkNotRevokedAfterStart(
    capturer: CameraVideoCapturer,
    senderStream: SenderStreamBox,
    lease: VideoHardMuteLease
  ) async throws {
    guard !lease.isValid else {
      return
    }
    // 起動したカメラを停止する (zombie 化を防ぐ)
    try await stopCameraVideoCapture(
      capturer,
      senderStream: senderStream)
    throw SoraError.mediaChannelError(
      reason: "video hard mute operation was cancelled")
  }

  // 現在のカメラキャプチャラーを取得します
  private func currentCameraVideoCapturer() async -> CameraVideoCapturer? {
    await cameraCaptureCoordinator.perform {
      await CameraVideoCapturer.currentForSDK()
    }
  }

  // カメラキャプチャを停止します
  private func stopCameraVideoCapture(
    _ capturer: CameraVideoCapturer,
    senderStream: SenderStreamBox
  ) async throws {
    let cameraCaptureCoordinator = cameraCaptureCoordinator
    try await cameraCaptureCoordinator.perform {
      let current = await CameraVideoCapturer.currentForSDK()
      guard current === capturer, current?.stream === senderStream.stream else {
        // すでに停止済みなら cleanup は完了している。別の current が存在する場合も
        // その接続のカメラには作用しない。
        guard capturer.isRunning else {
          return
        }
        throw SoraError.mediaChannelError(
          reason: "camera is owned by another connection")
      }
      if let error = await capturer.stopForSDK() {
        // callback 時点で停止済みなら cleanup 成功として扱う。
        guard capturer.isRunning else {
          cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturer: capturer)
          return
        }
        cameraCaptureCoordinator.quarantine(capturer: capturer)
        throw error
      }
      cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturer: capturer)
    }
  }

  // カメラキャプチャを再開します
  private func restartCameraVideoCapture(
    _ capturer: CameraVideoCapturer,
    senderStream: SenderStreamBox
  ) async throws {
    let cameraCaptureCoordinator = cameraCaptureCoordinator
    try await cameraCaptureCoordinator.perform {
      guard cameraCaptureCoordinator.isAvailable else {
        throw SoraError.mediaChannelError(
          reason: "camera capture is quarantined after a cleanup failure")
      }
      let current = await CameraVideoCapturer.currentForSDK()
      guard capturer.stream === senderStream.stream else {
        throw SoraError.mediaChannelError(reason: "camera is owned by another connection")
      }
      if let current {
        guard current === capturer, current.stream === senderStream.stream else {
          throw SoraError.mediaChannelError(
            reason: "camera is owned by another connection")
        }
      }
      if let error = await capturer.restartForSDK(senderStream: senderStream) {
        if capturer.isRunning {
          cameraCaptureCoordinator.quarantine(capturer: capturer)
        }
        throw error
      }
    }
  }

  // カメラキャプチャを開始します
  private func startCameraVideoCapture(
    cameraSettings: CameraSettingsSnapshot,
    senderStream: SenderStreamBox
  ) async throws -> CameraVideoCapturer {
    let cameraCaptureCoordinator = cameraCaptureCoordinator
    return try await cameraCaptureCoordinator.perform {
      guard cameraCaptureCoordinator.isAvailable else {
        throw SoraError.mediaChannelError(
          reason: "camera capture is quarantined after a cleanup failure")
      }
      guard await CameraVideoCapturer.currentForSDK() == nil else {
        throw SoraError.mediaChannelError(
          reason: "camera is owned by another connection")
      }

      // 接続時設定の position に対応した CameraVideoCapturer を取得します。
      // `.front` / `.back` を優先して利用し、静的プロパティ経由で参照される状態と齟齬が出ないようにします。
      let capturer: CameraVideoCapturer
      switch cameraSettings.position {
      case .front:
        guard let front = CameraVideoCapturer.front else {
          throw SoraError.cameraError(reason: "front camera is not found")
        }
        capturer = front
      case .back:
        guard let back = CameraVideoCapturer.back else {
          throw SoraError.cameraError(reason: "back camera is not found")
        }
        capturer = back
      case .unspecified:
        throw SoraError.cameraError(
          reason: "CameraSettings.position should not be .unspecified")
      @unknown default:
        guard let device = CameraVideoCapturer.device(for: cameraSettings.position) else {
          throw SoraError.cameraError(reason: "camera device is not found for position")
        }
        capturer = CameraVideoCapturer(device: device)
      }

      guard
        // 接続時設定に基づいてカメラの解像度、フレームレートを指定します
        let format = CameraVideoCapturer.format(
          width: cameraSettings.resolution.width,
          height: cameraSettings.resolution.height,
          for: capturer.device,
          frameRate: cameraSettings.frameRate),
        let frameRate = CameraVideoCapturer.maxFrameRate(
          cameraSettings.frameRate,
          for: format)
      else {
        throw SoraError.cameraError(reason: "failed to resolve camera settings")
      }

      let formatBox = CameraCaptureFormatBox(format: format)
      if let error = await capturer.startForSDK(
        format: formatBox.format,
        frameRate: frameRate,
        senderStream: senderStream)
      {
        throw error
      }
      return capturer
    }
  }
}
