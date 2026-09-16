import Foundation
import Security
import WebRTC

/// ICE サーバーの設定を接続開始時に写し取った値です。
///
/// `ICEServerInfo` は可変 class のため、接続開始後に利用者側で変更されても
/// 影響を受けないよう値として保持します。
struct ICEServerSnapshot: Sendable {
  /// URL のリスト
  let urls: [String]

  /// ユーザー名
  ///
  /// `ICEServerInfo` の `userName` は非推奨となり `username` へ移行する予定のため、
  /// snapshot 側は `username` とする。
  let username: String?

  /// クレデンシャル
  let credential: String?

  /// TURN-TLS のポリシーが insecure かどうか
  ///
  /// `ICEServerInfo.tlsSecurityPolicy` の真値です。
  let isTLSInsecure: Bool

  /// 初期化します。
  init(urls: [String], username: String?, credential: String?, isTLSInsecure: Bool) {
    self.urls = urls
    self.username = username
    self.credential = credential
    self.isTLSInsecure = isTLSInsecure
  }

  /// `ICEServerInfo` から写し取ります。
  init(_ info: ICEServerInfo) {
    // tlsSecurityPolicy は非推奨のため、読み取りはここ 1 箇所に閉じる。
    self.init(
      urls: info.urls,
      username: info.userName,
      credential: info.credential,
      isTLSInsecure: info.tlsSecurityPolicy == .insecure)
  }

  /// `RTCIceServer` を生成します。
  /// - parameter insecure: 接続設定の `insecure`
  func nativeValue(insecure: Bool) -> RTCIceServer {
    RTCIceServer(
      urlStrings: urls,
      username: username,
      credential: credential,
      tlsCertPolicy: insecure || isTLSInsecure ? .insecureNoCheck : .secure)
  }

  /// TURN-TLS の検証を行うかどうか
  var usesVerifiedTURNTLS: Bool {
    if isTLSInsecure {
      return false
    }
    return urls.contains { url in
      url.lowercased().hasPrefix("turns:")
    }
  }
}

/// WebRTC の設定を接続開始時に写し取った値です。
struct WebRTCConfigurationSnapshot: Sendable {
  /// メディア制約
  let constraints: MediaConstraints

  /// ICE サーバー情報のリスト
  let iceServerInfos: [ICEServerSnapshot]

  /// ICE 通信ポリシー
  let iceTransportPolicy: ICETransportPolicy

  /// SDP でのマルチストリームの記述方式
  let sdpSemantics: SDPSemantics

  /// 送信する映像の品質が維持できない場合の挙動
  let degradationPreference: DegradationPreference?

  /// `Configuration.insecure` に対応する内部フラグ
  let isInsecure: Bool

  /// 初期化します。
  init(
    constraints: MediaConstraints,
    iceServerInfos: [ICEServerSnapshot],
    iceTransportPolicy: ICETransportPolicy,
    sdpSemantics: SDPSemantics,
    degradationPreference: DegradationPreference?,
    isInsecure: Bool
  ) {
    self.constraints = constraints
    self.iceServerInfos = iceServerInfos
    self.iceTransportPolicy = iceTransportPolicy
    self.sdpSemantics = sdpSemantics
    self.degradationPreference = degradationPreference
    self.isInsecure = isInsecure
  }

  /// `WebRTCConfiguration` から写し取ります。
  init(_ configuration: WebRTCConfiguration) {
    // 接続所有の設定は offer を受信するまで insecure にしない。
    // (一時 offer の生成に Configuration.insecure を反映しない既存挙動を保つ)
    self.init(
      constraints: configuration.constraints,
      iceServerInfos: configuration.iceServerInfos.map(ICEServerSnapshot.init),
      iceTransportPolicy: configuration.iceTransportPolicy,
      sdpSemantics: configuration.sdpSemantics,
      degradationPreference: configuration.degradationPreference,
      isInsecure: false)
  }

