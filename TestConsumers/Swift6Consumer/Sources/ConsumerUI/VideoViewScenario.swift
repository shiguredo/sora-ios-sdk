// 検査する契約:
//   - target の default actor isolation が MainActor であること。
//     この file に @MainActor を書かずに、UIView 継承で MainActor 隔離を持つ
//     VideoView を生成して操作できることが検証条件である。
// 期待する診断: なし (error 0 件、warning 0 件)
import Sora
import UIKit

/// VideoView を生成して再生を開始し、公開プロパティを参照する。
func useVideoView() {
  let videoView = VideoView(frame: .zero)
  videoView.connectionMode = .autoClear
  videoView.backgroundView = UIView(frame: .zero)
  videoView.debugMode = false
  videoView.start()
  videoView.stop()
  videoView.clear()
  _ = videoView.isRendering
  _ = videoView.currentVideoFrameSize
}

/// MediaStream へ VideoView を renderer として設定する。
func attachVideoView(to mediaStream: MediaStream) {
  let videoView = VideoView(frame: .zero)
  mediaStream.videoRenderer = videoView
}
