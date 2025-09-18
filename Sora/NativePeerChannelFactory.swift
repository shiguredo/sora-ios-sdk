import Foundation
import WebRTC

class WrapperVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
  static var shared = WrapperVideoEncoderFactory()

  var defaultEncoderFactory: RTCDefaultVideoEncoderFactory

  var simulcastEncoderFactory: RTCVideoEncoderFactorySimulcast

  var currentEncoderFactory: RTCVideoEncoderFactory {
    simulcastEnabled ? simulcastEncoderFactory : defaultEncoderFactory
  }

  var simulcastEnabled = false

  override init() {
    // Sora iOS SDK では VP8, VP9, H.264 が有効
    defaultEncoderFactory = RTCDefaultVideoEncoderFactory()
    simulcastEncoderFactory = RTCVideoEncoderFactorySimulcast(
      primary: defaultEncoderFactory, fallback: defaultEncoderFactory)
  }

  func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
    currentEncoderFactory.createEncoder(info)
  }

  func supportedCodecs() -> [RTCVideoCodecInfo] {
    currentEncoderFactory.supportedCodecs()
  }
}

class NativePeerChannelFactory {
  static var `default` = NativePeerChannelFactory()

  var nativeFactory: RTCPeerConnectionFactory

  init() {
    Logger.debug(type: .peerChannel, message: "create native peer channel factory")

    // 映像コーデックのエンコーダーとデコーダーを用意する
    let encoder = WrapperVideoEncoderFactory.shared
    let decoder = RTCDefaultVideoDecoderFactory()
    nativeFactory =
      RTCPeerConnectionFactory(
        encoderFactory: encoder,
        decoderFactory: decoder)

    for info in encoder.supportedCodecs() {
      Logger.debug(
        type: .peerChannel,
        message: "supported video encoder: \(info.name) \(info.parameters)")
    }
    for info in decoder.supportedCodecs() {
      Logger.debug(
        type: .peerChannel,
        message: "supported video decoder: \(info.name) \(info.parameters)")
    }
  }

  func createNativePeerChannel(
    configuration: WebRTCConfiguration,
    constraints: MediaConstraints,
    proxy: Proxy? = nil,
    delegate: RTCPeerConnectionDelegate?
  ) -> RTCPeerConnection? {
    if let proxy {
      return nativeFactory.peerConnection(
        with: configuration.nativeValue,
        constraints: constraints.nativeValue,
        certificateVerifier: nil,
        delegate: delegate,
        proxyType: RTCProxyType.https,
        proxyAgent: proxy.agent,
        proxyHostname: proxy.host,
        proxyPort: Int32(proxy.port),
        proxyUsername: proxy.username ?? "",
        proxyPassword: proxy.password ?? "")
    } else {
      return nativeFactory.peerConnection(
        with: configuration.nativeValue, constraints: constraints.nativeValue,
        delegate: delegate)
    }
  }

  func createNativeStream(streamId: String) -> RTCMediaStream {
    nativeFactory.mediaStream(withStreamId: streamId)
  }

  func createNativeVideoSource() -> RTCVideoSource {
    nativeFactory.videoSource()
  }

  func createNativeVideoTrack(
    videoSource: RTCVideoSource,
    trackId: String
  ) -> RTCVideoTrack {
    nativeFactory.videoTrack(with: videoSource, trackId: trackId)
  }

  func createNativeAudioSource(constraints: MediaConstraints?) -> RTCAudioSource {
    nativeFactory.audioSource(with: constraints?.nativeValue)
  }

  func createNativeAudioTrack(
    trackId: String,
    constraints: RTCMediaConstraints
  ) -> RTCAudioTrack {
    let audioSource = nativeFactory.audioSource(with: constraints)
    return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
  }

  func createNativeSenderStream(
    streamId: String,
    videoTrackId: String?,
    audioTrackId: String?,
    constraints: MediaConstraints
  ) -> RTCMediaStream {
    Logger.debug(
      type: .nativePeerChannel,
      message: "create native sender stream (\(streamId))")
    let nativeStream = createNativeStream(streamId: streamId)

    if let trackId = videoTrackId {
      Logger.debug(
        type: .nativePeerChannel,
        message: "create native video track (\(trackId))")
      let videoSource = createNativeVideoSource()
      let videoTrack = createNativeVideoTrack(
        videoSource: videoSource,
        trackId: trackId)
      nativeStream.addVideoTrack(videoTrack)
    }

    if let trackId = audioTrackId {
      Logger.debug(
        type: .nativePeerChannel,
        message: "create native audio track (\(trackId))")
      let audioTrack = createNativeAudioTrack(
        trackId: trackId,
        constraints: constraints.nativeValue)
      nativeStream.addAudioTrack(audioTrack)
    }

    return nativeStream
  }

  // クライアント情報としての Offer SDP を生成する
  func createClientOfferSDP(
    configuration: WebRTCConfiguration,
    constraints: MediaConstraints,
    handler: @escaping (String?, Error?) -> Void
  ) {
    let peer = createNativePeerChannel(
      configuration: configuration, constraints: constraints, delegate: nil)

    // `guard let peer = peer {` と書いた場合、 Xcode 12.5 でビルド・エラーになった
    guard let peer2 = peer else {
      handler(nil, SoraError.peerChannelError(reason: "createNativePeerChannel failed"))
      return
    }

    let stream = createNativeSenderStream(
      streamId: "offer",
      videoTrackId: "video",
      audioTrackId: "audio",
      constraints: constraints)
    peer2.add(stream.videoTracks[0], streamIds: [stream.streamId])
    peer2.add(stream.audioTracks[0], streamIds: [stream.streamId])
    Task {
      do {
        let sdp = try await peer2.offer(for: constraints.nativeValue)
        handler(sdp.sdp, nil)
      } catch {
        handler(nil, error)
      }
      peer2.close()
    }
  }
}
