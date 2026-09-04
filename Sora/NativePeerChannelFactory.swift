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
  /// 録音ポーズ/再開制御用に保持する ADM ラッパー
  let audioDeviceModuleWrapper: AudioDeviceModuleWrapper?
  /// カスタム音声デバイス (テストから注入されたダミー音声デバイス等)
  let audioDevice: RTCAudioDevice?
  /// 接続が保持する音声セッションの要求
  private let audioSessionRequirement: AudioSessionRequirement?

  var nativeFactory: RTCPeerConnectionFactory

  init(
    bypassVoiceProcessing: Bool,
    audioDevice: RTCAudioDevice? = nil,
    audioSessionUsage: AudioSessionUsage = .none,
    audioSessionCoordinator: AudioSessionCoordinator = .shared
  ) throws {
    Logger.debug(type: .peerChannel, message: "create native peer channel factory")

    let stereoPlayoutEnabled = audioSessionUsage.stereoPlayoutEnabled
    if stereoPlayoutEnabled, audioDevice != nil {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled cannot be used with a custom audio device")
    }
    if audioDevice != nil {
      guard case .custom = audioSessionUsage else {
        throw SoraError.configurationError(
          reason: "a custom audio device requires the custom audio session profile")
      }
    } else if case .custom = audioSessionUsage {
      throw SoraError.configurationError(
        reason: "the custom audio session profile requires a custom audio device")
    }

    // ADM の生成前に profile を予約し、別接続との AudioSession mode 競合を防ぐ。
    // 以降で初期化に失敗した場合は local lease の deinit が要求を解放する。
    let audioSessionRequirement = try audioSessionUsage.profile.map {
      try audioSessionCoordinator.acquire(
        profile: $0,
        requiresPlayAndRecord: audioSessionUsage.requiresPlayAndRecord)
    }
    // 通常の VPIO では共有 template を ADM の生成前に確定する。
    // ステレオでは API 成功後にだけ category を変更するため、後段で登録する。
    if audioSessionUsage.requiresPlayAndRecord, !stereoPlayoutEnabled {
      audioSessionRequirement?.requirePlayAndRecord()
    }

    // 映像コーデックのエンコーダーとデコーダーを用意する
    let encoder = WrapperVideoEncoderFactory.shared
    let decoder = RTCDefaultVideoDecoderFactory()

    if let audioDevice {
      self.audioDevice = audioDevice
      self.audioDeviceModule = nil
      self.audioDeviceModuleWrapper = nil
      self.audioSessionRequirement = audioSessionRequirement
      // カスタム音声デバイス有効時は bypassVoiceProcessing は無視される (Voice Processing 不要のため)
      if bypassVoiceProcessing {
        Logger.warn(
          type: .peerChannel,
          message: "bypassVoiceProcessing is ignored when custom audio device is enabled")
      }
      nativeFactory =
        RTCPeerConnectionFactory(
          encoderFactory: encoder,
          decoderFactory: decoder,
          audioDevice: audioDevice)
    } else {
      if stereoPlayoutEnabled, bypassVoiceProcessing {
        Logger.warn(
          type: .peerChannel,
          message: "bypassVoiceProcessing is ignored when stereo playout is enabled")
      }
      let adm: RTCAudioDeviceModule = RTCAudioDeviceModule(
        bypassVoiceProcessing: stereoPlayoutEnabled ? false : bypassVoiceProcessing)
      if stereoPlayoutEnabled {
        // この API はファクトリー生成後や再生初期化後には呼べないため、ADM の生成直後に実行する。
        let result = adm.setStereoPlayoutEnabled(true)
        try Self.validateStereoPlayoutResult(result)
      }
      self.audioDevice = nil
      self.audioDeviceModule = adm
      self.audioDeviceModuleWrapper = AudioDeviceModuleWrapper(audioDeviceModule: adm)
      // ステレオ化に失敗した場合にカテゴリを変更しないよう、API の成功確認後に登録する。
      if stereoPlayoutEnabled {
        audioSessionRequirement?.requirePlayAndRecord()
      }
      self.audioSessionRequirement = audioSessionRequirement
      nativeFactory =
        RTCPeerConnectionFactory(
          encoderFactory: encoder,
          decoderFactory: decoder,
          audioDeviceModule: adm)
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

  deinit {
    audioSessionRequirement?.release()
  }

  /// ADM のステレオ再生設定結果を SDK のエラーへ変換します。
  static func validateStereoPlayoutResult(_ result: Int) throws {
    guard result == 0 else {
      throw SoraError.mediaChannelError(
        reason: "RTCAudioDeviceModule::setStereoPlayoutEnabled failed (result: \(result))")
    }
  }

  /// 接続終了時に音声セッションの要求を明示的に解放します。
  func releaseAudioSessionRequirement() {
    audioSessionRequirement?.release()
  }

  func createNativePeerChannel(
    configuration: WebRTCConfiguration,
    constraints: MediaConstraints,
    proxy: Proxy? = nil,
    caCertificates: [SecCertificate]? = nil,
    delegate: RTCPeerConnectionDelegate?
  ) -> RTCPeerConnection? {
    let certificateVerifier = createCertificateVerifier(
      configuration: configuration,
      caCertificates: caCertificates)
    if let proxy {
      // proxy ありの overload は certificateVerifier が nullable のため、
      // verifier が不要な場合は nil をそのまま渡せる。
      return nativeFactory.peerConnection(
        with: configuration.nativeValue,
        constraints: constraints.nativeValue,
        certificateVerifier: certificateVerifier,
        delegate: delegate,
        proxyType: RTCProxyType.https,
        proxyAgent: proxy.agent,
        proxyHostname: proxy.host,
        proxyPort: Int32(proxy.port),
        proxyUsername: proxy.username ?? "",
        proxyPassword: proxy.password ?? "")
    } else {
      if let certificateVerifier {
        return nativeFactory.peerConnection(
          with: configuration.nativeValue,
          constraints: constraints.nativeValue,
          certificateVerifier: certificateVerifier,
          delegate: delegate)
      } else {
        // proxy なしの certificateVerifier 付き overload は nullable ではないため、
        // certificateVerifier が不要な場合は certificateVerifier なしの overload を使う。
        return nativeFactory.peerConnection(
          with: configuration.nativeValue,
          constraints: constraints.nativeValue,
          delegate: delegate)
      }
    }
  }

  private func createCertificateVerifier(
    configuration: WebRTCConfiguration,
    caCertificates: [SecCertificate]?
  ) -> RTCSSLCertificateVerifier? {
    if configuration.usesVerifiedTURNTLS {
      return IOSCertificateVerifier(caCertificates: caCertificates)
    }

    return nil
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
