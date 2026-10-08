import Foundation
import WebRTC

// WebRTC の非 Sendable なエンコーダーファクトリーを保持して共有するため、@unchecked Sendable を付与します。
// この型自身の可変状態は simulcastEnabled だけで、その読み書きは lock が排他します (保持する factory の
// 内部状態の thread safety は主張しません)。
final class WrapperVideoEncoderFactory: NSObject, @unchecked Sendable, RTCVideoEncoderFactory {
  static let shared = WrapperVideoEncoderFactory()

  let defaultEncoderFactory: RTCDefaultVideoEncoderFactory

  let simulcastEncoderFactory: RTCVideoEncoderFactorySimulcast

  /// `simulcastEnabled` の読み書きを排他する lock です。
  ///
  /// lock を取得した区間の中では lock 付きの getter / setter を呼ばず、確定値を直接読みます
  /// (非再帰の `NSLock` を再取得して self-deadlock するため)。
  private let lock = NSLock()

  /// `simulcastEnabled` の確定値です。
  private var storedSimulcastEnabled = false

  var currentEncoderFactory: RTCVideoEncoderFactory {
    // lock は `simulcastEnabled` の getter が取って解放します。返した factory への呼び出しも
    // lock の外です。
    simulcastEnabled ? simulcastEncoderFactory : defaultEncoderFactory
  }