  /// `RTCConfiguration` を生成します。
  ///
  /// `RTCConfiguration` は Objective-C の class で `Sendable` ではないため、
  /// stored property ではなく computed property として生成します。
  var nativeValue: RTCConfiguration {
    let config = RTCConfiguration()
    config.iceServers = iceServerInfos.map { info in
      info.nativeValue(insecure: isInsecure)
    }
    config.iceTransportPolicy = iceTransportPolicy.nativeValue
    config.sdpSemantics = sdpSemantics.nativeValue

    // AES-GCM を有効にする
    config.cryptoOptions = RTCCryptoOptions(
      srtpEnableGcmCryptoSuites: true,
      srtpPreferGcmCryptoSuites: true,
      srtpEnableAes128Sha1_32CryptoCipher: false,
      srtpEnableAes128Sha1_80CryptoCipher: false,
      srtpEnableEncryptedRtpHeaderExtensions: false,
      sframeRequireFrameEncryption: false)
    return config
  }

  /// `RTCMediaConstraints` を生成します。
  var nativeConstraints: RTCMediaConstraints { constraints.nativeValue }

  /// 一部のフィールドを差し替えた新しい値を返します。
  ///
  /// stored property がすべて `let` のため、offer 受信時の更新はこの関数で
  /// 新しい値を作って代入します。
  func replacing(
    iceServerInfos: [ICEServerSnapshot]? = nil,
    iceTransportPolicy: ICETransportPolicy? = nil,
    isInsecure: Bool? = nil
  ) -> WebRTCConfigurationSnapshot {
    WebRTCConfigurationSnapshot(
      constraints: constraints,
      iceServerInfos: iceServerInfos ?? self.iceServerInfos,
      iceTransportPolicy: iceTransportPolicy ?? self.iceTransportPolicy,
      sdpSemantics: sdpSemantics,
      degradationPreference: degradationPreference,
      isInsecure: isInsecure ?? self.isInsecure)
  }

  /// TURN-TLS の検証を行うかどうか
  var usesVerifiedTURNTLS: Bool {
    if isInsecure {
      return false
    }
    return iceServerInfos.contains { info in
      info.usesVerifiedTURNTLS
    }
  }
}

/// 転送フィルターの設定を接続開始時に写し取った値です。
struct ForwardingFilterSnapshot: Sendable {
  /// name
  let name: String?

  /// priority
  let priority: Int?

  /// action
  let action: ForwardingFilterAction?

  /// rules
  let rules: [[ForwardingFilterRule]]

  /// version
  let version: String?

  /// metadata
  let metadata: JSONValue?

  /// 初期化します。
  init(
    name: String?,
    priority: Int?,
    action: ForwardingFilterAction?,
    rules: [[ForwardingFilterRule]],
    version: String?,
    metadata: JSONValue?
  ) {
    self.name = name
    self.priority = priority
    self.action = action
    self.rules = rules
    self.version = version
    self.metadata = metadata
  }

  /// `ForwardingFilter` から写し取ります。
  init(_ forwardFilter: ForwardingFilter) throws {
    let metadata = try forwardFilter.metadata.map { value in
      try JSONValue.from(
        value, errorReason: ConfigurationSnapshotErrorReason.forwardingFilterMetadata)
    }
    self.init(
      name: forwardFilter.name,
      priority: forwardFilter.priority,
      action: forwardFilter.action,
      rules: forwardFilter.rules,
      version: forwardFilter.version,
      metadata: metadata)
  }

  /// `ForwardingFilter` へ戻します。
  ///
  /// `ForwardingFilter.metadata` は `Encodable?` のため、`Encodable` に準拠する
  /// `JSONValue` をそのまま渡せます。
  func forwardingFilter() -> ForwardingFilter {
    ForwardingFilter(
      name: name,
      priority: priority,
      action: action,
      rules: rules,
      version: version,
      metadata: metadata)
  }
}

/// `ConnectionConfigurationSnapshot` の変換に失敗したときの理由です。
///
/// `SoraError.configurationError` の理由は利用者に見えるため、キー名と失敗種別だけを
/// 含めます。元のエラーの説明文は値や codingPath を含むことがあるため使いません。
private enum ConfigurationSnapshotErrorReason {
  static let signalingConnectMetadata = "signaling connect metadata could not be encoded"
  static let signalingConnectNotifyMetadata =
    "signaling notify metadata could not be encoded"
  static let forwardingFilterMetadata = "forwarding filter metadata could not be encoded"
  static let dataChannels = "data channels are not JSON-serializable"
  static let audioOpusParams = "audio opus params could not be encoded"

  static func videoParams(_ name: String) -> String {
    "video \(name) params could not be encoded"
  }
}

