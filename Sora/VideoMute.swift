import Foundation

// 映像ハードミュートの同時呼び出しを防ぐためのシリアルキュークラスです
// MediaChannel.setVideoHardMute(_:) 内での使用を想定しています
//
// 既に処理が実行中または CameraVideoCapturer が無効な場合は `SoraError.mediaChannelError` がスローされます
final class VideoHardMuteSerialQueue {
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.video.hardmute")

  // 同時実行を防ぐための処理実行中フラグ
  private var isProcessing = false
  private var capturer: CameraVideoCapturer?

  // queue 上で同時実行を防ぐ排他処理を行い、
  // libwebrtc のカメラ用キュー（SoraDispatcher）でカメラ操作を行います
  func set(mute: Bool, senderStream: MediaStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        // 同時に呼び出された場合はエラーにします
        guard !isProcessing else {
          continuation.resume(
            throwing: SoraError.mediaChannelError(
              reason: "video hard mute operation is in progress"))
          return
        }

        // 同時実行を防ぐための処理中フラグです
        isProcessing = true
        // CameraVideoCapturer.current は stop 実行時に nil になるため
        // restart 用にキャプチャラーを退避します
        let storedCapturer = capturer

        // キューの完了処理です。処理中フラグの無効化と continuation を完了します
        // 状態更新を同一キューで直列化するため queue.async で実行します
        // continuation.resume も同一キュー上で呼ぶようにしています
        func finish(_ error: Error?, update: ((VideoHardMuteSerialQueue) -> Void)? = nil) {
          queue.async { [self] in
            update?(self)
            isProcessing = false
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: ())
            }
          }
        }

        // libwebrtc のカメラ用キューでカメラ操作を非同期実行します
        SoraDispatcher.async(on: .camera) {
          if mute {
            // ミュート有効化
            // 起動中のカメラがあれば停止します
            guard let current = CameraVideoCapturer.current else {
              // 前回のハードミュートでキャプチャラーを退避している場合は冪等として成功扱いにします
              if storedCapturer != nil {
                finish(nil)
              } else {
                // カメラが起動しておらず再開用キャプチャラーも無い場合は失敗にします
                finish(SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable"))
              }
              return
            }

            // CameraVideoCapturer.stop() により映像キャプチャを停止します
            // CameraVideoCapturer.stop() は実行結果を Error? コールバックで返します
            current.stop { error in
              finish(error) { serialQueue in
                // キャプチャラーは再開用として退避します
                serialQueue.capturer = current
              }
            }
            return
          }

          // 既にカメラが起動中であれば何もしません
          if CameraVideoCapturer.current != nil {
            finish(nil)
            return
          }

          // 退避済みのキャプチャラーの存在チェック
          guard let storedCapturer else {
            finish(SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable"))
            return
          }

          // マルチストリームの場合、停止時と現在の送信ストリームが異なることがあるので再設定します
          storedCapturer.stream = senderStream
          // CameraVideoCapturer.restart() により映像キャプチャを再開
          storedCapturer.restart { error in
            finish(error)
          }
        }
      }
    }
  }
}
