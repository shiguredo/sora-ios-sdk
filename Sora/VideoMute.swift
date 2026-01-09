import Foundation

// 映像ハードミュートの同時呼び出しによるレースコンディション防止を目的とした Actor です
// MediaChannel.setVideoHardMute(_:) での使用を想定しています
actor VideoHardMuteActor {
  // 処理実行中フラグ
  private var isProcessing = false
  // カメラ操作のためのキャプチャラー
  private var capturer: CameraVideoCapturer?

  /// ハードミュートを有効化/無効化します
  /// カメラキャプチャラーの操作には libwebrtc のカメラ用キュー（SoraDispatcher）を利用して呼ぶようにします
  ///
  /// - Parameters:
  ///  - mute: `true` で有効化、`false` で無効化
  ///  - senderStream: 送信ストリーム
  /// - Throws:
  ///   - 既に処理実行中、またはカメラキャプチャラーが無効な場合は `SoraError.mediaChannelError`
  ///   - カメラ操作の失敗時は `SoraError.cameraError`
  func setMute(mute: Bool, senderStream: MediaStream) async throws {
    guard !isProcessing else {
      throw SoraError.mediaChannelError(reason: "video hard mute operation is in progress")
    }
    isProcessing = true
    defer { isProcessing = false }

    // ミュートを有効化します
    if mute {
      guard let currentCapturer = await currentCameraVideoCapturer() else {
        // 前回のハードミュートでキャプチャラーを保持している場合は冪等として成功扱いにします
        if capturer != nil { return }
        throw SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable")
      }
      try await stopCameraVideoCapture(currentCapturer)
      // ミュート無効化する際にキャプチャラーを使用するため保持しておきます
      capturer = currentCapturer
      return
    }

    // ミュートを無効化します
    // 現在のキャプチャラーが取得できる場合は既に再開済みとして成功扱いにします
    let currentCapturer = await currentCameraVideoCapturer()
    if currentCapturer != nil { return }
    // 前回停止時のキャプチャラーが保持できていない場合エラー
    guard let stored = capturer else {
      throw SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable")
    }
    try await restartCameraVideoCapture(stored, senderStream: senderStream)
  }

  // 現在のカメラキャプチャラーを取得します
  private func currentCameraVideoCapturer() async -> CameraVideoCapturer? {
    await withCheckedContinuation { cont in
      SoraDispatcher.async(on: .camera) { cont.resume(returning: CameraVideoCapturer.current) }
    }
  }

  // カメラキャプチャを停止します
  private func stopCameraVideoCapture(_ capturer: CameraVideoCapturer) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // CameraVideoCapturer.stop はコールバック形式です
        capturer.stop { error in
          if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
        }
      }
    }
  }

  // カメラキャプチャを再開します
  private func restartCameraVideoCapture(
    _ capturer: CameraVideoCapturer,
    senderStream: MediaStream
  ) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // マルチストリームの場合、停止時と現在の送信ストリームが異なることがあるので再設定します
        capturer.stream = senderStream
        // CameraVideoCapturer.restart はコールバック形式です
        capturer.restart { error in
          if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
        }
      }
    }
  }
}