/// 接続設定を接続開始時に写し取った値です。
///
/// 接続開始後に走る非同期処理は、利用者所有の可変値ではなくこの値だけを参照します。
/// mutable な handler bag と `RTCAudioDevice` は含めません。
struct ConnectionConfigurationSnapshot: Sendable {
  // MARK: 接続に関する設定

  let urlCandidates: [URL]
  let channelId: String
  let clientId: String?
  let bundleId: String?
  let role: Role
  let multistreamEnabled: Bool?
  let isMultistream: Bool
  let isSender: Bool
  let connectionTimeout: Int

  // MARK: メディアに関する設定

  let videoCodec: VideoCodec
  let videoBitRate: Int?
  let audioCodec: AudioCodec
  let audioBitRate: Int?
  let videoEnabled: Bool
  let audioEnabled: Bool
  let audioStereoOutputEnabled: Bool
  let initialCameraEnabled: Bool
  let initialMicrophoneEnabled: Bool
  let bypassVoiceProcessing: Bool
  let cameraSettings: CameraSettings

  // MARK: スポットライトに関する設定

  let isSpotlightEnabled: Bool
  let spotlightNumber: Int?
  let spotlightFocusRid: SpotlightRid
  let spotlightUnfocusRid: SpotlightRid

  // MARK: サイマルキャストに関する設定

  let simulcastEnabled: Bool
  let simulcastRid: SimulcastRid?
  let simulcastRequestRid: SimulcastRequestRid

  // MARK: シグナリングに関する設定

  let dataChannelSignaling: Bool?
  let ignoreDisconnectWebSocket: Bool?
  let audioStreamingLanguageCode: String?
  let proxy: Proxy?
  let insecure: Bool
  let caCertificate: String?
  let signalingConnectMetadata: JSONValue?
  let signalingConnectNotifyMetadata: JSONValue?
  let dataChannelSettings: JSONValue?
  let forwardingFilter: ForwardingFilterSnapshot?
  let forwardingFilters: [ForwardingFilterSnapshot]?
  let webRTCConfiguration: WebRTCConfigurationSnapshot

  // MARK: コーデック別パラメーター (connect message に載るものだけ)

  let videoVp9Params: JSONValue?
  let videoAv1Params: JSONValue?
  let videoH264Params: JSONValue?
  let videoH265Params: JSONValue?
  let audioOpusParams: JSONValue?

  // MARK: 派生値

  let requiresStereoAudioSDP: Bool
  let usesCustomAudioDevice: Bool

  // MARK: パブリッシャーに関する設定

  let publisherStreamId: String
  let publisherVideoTrackId: String
  let publisherAudioTrackId: String

