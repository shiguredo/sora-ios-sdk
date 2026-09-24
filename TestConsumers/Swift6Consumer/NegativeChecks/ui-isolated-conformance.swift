// EXPECT-DIAGNOSTIC: IsolatedConformances
// 検査する契約: 既定隔離が MainActor の文脈で宣言した型は VideoRenderer の
// conformance も MainActor に隔離されるため、nonisolated な文脈では使えないこと。
// この file はどの target にも含めない。
import Sora
import UIKit

final class MainActorRenderer: VideoRenderer {
  func onChange(size: CGSize) {}

  func render(videoFrame: VideoFrame?) {}

  func onDisconnect(from mediaChannel: MediaChannel?) {}

  func onAdded(from mediaStream: MediaStream) {}

  func onRemoved(from mediaStream: MediaStream) {}

  func onSwitch(video: Bool) {}

  func onSwitch(audio: Bool) {}
}

nonisolated func useIsolatedRenderer(_ mediaStream: MediaStream) {
  let renderer = MainActorRenderer()
  mediaStream.videoRenderer = renderer
}
