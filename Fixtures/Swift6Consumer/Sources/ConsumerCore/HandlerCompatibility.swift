// 検査する契約:
//   - 非推奨でない公開 handler の closure 型に @Sendable が付いていないため、
//     nonisolated な文脈から closure を代入できること
//   - VideoRenderer を nonisolated な型で実装し、MediaStream へ設定できること
// 期待する診断: なし (error 0 件、warning 0 件)
import AVFoundation
import Foundation
import Sora
import WebRTC

/// Sora の handler を代入する。
func makeSoraHandlers() -> SoraHandlers {
  let handlers = SoraHandlers()
  handlers.onConnect = { mediaChannel, error in
    _ = mediaChannel
    _ = error
  }
  handlers.onDisconnect = { mediaChannel, error in
    _ = mediaChannel
    _ = error
  }
  handlers.onAddMediaChannel = { mediaChannel in
    _ = mediaChannel
  }
  handlers.onRemoveMediaChannel = { mediaChannel in
    _ = mediaChannel
  }
  handlers.onChangeAudioRoute = { session, reason, route in
    _ = session
    _ = reason
    _ = route
  }
  return handlers
}

/// MediaChannel の handler を代入する。
func makeMediaChannelHandlers() -> MediaChannelHandlers {
  let handlers = MediaChannelHandlers()
  handlers.onConnect = { error in
    _ = error
  }
  handlers.onDisconnect = { event in
    _ = event
  }
  handlers.onAddStream = { mediaStream in
    _ = mediaStream
  }
  handlers.onRemoveStream = { mediaStream in
    _ = mediaStream
  }
  handlers.onReceiveSignalingJSON = { json in
    _ = json
  }
  handlers.onDataChannel = { mediaChannel in
    _ = mediaChannel
  }
  handlers.onDataChannelOpened = { mediaChannel, label in
    _ = mediaChannel
    _ = label
  }
  handlers.onDataChannelMessage = { mediaChannel, label, data in
    _ = mediaChannel
    _ = label
    _ = data
  }
  return handlers
}

/// MediaStream の handler を代入する。
/// handlers は get のみのため、取得した instance をそのまま使う。
func configure(_ handlers: MediaStreamHandlers) {
  handlers.onSwitchVideo = { isEnabled in
    _ = isEnabled
  }
  handlers.onSwitchAudio = { isEnabled in
    _ = isEnabled
  }
}

/// CameraVideoCapturer の handler を代入する。
/// onCapture は VideoFrame を返す closure 型のため、そのまま frame を返す。
func makeCameraVideoCapturerHandlers() -> CameraVideoCapturerHandlers {
  let handlers = CameraVideoCapturerHandlers()
  handlers.onCapture = { capturer, videoFrame in
    _ = capturer
    return videoFrame
  }
  handlers.onStart = { capturer in
    _ = capturer
  }
  handlers.onStop = { capturer in
    _ = capturer
  }
  return handlers
}

/// WebSocketChannel の handler を代入する。
func makeWebSocketChannelHandlers() -> WebSocketChannelHandlers {
  let handlers = WebSocketChannelHandlers()
  handlers.onReceive = { message in
    _ = message
  }
  return handlers
}

/// 接続設定に handler を設定する。
func attachHandlers(to configuration: inout Configuration) {
  configuration.webSocketChannelHandlers = makeWebSocketChannelHandlers()
  configuration.mediaChannelHandlers = makeMediaChannelHandlers()
}

/// VideoRenderer の nonisolated な実装。
final class ConsoleVideoRenderer: VideoRenderer {
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

/// MediaStream へ renderer と handler を設定し、公開プロパティを参照する。
func attach(renderer: VideoRenderer, to mediaStream: MediaStream) {
  // handlers は get のみのため、取得した instance の closure を差し替える
  configure(mediaStream.handlers)
  mediaStream.videoRenderer = renderer
  mediaStream.videoEnabled = true
  mediaStream.audioEnabled = true
  _ = mediaStream.streamId
  _ = mediaStream.creationTime
  _ = mediaStream.hasVideoTrack
  _ = mediaStream.hasAudioTrack
  _ = mediaStream.mediaChannel
  mediaStream.terminate()
}