  /// `Configuration` から写し取ります。
  ///
  /// 接続開始時に呼び出します。`JSONValue` への変換に失敗した場合は
  /// `SoraError.configurationError` を throw します。
  init(configuration: Configuration) throws {
    urlCandidates = configuration.urlCandidates
    channelId = configuration.channelId
    clientId = configuration.clientId
    bundleId = configuration.bundleId
    role = configuration.role
    multistreamEnabled = configuration.multistreamEnabled
    isMultistream = configuration.isMultistream
    isSender = configuration.isSender
    connectionTimeout = configuration.connectionTimeout

    videoCodec = configuration.videoCodec
    videoBitRate = configuration.videoBitRate
    audioCodec = configuration.audioCodec
    audioBitRate = configuration.audioBitRate
    videoEnabled = configuration.videoEnabled
    audioEnabled = configuration.audioEnabled
    audioStereoOutputEnabled = configuration.audioStereoOutputEnabled
    initialCameraEnabled = configuration.initialCameraEnabled
    initialMicrophoneEnabled = configuration.initialMicrophoneEnabled
    bypassVoiceProcessing = configuration.bypassVoiceProcessing
    cameraSettings = configuration.cameraSettings

    isSpotlightEnabled = configuration.isSpotlightEnabled
    spotlightNumber = configuration.spotlightNumber
    spotlightFocusRid = configuration.spotlightFocusRid
    spotlightUnfocusRid = configuration.spotlightUnfocusRid

    simulcastEnabled = configuration.simulcastEnabled
    simulcastRid = configuration.simulcastRid
    simulcastRequestRid = configuration.simulcastRequestRid

    dataChannelSignaling = configuration.dataChannelSignaling
    ignoreDisconnectWebSocket = configuration.ignoreDisconnectWebSocket
    audioStreamingLanguageCode = configuration.audioStreamingLanguageCode
    proxy = configuration.proxy
    insecure = configuration.insecure
    caCertificate = configuration.caCertificate
    webRTCConfiguration = WebRTCConfigurationSnapshot(configuration.webRTCConfiguration)

    signalingConnectMetadata = try configuration.signalingConnectMetadata.map { value in
      try JSONValue.from(
        value, errorReason: ConfigurationSnapshotErrorReason.signalingConnectMetadata)
    }
    signalingConnectNotifyMetadata = try configuration.signalingConnectNotifyMetadata.map {
      value in
      try JSONValue.from(
        value,
        errorReason: ConfigurationSnapshotErrorReason.signalingConnectNotifyMetadata)
    }
    dataChannelSettings = try configuration.dataChannels.map { value in
      try JSONValue.fromDataChannels(
        value, errorReason: ConfigurationSnapshotErrorReason.dataChannels)
    }
    forwardingFilter = try configuration.forwardingFilter.map { value in
      try ForwardingFilterSnapshot(value)
    }
    forwardingFilters = try configuration.forwardingFilters.map { values in
      try values.map { try ForwardingFilterSnapshot($0) }
    }

    // connect message に載る条件を満たすコーデック別パラメーターだけを写し取る。
    // 載らないものを変換すると、検証していない値で snapshot 生成が失敗する。
    videoVp9Params = try Self.convertVideoParams(
      configuration.videoVp9Params,
      codec: configuration.videoCodec,
      target: .vp9,
      name: "vp9",
      videoEnabled: configuration.videoEnabled)
    videoAv1Params = try Self.convertVideoParams(
      configuration.videoAv1Params,
      codec: configuration.videoCodec,
      target: .av1,
      name: "av1",
      videoEnabled: configuration.videoEnabled)
    videoH264Params = try Self.convertVideoParams(
      configuration.videoH264Params,
      codec: configuration.videoCodec,
      target: .h264,
      name: "h264",
      videoEnabled: configuration.videoEnabled)
    videoH265Params = try Self.convertVideoParams(
      configuration.videoH265Params,
      codec: configuration.videoCodec,
      target: .h265,
      name: "h265",
      videoEnabled: configuration.videoEnabled)
    audioOpusParams = try Self.convertAudioParams(
      configuration.audioOpusParams,
      audioEnabled: configuration.audioEnabled,
      audioCodec: configuration.audioCodec)

    requiresStereoAudioSDP = configuration.requiresStereoAudioSDP
    usesCustomAudioDevice = configuration.audioDevice != nil

    publisherStreamId = configuration.publisherStreamId
    publisherVideoTrackId = configuration.publisherVideoTrackId
    publisherAudioTrackId = configuration.publisherAudioTrackId
  }

  /// connect message に載る条件を満たすときだけ video のコーデック別パラメーターを変換します。
  ///
  /// `SignalingConnect.encode(to:)` は `videoEnabled` が true かつ `videoCodec` が `target` と
  /// 一致するときだけ対応する params を書くため、同じ条件で検証します。
  private static func convertVideoParams(
    _ value: Encodable?,
    codec: VideoCodec,
    target: VideoCodec,
    name: String,
    videoEnabled: Bool
  ) throws -> JSONValue? {
    guard videoEnabled, codec == target else {
      return nil
    }
    return try value.map { value in
      try JSONValue.from(
        value, errorReason: ConfigurationSnapshotErrorReason.videoParams(name))
    }
  }

  /// connect message に載る条件を満たすときだけ audio のコーデック別パラメーターを変換します。
  ///
  /// `SignalingConnect.encode(to:)` は `audioEnabled` が true かつ `audioCodec` が `.opus` の
  /// ときだけ `opus_params` を書くため、同じ条件で検証します。
  private static func convertAudioParams(
    _ value: Encodable?,
    audioEnabled: Bool,
    audioCodec: AudioCodec
  ) throws -> JSONValue? {
    guard audioEnabled, audioCodec == .opus else {
      return nil
    }
    return try value.map { value in
      try JSONValue.from(
        value, errorReason: ConfigurationSnapshotErrorReason.audioOpusParams)
    }
  }
}

extension ConnectionConfigurationSnapshot {
  /// PEM 文字列から CA 証明書を解析します。
  func parsedCACertificates() throws -> [SecCertificate]? {
    guard let cs = caCertificate else {
      return nil
    }
    return try Configuration.parsePEMCertificates(cs)
  }
}
