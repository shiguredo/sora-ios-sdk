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
// MediaChannel は 1 回の Sora.connect() に対応するため、接続の識別に
// ObjectIdentifier (MediaChannel identity) を使用します。
// ObjectIdentifier は値のコピーで actor 境界をまたぐため @unchecked Sendable とする。
// 注意: ObjectIdentifier は dealloc 後のアドレス再利用 (ABA) で別インスタンスと
// 同一値になり得るが、切断時に保存状態が破棄されるため実運用では発生しない。
// 将来カメラ状態 owner (論理接続 ID を保持する型) を導入する際に UUID 等へ移行する。
struct VideoHardMuteLease: Hashable, @unchecked Sendable {
  let channel: ObjectIdentifier
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

  // 処理実行中フラグ
  private var isProcessing = false
  private var storedCapturer: StoredCapturer?
  // lease ごとの破棄予約世代 (revocation)。
  // setMute は開始時に捕捉した世代を各 await 復帰後に照合する。
  // release() で世代を進めると、setMute が await 中に release されても
  // 復帰後に「破棄予約済み」を検知して保存や再開を行わない。
  // (actor は await 中に再入できるため、release の実行タイミングに依存しない)
  private var leaseGenerations: [VideoHardMuteLease: Int] = [:]

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
    guard !isProcessing else {
      throw SoraError.mediaChannelError(reason: "video hard mute operation is in progress")
    }
    isProcessing = true
    defer { isProcessing = false }

    // 操作開始時の世代を捕捉する。setMute は各 await 復帰後に
    // この世代と一致することを確認する (revocation の検知)
    let operationGeneration = leaseGenerations[lease] ?? 0
    // 破棄予約済みの lease では操作を開始しない
    try checkNotRevoked(
      lease: lease, operationGeneration: operationGeneration)

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
      try checkNotRevoked(
        lease: lease, operationGeneration: operationGeneration)
      try await stopCameraVideoCapture(currentCapturer)
      // stop 完了後に再確認する (保存を中止する)
      try checkNotRevoked(
        lease: lease, operationGeneration: operationGeneration)
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
    try checkNotRevoked(
      lease: lease, operationGeneration: operationGeneration)

