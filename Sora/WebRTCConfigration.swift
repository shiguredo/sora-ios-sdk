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
        get {
            return RTCMediaConstraints(mandatoryConstraints: mandatory,
                                       optionalConstraints: optional)
        }
    }
    
}

/**
 SDP でのマルチストリームの記述方式です。
 */
public enum SDPSemantics {
    
    /// デフォルト
    case `default`
    
    /// Plan B
    case planB
    
    /// Unified Plan
    case unifiedPlan
    
    // MARK: - ネイティブ
    
    var nativeValue: RTCSdpSemantics {
        get {
            switch self {
            case .default:
                return RTCSdpSemantics.default
            case .planB:
                return RTCSdpSemantics.planB
            case .unifiedPlan:
                return RTCSdpSemantics.unifiedPlan
            }
        }
    }
    
}

/**
 WebRTC に関する設定です。
 */
public struct WebRTCConfiguration {
    
    // MARK: メディア制約に関する設定
    
    /// メディア制約
    public var constraints: MediaConstraints = MediaConstraints()
    
    // MARK: ICE サーバーに関する設定
    
    /// ICE サーバー情報のリスト
    public var iceServerInfos: [ICEServerInfo]
    
    /// ICE 通信ポリシー
    public var iceTransportPolicy: ICETransportPolicy = .relay

    // MARK: SDP に関する設定
    
    /// SDP でのマルチストリームの記述方式
    public var sdpSemantics: SDPSemantics = .default
    
    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     */
    public init() {
        iceServerInfos = [
            ICEServerInfo(urls: [URL(string: "stun:stun.l.google.com:19302")!],
                          userName: nil,
                          credential: nil,
                          tlsSecurityPolicy: .secure)]
    }
    
    // MARK: - ネイティブ
    
    var nativeValue: RTCConfiguration {
        get {
            let config = RTCConfiguration()
            config.iceServers = iceServerInfos.map { info in
                return info.nativeValue
            }
            config.iceTransportPolicy = iceTransportPolicy.nativeValue
            config.sdpSemantics = sdpSemantics.nativeValue
            return config
        }
    }
    
    var nativeConstraints: RTCMediaConstraints {
        get { return constraints.nativeValue }
    }
    
}

private var sdpSemanticsTable: PairTable<String, SDPSemantics> =
    PairTable(pairs: [("planB", .planB),
                      ("unifiedPlan", .unifiedPlan)])

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
