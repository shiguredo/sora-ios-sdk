import Foundation
import WebRTC

// WebRTC のエンコーダーファクトリーを共有して扱うため、 @unchecked Sendable を付与します。
final class WrapperVideoEncoderFactory: NSObject, @unchecked Sendable, RTCVideoEncoderFactory {
  static let shared = WrapperVideoEncoderFactory()

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

// WebRTC の非 Sendable オブジェクトを保持するため、
// 呼び出し側でスレッド安全性を担保する前提で @unchecked Sendable を付与します。
final class NativePeerChannelFactory: @unchecked Sendable {
  let audioDeviceModule: RTCAudioDeviceModule?
  let customAudioDevice: RTCAudioDevice?
  /// 録音ミュート制御用に保持するラッパー
  let audioInputMuteController: AudioInputMuteController?

  var nativeFactory: RTCPeerConnectionFactory

  var usesCustomAudioDevice: Bool {
    customAudioDevice != nil
  }

  init(bypassVoiceProcessing: Bool, customAudioDevice: RTCAudioDevice? = nil) {
    Logger.debug(type: .peerChannel, message: "create native peer channel factory")
    self.customAudioDevice = customAudioDevice

    // 映像コーデックのエンコーダーとデコーダーを用意する
    let encoder = WrapperVideoEncoderFactory.shared
    let decoder = RTCDefaultVideoDecoderFactory()
    if let customAudioDevice {
      // カスタム ADM を使用する
      audioDeviceModule = nil
      if let audioInputMuteControllable = customAudioDevice as? AudioInputMuteControllable {
        audioInputMuteController = AudioInputMuteControllableWrapper(
          audioInputMuteControllable: audioInputMuteControllable)
      } else {
        audioInputMuteController = nil
      }
      nativeFactory =
        RTCPeerConnectionFactory(
          encoderFactory: encoder,
          decoderFactory: decoder,
          audioDevice: customAudioDevice)
    } else {
      guard
        let createdAudioDeviceModule = RTCAudioDeviceModule(
          bypassVoiceProcessing: bypassVoiceProcessing)
      else {
        fatalError("RTCAudioDeviceModule の生成に失敗しました")
      }
      self.audioDeviceModule = createdAudioDeviceModule
      audioInputMuteController = AudioDeviceModuleWrapper(
        audioDeviceModule: createdAudioDeviceModule)
      nativeFactory =
        RTCPeerConnectionFactory(
          encoderFactory: encoder,
          decoderFactory: decoder,
          audioDeviceModule: createdAudioDeviceModule)
    }

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
    peer2.offer(for: constraints.nativeValue) { sdp, error in
      if let error {
        handler(nil, error)
      } else if let sdp {
        handler(sdp.sdp, nil)
      } else {
        handler(nil, SoraError.peerChannelError(reason: "offer creation failed"))
      }
      peer2.close()
    }
  }
}