    // 前回停止時のキャプチャラーが保持できていれば restart、なければ start します
    if let storedCapturer {
      try await restartCameraVideoCapture(
        storedCapturer.capturer,
        senderStream: senderStream)
      // restart 完了後に再確認する。revoke 済みだった場合はカメラを停止する
      try await checkNotRevokedAfterRestart(
        capturer: storedCapturer.capturer,
        lease: lease, operationGeneration: operationGeneration)
      return
    }
    // 別 lease が保存状態を持つ間に、start 経路で共有カメラを起動しない
    // (guard で all storedCapturer == nil を確認済み)
    try await startCameraVideoCapture(cameraSettings: cameraSettings, senderStream: senderStream)
    // start 完了後に再確認する。revoke 済みだった場合はカメラを停止する
    try await checkNotRevokedAfterStart(
      lease: lease, operationGeneration: operationGeneration)
  }

  // 接続切断時に、その接続が所有する保存状態を破棄します。
  // 別接続がこの接続の capturer を取得できないようにするために使用します。
  // 破棄予約 (世代を進める) も行い、await 中の setMute が復帰後に
  // 保存や再開を行わないようにする。
  func release(lease: VideoHardMuteLease) {
    if storedCapturer?.lease == lease {
      storedCapturer = nil
    }
    leaseGenerations[lease, default: 0] += 1
  }

  // 破棄予約 (revocation) を検知したかを確認します。
  // 不一致ならエラーを返す (カメラ操作はまだ行っていない場合)
  private func checkNotRevoked(
    lease: VideoHardMuteLease,
    operationGeneration: Int
  ) throws {
    guard leaseGenerations[lease] ?? 0 == operationGeneration else {
      throw SoraError.mediaChannelError(
        reason: "video hard mute operation was cancelled")
    }
  }

  // restart 後に破棄予約を検知した場合、カメラを停止してからエラーを返します。
  // (停止しないと、破棄された接続の stream へカメラが送信し続けるため)
  private func checkNotRevokedAfterRestart(
    capturer: CameraVideoCapturer,
    lease: VideoHardMuteLease,
    operationGeneration: Int
  ) async throws {
    guard leaseGenerations[lease] ?? 0 != operationGeneration else {
      return
    }
    // 再開した capturer を停止する (zombie 化を防ぐ)
    try await stopCameraVideoCapture(capturer)
    throw SoraError.mediaChannelError(
      reason: "video hard mute operation was cancelled")
  }

  // start 後に破棄予約を検知した場合、カメラを停止してからエラーを返します。
  // (startCameraVideoCapture が capturer を返さないため、現在のカメラを停止する)
  private func checkNotRevokedAfterStart(
    lease: VideoHardMuteLease,
    operationGeneration: Int
  ) async throws {
    guard leaseGenerations[lease] ?? 0 != operationGeneration else {
      return
    }
    // 起動した共有カメラを停止する (zombie 化を防ぐ)
    if let currentCapturer = await currentCameraVideoCapturer() {
      try await stopCameraVideoCapture(currentCapturer)
    }
    throw SoraError.mediaChannelError(
      reason: "video hard mute operation was cancelled")
  }

  // 現在のカメラキャプチャラーを取得します
  private func currentCameraVideoCapturer() async -> CameraVideoCapturer? {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        continuation.resume(returning: CameraVideoCapturer.current)
      }
    }
  }

  // カメラキャプチャを停止します
  private func stopCameraVideoCapture(_ capturer: CameraVideoCapturer) async throws {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // CameraVideoCapturer.stop はコールバック形式です
        capturer.stop { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ())
          }
        }
      }
    }
  }

  // カメラキャプチャを再開します
  private func restartCameraVideoCapture(
    _ capturer: CameraVideoCapturer,
    senderStream: SenderStreamBox
  ) async throws {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // マルチストリームの場合、停止時と現在の送信ストリームが異なることがあるので再設定します
        capturer.stream = senderStream.stream
        // CameraVideoCapturer.restart はコールバック形式です
        capturer.restart { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ())
          }
        }
      }
    }
  }

  // カメラキャプチャを開始します
  private func startCameraVideoCapture(
    cameraSettings: CameraSettingsSnapshot,
    senderStream: SenderStreamBox
  ) async throws {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // 接続時設定の position に対応した CameraVideoCapturer を取得します。
        // `.front` / `.back` を優先して利用し、静的プロパティ経由で参照される状態と齟齬が出ないようにします。
        let capturer: CameraVideoCapturer
        switch cameraSettings.position {
        case .front:
          guard let front = CameraVideoCapturer.front else {
            continuation.resume(
              throwing: SoraError.cameraError(reason: "front camera is not found"))
            return
          }
          capturer = front
        case .back:
          guard let back = CameraVideoCapturer.back else {
            continuation.resume(throwing: SoraError.cameraError(reason: "back camera is not found"))
            return
          }
          capturer = back
        case .unspecified:
          continuation.resume(
            throwing: SoraError.cameraError(
              reason: "CameraSettings.position should not be .unspecified"
            )
          )
          return
        @unknown default:
          guard let device = CameraVideoCapturer.device(for: cameraSettings.position) else {
            continuation.resume(
              throwing: SoraError.cameraError(reason: "camera device is not found for position")
            )
            return
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
          let frameRate = CameraVideoCapturer.maxFrameRate(cameraSettings.frameRate, for: format)
        else {
          continuation.resume(
            throwing: SoraError.cameraError(reason: "failed to resolve camera settings"))
          return
        }

        // カメラキャプチャを開始します
        // CameraVideoCapturer.start はコールバック形式です
        capturer.stream = senderStream.stream
        // start 完了まで capturer を確実に生存させるためにクロージャ側でも保持します。
        // start 成功時は CameraVideoCapturer.current がセットされ、以後はそちらが保持します。
        capturer.start(format: format, frameRate: frameRate) { [capturer] error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ())
          }
        }
      }
    }
  }
}
