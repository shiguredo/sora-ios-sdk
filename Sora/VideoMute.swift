import Foundation

// 映像ハードミュートの同時呼び出しによるレースコンディション防止を目的とした Actor です
// MediaChannel.setVideoHardMute(_:) での使用を想定しています
actor VideoHardMuteActor {
  // 処理実行中フラグ
  private var isProcessing = false
  // カメラ操作のためのキャプチャラー
  private var capturer: CameraVideoCapturer?

  /// ハードミュートを有効化/無効化します
  ///
  /// - Parameters:
  ///  - mute: `true` で有効化、`false` で無効化
  ///  - senderStream: 送信ストリーム
  ///  - cameraSettings: カメラ設定
  /// - Throws:
  ///   - 既に処理実行中の場合は `SoraError.mediaChannelError`
  ///   - カメラ操作の失敗時は `SoraError.cameraError`
  func setMute(mute: Bool, senderStream: MediaStream, cameraSettings: CameraSettings) async throws {
    guard !isProcessing else {
      throw SoraError.mediaChannelError(reason: "video hard mute operation is in progress")
    }
    isProcessing = true
    defer { isProcessing = false }

    // ミュートを有効化します
    if mute {
      guard let currentCapturer = await currentCameraVideoCapturer() else {
        // キャプチャ未起動の場合は停止対象がないため、冪等として成功扱いにします
        return
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
    // 前回停止時のキャプチャラーが保持できていれば restart、なければ新規に start します
    if let stored = capturer {
      try await restartCameraVideoCapture(stored, senderStream: senderStream)
      return
    }
    try await startCameraVideoCapture(cameraSettings: cameraSettings, senderStream: senderStream)
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
    senderStream: MediaStream
  ) async throws {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // マルチストリームの場合、停止時と現在の送信ストリームが異なることがあるので再設定します
        capturer.stream = senderStream
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
    cameraSettings: CameraSettings,
    senderStream: MediaStream
  ) async throws {
    // libwebrtc のカメラ用キュー（SoraDispatcher）を利用して実行します
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SoraDispatcher.async(on: .camera) {
        // 接続時設定の position に対応した device を取得します
        // 未指定 (.unspecified) 時はエラーとします
        if cameraSettings.position == .unspecified {
          continuation.resume(
            throwing: SoraError.cameraError(
              reason: "CameraSettings.position should not be .unspecified"
            )
          )
          return
        }

        let device =
          CameraVideoCapturer.device(for: cameraSettings.position)
        guard let device else {
          continuation.resume(throwing: SoraError.cameraError(reason: "camera device is not found"))
          return
        }

        guard
          // 接続時設定に基づいてカメラの解像度、フレームレートを指定します
          let format = CameraVideoCapturer.format(
            width: cameraSettings.resolution.width,
            height: cameraSettings.resolution.height,
            for: device,
            frameRate: cameraSettings.frameRate),
          let frameRate = CameraVideoCapturer.maxFrameRate(cameraSettings.frameRate, for: format)
        else {
          continuation.resume(
            throwing: SoraError.cameraError(reason: "failed to resolve camera settings"))
          return
        }

        // カメラキャプチャを開始します
        // CameraVideoCapturer.start はコールバック形式です
        let capturer = CameraVideoCapturer(device: device)
        capturer.stream = senderStream
        capturer.start(format: format, frameRate: frameRate) { error in
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
