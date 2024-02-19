import Foundation
import WebRTC

/**
 メディア制約を表します。
 */
public struct MediaConstraints {
    /// 必須の制約
    public var mandatory: [String: String] = [:]

    /// オプションの制約
    public var optional: [String: String] = [:]

    // MARK: - ネイティブ

    var nativeValue: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: mandatory,
                            optionalConstraints: optional)
    }
}

/**
 SDP でのマルチストリームの記述方式です。
 */
public enum SDPSemantics {
    /// Unified Plan
    case unifiedPlan

    // MARK: - ネイティブ

    var nativeValue: RTCSdpSemantics {
        switch self {
        case .unifiedPlan:
            return RTCSdpSemantics.unifiedPlan
        }
    }
}

/**
 (リソースの逼迫により) 送信する映像の品質が劣化した場合の挙動です。
 */
public enum DegradationPreference {
    /// リソースが逼迫しても何もしない
    case disabled

    /// バランスを取る
    case balanced

    /// フレームレートを維持する
    case maintainFramerate

    /// 解像度を維持する
    case maintainResolution

    // MARK: - ネイティブ

    var nativeValue: RTCDegradationPreference {
        switch self {
        case .balanced:
            return RTCDegradationPreference.balanced
        case .disabled:
            return RTCDegradationPreference.disabled
        case .maintainFramerate:
            return RTCDegradationPreference.maintainFramerate
        case .maintainResolution:
            return RTCDegradationPreference.maintainResolution
        }
    }
}

/**
 WebRTC に関する設定です。
 */
public struct WebRTCConfiguration {
    // MARK: メディア制約に関する設定

    /// メディア制約
    public var constraints = MediaConstraints()

    // MARK: ICE サーバーに関する設定

    /// ICE サーバー情報のリスト
    public var iceServerInfos: [ICEServerInfo]

    /// ICE 通信ポリシー
    public var iceTransportPolicy: ICETransportPolicy = .relay

    // MARK: SDP に関する設定

    /// SDP でのマルチストリームの記述方式
    public var sdpSemantics: SDPSemantics = .unifiedPlan

    /// (リソースの不足により) 送信する映像の品質が劣化した場合の挙動
    public var senderDegradationPreference: DegradationPreference?

    // MARK: - インスタンスの生成

    /**
     初期化します。
     */
    public init() {
        iceServerInfos = []
    }

    // MARK: - ネイティブ

    var nativeValue: RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServerInfos.map { info in
            info.nativeValue
        }
        config.iceTransportPolicy = iceTransportPolicy.nativeValue
        config.sdpSemantics = sdpSemantics.nativeValue

        // AES-GCM を有効にする
        config.cryptoOptions = RTCCryptoOptions(srtpEnableGcmCryptoSuites: true,
                                                srtpEnableAes128Sha1_32CryptoCipher: false,
                                                srtpEnableEncryptedRtpHeaderExtensions: false,
                                                sframeRequireFrameEncryption: false)
        return config
    }

    var nativeConstraints: RTCMediaConstraints { constraints.nativeValue }
}

private var sdpSemanticsTable: PairTable<String, SDPSemantics> =
    PairTable(name: "SDPSemantics",
              pairs: [("unifiedPlan", .unifiedPlan)])

/// :nodoc:
extension SDPSemantics: Codable {
    public init(from decoder: Decoder) throws {
        self = try sdpSemanticsTable.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try sdpSemanticsTable.encode(self, to: encoder)
    }
}

/// :nodoc:
extension MediaConstraints: Codable {
    enum CodingKeys: String, CodingKey {
        case mandatory
        case optional
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mandatory = try container.decode([String: String].self,
                                         forKey: .mandatory)
        optional = try container.decode([String: String].self,
                                        forKey: .optional)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mandatory, forKey: .mandatory)
        try container.encode(optional, forKey: .optional)
    }
}

/// :nodoc:
extension WebRTCConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case constraints
        case iceServerInfos
        case iceTransportPolicy
        case sdpSemantics
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        constraints = try container.decode(MediaConstraints.self,
                                           forKey: .constraints)
        iceServerInfos = try container.decode([ICEServerInfo].self,
                                              forKey: .iceServerInfos)
        iceTransportPolicy = try container.decode(ICETransportPolicy.self,
                                                  forKey: .iceTransportPolicy)
        sdpSemantics = try container.decode(SDPSemantics.self,
                                            forKey: .sdpSemantics)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(constraints, forKey: .constraints)
        try container.encode(iceServerInfos, forKey: .iceServerInfos)
        try container.encode(iceTransportPolicy, forKey: .iceTransportPolicy)
        try container.encode(sdpSemantics, forKey: .sdpSemantics)
    }
}
