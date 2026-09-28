// 検査する契約:
//   - 非推奨でない公開 handler の closure 型に @Sendable が付いていないため、
//     nonisolated な文脈から非 Sendable な値を capture した closure を代入できること
//   - VideoRenderer を nonisolated な型で実装し、MediaStream へ設定できること
//   - WebRTC product を import できること (Sora の binaryTarget を consumer が参照できること)
// 期待する診断: なし (error 0 件、warning 0 件)
import Foundation
import Sora
import WebRTC

/// Sora の handler を代入する。
/// 各 handler 型につき 1 つは外側の非 Sendable な値を capture し、
/// closure 型に @Sendable が付いた場合に検出できるようにする。
func makeSoraHandlers(mediaChannel: MediaChannel) -> SoraHandlers {
  let handlers = SoraHandlers()
  handlers.onConnect = { _, error in
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
func makeMediaChannelHandlers(mediaChannel: MediaChannel) -> MediaChannelHandlers {
  let handlers = MediaChannelHandlers()
  handlers.onConnect = { error in
    _ = mediaChannel
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
func configure(_ handlers: MediaStreamHandlers, capturing mediaStream: MediaStream) {
  handlers.onSwitchVideo = { isEnabled in
    _ = mediaStream
    _ = isEnabled
  }
  handlers.onSwitchAudio = { isEnabled in
    _ = isEnabled
  }
}

/// CameraVideoCapturer の handler を代入する。
/// onCapture は VideoFrame を返す closure 型のため、そのまま frame を返す。
func makeCameraVideoCapturerHandlers(mediaChannel: MediaChannel) -> CameraVideoCapturerHandlers {
  let handlers = CameraVideoCapturerHandlers()
  handlers.onCapture = { capturer, videoFrame in
    _ = capturer
    return videoFrame
  }
  handlers.onStart = { capturer in
    _ = mediaChannel
    _ = capturer
  }
  handlers.onStop = { capturer in
    _ = capturer
  }
  return handlers
}

/// WebSocketChannel の handler を代入する。
func makeWebSocketChannelHandlers(mediaChannel: MediaChannel) -> WebSocketChannelHandlers {
  let handlers = WebSocketChannelHandlers()
  handlers.onReceive = { message in
    _ = mediaChannel
    _ = message
  }
  return handlers
}

/// 接続設定に handler を設定する。
func attachHandlers(to configuration: inout Configuration, mediaChannel: MediaChannel) {
  configuration.webSocketChannelHandlers = makeWebSocketChannelHandlers(mediaChannel: mediaChannel)
  configuration.mediaChannelHandlers = makeMediaChannelHandlers(mediaChannel: mediaChannel)
}

/// VideoRenderer の nonisolated な空実装 (描画は行わない)。
final class EmptyVideoRenderer: VideoRenderer {
  func onChange(size: CGSize) {}

  func render(videoFrame: VideoFrame?) {}

  func onDisconnect(from mediaChannel: MediaChannel?) {}

  func onAdded(from mediaStream: MediaStream) {}

  func onRemoved(from mediaStream: MediaStream) {}

  func onSwitch(video: Bool) {}

  func onSwitch(audio: Bool) {}
}

/// MediaStream へ renderer と handler を設定し、公開プロパティを参照する。
func attach(renderer: VideoRenderer, to mediaStream: MediaStream) {
  configure(mediaStream.handlers, capturing: mediaStream)
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
