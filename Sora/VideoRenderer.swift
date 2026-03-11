import Foundation
import WebRTC

private final class VideoRendererSizeEvent: @unchecked Sendable {
  weak var renderer: VideoRenderer?
  let size: CGSize

  init(renderer: VideoRenderer?, size: CGSize) {
    self.renderer = renderer
    self.size = size
  }
}

private final class VideoRendererFrameEvent: @unchecked Sendable {
  weak var renderer: VideoRenderer?
  let videoFrame: VideoFrame?

  init(renderer: VideoRenderer?, videoFrame: VideoFrame?) {
    self.renderer = renderer
    self.videoFrame = videoFrame
  }
}

/// 映像の描画に必要な機能を定義したプロトコルです。
public protocol VideoRenderer: AnyObject {
  /// 映像のサイズが変更されたときに呼ばれます。
  /// - parameter size: 変更後のサイズ
  func onChange(size: CGSize)
  /// 映像フレームを描画します。
  /// - parameter videoFrame: 描画する映像フレーム
  func render(videoFrame: VideoFrame?)
  /// 接続解除時に呼ばれます。
  /// - parameter from: 接続解除するメディアチャンネル
  func onDisconnect(from: MediaChannel?)
  /// ストリームへの追加時に呼ばれます。
  /// - parameter from: 追加されるストリーム
  func onAdded(from: MediaStream)
  /// ストリームからの除去時に呼ばれます。
  /// - parameter from: 除去されるストリーム
  func onRemoved(from: MediaStream)
  /// 映像の可否の設定の変更時に呼ばれます。
  /// - parameter video: 映像の可否
  func onSwitch(video: Bool)
  /// 音声の可否の設定の変更時に呼ばれます。
  /// - parameter audio: 音声の可否
  func onSwitch(audio: Bool)
}

class VideoRendererAdapter: NSObject, RTCVideoRenderer {
  private(set) weak var videoRenderer: VideoRenderer?

  init(videoRenderer: VideoRenderer) {
    self.videoRenderer = videoRenderer
  }

  // TODO(zztkm): VideoView / VideoRenderer の MainActor 整合性は別途根本対応する。
  // Swift 6 ビルドを優先し、描画とサイズ変更だけを main thread に受け渡します。
  func setSize(_ size: CGSize) {
    if let renderer = videoRenderer {
      Logger.debug(
        type: .videoRenderer,
        message: "set size \(size) for \(renderer)")
      let event = VideoRendererSizeEvent(renderer: renderer, size: size)
      DispatchQueue.main.async { [event] in
        event.renderer?.onChange(size: event.size)
      }
    } else {
      Logger.debug(
        type: .videoRenderer,
        message: "set size \(size) IGNORED, no renderer set")
    }
  }

  func renderFrame(_ frame: RTCVideoFrame?) {
    let videoFrame = frame.map { VideoFrame.native(capturer: nil, frame: $0) }
    let event = VideoRendererFrameEvent(renderer: videoRenderer, videoFrame: videoFrame)
    DispatchQueue.main.async { [event] in
      event.renderer?.render(videoFrame: event.videoFrame)
    }
  }
}