  /// サイマルキャストが有効かどうかです。
  ///
  /// 接続開始時 (`PeerChannel.connect`) と `type: offer` の受信時に書き換えられ、libwebrtc が
  /// `supportedCodecs()` / `createEncoder(_:)` から読むため、get / set を lock で排他します。
  var simulcastEnabled: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedSimulcastEnabled
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedSimulcastEnabled = newValue
    }
  }

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
  /// 一時 Offer や redirect の PC 入れ替えで ADM が再初期化されるのを防ぐ、未接続の PC
  private let stereoMediaEngineAnchor: RTCPeerConnection?

  var nativeFactory: RTCPeerConnectionFactory

  #if DEBUG
    /// 直近の `createClientOfferSDP` が生成した一時 `RTCPeerConnection` です。テストの観測にだけ使います。
    ///
    /// 完了 block の末尾で一時 PC を `close()` していることを回帰テストから確認するために参照を
    /// 保持します。`weak` にするのは、Debug 構成の利用者に対して、テスト用の保持が対象の寿命へ
    /// 影響しないようにするためです。テスト側は handler の内側で一時 PC を強参照して保持する
    /// 必要があります (保持しないと `close()` 後の `.closed` を観測できません)。
    /// 直近の 1 個だけを保持するため、この accessor を使うテストは `createClientOfferSDP` を
    /// 1 回だけ呼び、他の呼び出しと重ならないようにします。
    /// 代入と保持は Debug 構成だけで行います。Debug 構成では `createClientOfferSDP` のたびに
    /// weak 代入が 1 回入り、Release では宣言も代入も存在しないため、この accessor も Debug 構成
    /// でのみ参照できます。
    private(set) weak var lastClientOfferPeerConnectionForTesting: RTCPeerConnection?
  #endif

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
      // ステレオ設定は ADM の生成時に渡す。
      let adm: RTCAudioDeviceModule = RTCAudioDeviceModule(
        bypassVoiceProcessing: stereoPlayoutEnabled ? false : bypassVoiceProcessing,
        stereoPlayoutEnabled: stereoPlayoutEnabled)
      self.audioDevice = nil
      self.audioDeviceModule = adm
      let wrapper = AudioDeviceModuleWrapper(audioDeviceModule: adm)
      self.audioDeviceModuleWrapper = wrapper
      // ステレオ化に失敗した場合にカテゴリを変更しないよう、API の成功確認後に登録する。
      if stereoPlayoutEnabled, audioSessionUsage.requiresPlayAndRecord {
        audioSessionRequirement?.requirePlayAndRecord()
      }
      self.audioSessionRequirement = audioSessionRequirement
      let factory: RTCPeerConnectionFactory? =
        RTCPeerConnectionFactory(
          encoderFactory: encoder,
          decoderFactory: decoder,
          audioDeviceModule: adm)
      guard let factory else {
        throw SoraError.mediaChannelError(reason: "failed to create native peer connection factory")
      }
      // m155 以降の ADM は録音の pause/resume を worker スレッド上で実行する契約のため、
      // ハードミュートの実行先として factory を渡す。
      wrapper.bindToFactory(factory)
      nativeFactory = factory
    }

    if stereoPlayoutEnabled {
      // libwebrtc は最後の PC が破棄されると media engine と ADM を Terminate します。
      // 再 Init ではステレオ設定を失うため、音声セッションの要求を解放するまで参照を保ちます。
      // SDP・トラック・DataChannel を設定せず、ネットワーク接続や音声入出力は開始しません。
      guard
        let anchor = nativeFactory.peerConnection(
          with: RTCConfiguration(),
          constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
          delegate: nil)
      else {
        throw SoraError.mediaChannelError(reason: "failed to retain stereo audio media engine")
      }
      stereoMediaEngineAnchor = anchor
    } else {
      stereoMediaEngineAnchor = nil
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
    releaseAudioSessionRequirement()
  }

  /// 接続終了時に音声セッションの要求を明示的に解放します。
  func releaseAudioSessionRequirement() {
    // 共有カテゴリを復元する前に、保持用 PC も close します。
    // media engine の参照自体は、この Factory と保持用 PC の破棄時に解放されます。
    stereoMediaEngineAnchor?.close()
    audioSessionRequirement?.release()
  }

  func createNativePeerChannel(
    webRTCConfiguration: WebRTCConfigurationSnapshot,
    proxy: Proxy? = nil,
    caCertificates: [SecCertificate]? = nil,
    delegate: RTCPeerConnectionDelegate?
  ) -> RTCPeerConnection? {
    let certificateVerifier = createCertificateVerifier(
      webRTCConfiguration: webRTCConfiguration,
      caCertificates: caCertificates)
    if let proxy {
      // proxy ありの overload は certificateVerifier が nullable のため、
      // verifier が不要な場合は nil をそのまま渡せる。
      return nativeFactory.peerConnection(
        with: webRTCConfiguration.nativeValue,
        constraints: webRTCConfiguration.nativeConstraints,
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
          with: webRTCConfiguration.nativeValue,
          constraints: webRTCConfiguration.nativeConstraints,
          certificateVerifier: certificateVerifier,
          delegate: delegate)
      } else {
        // proxy なしの certificateVerifier 付き overload は nullable ではないため、
        // certificateVerifier が不要な場合は certificateVerifier なしの overload を使う。
        return nativeFactory.peerConnection(
          with: webRTCConfiguration.nativeValue,
          constraints: webRTCConfiguration.nativeConstraints,
          delegate: delegate)
      }
    }
  }

  private func createCertificateVerifier(
    webRTCConfiguration: WebRTCConfigurationSnapshot,
    caCertificates: [SecCertificate]?
  ) -> RTCSSLCertificateVerifier? {
    if webRTCConfiguration.usesVerifiedTURNTLS {
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

  /// クライアント Offer SDP 生成の handler と、その生成に使う `RTCPeerConnection` を
  /// 並行処理境界へ渡すための、用途限定の内部ラッパーです。
  ///
  /// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
  /// - 可変状態を持たず、保持する handler と `RTCPeerConnection` の参照は `init` で確定した
  ///   `let` で、box の生存中に再代入されないこと。`RTCPeerConnection` は class であるため、
  ///   ここで主張するのは参照が再代入されないことだけで、オブジェクトの状態の不変性ではない。
  ///   box は参照を保持して callback へ渡すだけで、状態を読み書きしないこと
  /// - 変更前から handler と `RTCPeerConnection` を渡していた `RTCPeerConnection.offer` の
  ///   完了 block をそのまま包み直すだけで、配送先・通知順序・呼び出し回数を変えず、
  ///   別系統の境界へ新たに渡さないこと
  /// - 保持するのは handler の closure と、変更前に同じ block が参照していた `RTCPeerConnection`
  ///   だけで、SDK 内部の参照型 (`NativePeerChannelFactory` 等) を新たに保持しないこと
  ///
  /// 保持する `RTCPeerConnection` は、変更前に完了 block が capture していた参照と同一です。
  /// この参照を保持すると、Offer SDP 生成後の解放が callback の完了まで遅れます。変更前も
  /// 完了 block が同じ参照を capture して `close()` を呼んでいたため callback の完了までは
  /// 生存しており、その参照をそのまま使うため、この遅延を許容します。`RTCPeerConnection` の
  /// `close()` は完了 block の内側で行う必要があり、`Sendable` な値へ写すことはできません。
  /// この callback の実行スレッドと配送は変更前と同じです。
  ///
  /// 生成は `createClientOfferSDP` の 1 箇所だけで、1 つの block へ 1 回だけ渡して 1 回だけ
  /// 実行する使用契約です (型では強制されません)。`Sendable` にするのはこの入れ物だけで、
  /// handler とその捕捉状態を `Sendable` にはしません。捕捉状態の所有と同期は、呼び出し
  /// スレッドを保証しない既存の挙動の下で利用者の責務です。実行スレッドの同一性・直列性も
  /// 契約にしません。
  private final class ClientOfferSDPCreationContext: @unchecked Sendable {
    let handler: (String?, (any Error)?) -> Void
    let peerConnection: RTCPeerConnection

    init(
      handler: @escaping (String?, (any Error)?) -> Void,
      peerConnection: RTCPeerConnection
    ) {
      self.handler = handler
      self.peerConnection = peerConnection
    }
  }

  // クライアント情報としての Offer SDP を生成する
  func createClientOfferSDP(
    webRTCConfiguration: WebRTCConfigurationSnapshot,
    handler: @escaping (String?, (any Error)?) -> Void
  ) {
    let peer = createNativePeerChannel(
      webRTCConfiguration: webRTCConfiguration, delegate: nil)

    // `guard let peer = peer {` と書いた場合、 Xcode 12.5 でビルド・エラーになった
    guard let tempPeer = peer else {
      handler(nil, SoraError.peerChannelError(reason: "createNativePeerChannel failed"))
      return
    }

    #if DEBUG
      // 観測用に保持する
      lastClientOfferPeerConnectionForTesting = tempPeer
    #endif

    let stream = createNativeSenderStream(
      streamId: "offer",
      videoTrackId: "video",
      audioTrackId: "audio",
      constraints: webRTCConfiguration.constraints)
    tempPeer.add(stream.videoTracks[0], streamIds: [stream.streamId])
    tempPeer.add(stream.audioTracks[0], streamIds: [stream.streamId])
    // handler は公開 API のため `@Sendable` にできず、 tempPeer は完了 block の内側で `close()` を
    // 呼ぶ必要があって値へ写せないため、両者を不変の参照保持 box へ移し、完了 block には
    // box (Sendable) だけを capture させます。
    let context = ClientOfferSDPCreationContext(
      handler: handler, peerConnection: tempPeer)
    tempPeer.offer(for: webRTCConfiguration.nativeConstraints) { sdp, error in
      if let error {
        context.handler(nil, error)
      } else if let sdp {
        context.handler(sdp.sdp, nil)
      } else {
        context.handler(nil, SoraError.peerChannelError(reason: "offer creation failed"))
      }
      context.peerConnection.close()
    }
  }
}
