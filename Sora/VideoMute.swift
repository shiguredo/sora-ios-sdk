import Foundation

// 映像ハードミュートの同時呼び出しを防ぐためのシリアルキュークラスです
// 同時に呼び出された場合はエラーになります
final class VideoHardMuteSerialQueue {
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.video.hardmute")

  private var isProcessing = false
  private var capturer: CameraVideoCapturer?

  func set(mute: Bool, senderStream: MediaStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard !isProcessing else {
          continuation.resume(
            throwing: SoraError.mediaChannelError(
              reason: "video hard mute operation is in progress"))
          return
        }

        isProcessing = true
        let cachedCapturer = capturer

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

        SoraDispatcher.async(on: .camera) {
          if mute {
            guard let current = CameraVideoCapturer.current else {
              if cachedCapturer != nil {
                finish(nil)
              } else {
                finish(SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable"))
              }
              return
            }

            current.stop { error in
              finish(error) { serialQueue in
                serialQueue.capturer = current
              }
            }
            return
          }

          if CameraVideoCapturer.current != nil {
            finish(nil)
            return
          }

          guard let cachedCapturer else {
            finish(SoraError.mediaChannelError(reason: "CameraVideoCapturer is unavailable"))
            return
          }

          cachedCapturer.stream = senderStream
          cachedCapturer.restart { error in
            finish(error)
          }
        }
      }
    }
  }
}
