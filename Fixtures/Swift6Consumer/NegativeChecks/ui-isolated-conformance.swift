// EXPECT-DIAGNOSTIC: IsolatedConformances
// 検査する契約: 既定隔離が MainActor の文脈で宣言した型は VideoRenderer の
// conformance も MainActor に隔離されるため、nonisolated な文脈では使えないこと。
// 期待する診断: IsolatedConformances (error)
// この file はどの target にも含めない。
import Sora
import UIKit

final class MainActorRenderer: VideoRenderer {
  func onChange(size: CGSize) {
    _ = size
  }

  func render(videoFrame: VideoFrame?) {
    _ = videoFrame
  }

  func onDisconnect(from mediaChannel: MediaChannel?) {
    _ = mediaChannel
  }

  func onAdded(from mediaStream: MediaStream) {
    _ = mediaStream
  }

  func onRemoved(from mediaStream: MediaStream) {
    _ = mediaStream
  }

  func onSwitch(video: Bool) {
    _ = video
  }

  func onSwitch(audio: Bool) {
    _ = audio
  }
}

nonisolated func useIsolatedRenderer(_ mediaStream: MediaStream) {
  let renderer = MainActorRenderer()
  mediaStream.videoRenderer = renderer
}
