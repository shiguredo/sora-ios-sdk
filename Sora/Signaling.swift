import Foundation

public protocol Signaling {
    associatedtype Connect: Encodable
    associatedtype Offer: Decodable
    associatedtype Answer: Encodable
    associatedtype Candidate: Encodable
    associatedtype UpdateToServer: Encodable
    associatedtype UpdateToClient: Decodable
    associatedtype Push: Decodable
    associatedtype ConnectionCreated: Decodable
    associatedtype ConnectionUpdated: Decodable
    associatedtype ConnectionDestroyed: Decodable
    associatedtype SpotlightChanged: Decodable
    associatedtype NetworkStatus: Decodable
    associatedtype Pong: Encodable
}

enum SignalingType: String {
    case connect
    case offer
    case answer
    case update
    case candidate
    case notify
    case ping
    case pong
    case disconnect
    case push
}

public enum SignalingSimulcast {
    case low
    case middle
    case high
}

/**
 "connect" シグナリングメッセージを表します。
 このメッセージはシグナリング接続の確立後、最初に送信されます。
 */
public struct SignalingConnect<ConnectMetadata: Encodable, NotifyMetadata: Encodable> {
    
    /// ロール
    public var role: SignalingRole
    
    /// チャネル ID
    public var channelId: String
    
    /// メタデータ
    public var metadata: ConnectMetadata?
    
    /// notify メタデータ
    public var notifyMetadata: NotifyMetadata?
    
    /// SDP 。クライアントの判別に使われます。
    public var sdp: String?
    
    /// マルチストリームの可否
    public var multistreamEnabled: Bool?
    
    /// Plan B の可否
    public var planBEnabled: Bool?
    
    /// スポットライト数
    public var spotlight: Int?
    
    /// サイマルキャスト
    public var simulcast: SignalingSimulcast?
    
    /// 映像の可否
    public var videoEnabled: Bool
    
    /// 映像コーデック
    public var videoCodec: VideoCodec
    
    /// 映像ビットレート
    public var videoBitRate: Int?
    
    /// 音声の可否
    public var audioEnabled: Bool
    
    /// 音声コーデック
    public var audioCodec: AudioCodec
    
    /// 最大話者数
    public var maxNumberOfSpeakers: Int?
    
}

/**
 "offer" シグナリングメッセージを表します。
 このメッセージは SDK が "connect" を送信した後に、サーバーから送信されます。
 */
public struct SignalingOffer<Metadata: Decodable> {
    
    /**
     クライアントが更新すべき設定を表します。
     */
    public struct Configuration {
        
        /// ICE サーバーの情報のリスト
        public let iceServerInfos: [ICEServerInfo]
        
        /// ICE 通信ポリシー
        public let iceTransportPolicy: ICETransportPolicy
    }
    
    /// クライアント ID
    public let clientId: String
    
    /// 接続 ID
    public let connectionId: String
    
    /// SDP メッセージ
    public let sdp: String
    
    /// クライアントが更新すべき設定
    public let configuration: Configuration?
    
    /// メタデータ
    public let metadata: Metadata?
    
}

public struct SignalingAnswer {
    
    /// SDP メッセージ
    public let sdp: String

}

public struct SignalingCandidate {
    
    public let candidate: String
    
}

public struct SignalingUpdate {
    
    /// SDP メッセージ
    public let sdp: String
    
}

/**
 "push" シグナリングメッセージを表します。
 このメッセージは Sora のプッシュ API を使用して送信されたデータです。
 */
public struct SignalingPush<PushData: Decodable> {
    
    /// プッシュ通知で送信される JSON データ
    public let data: PushData
    
}

public struct SignalingNotifyConnection<Metadata: Decodable, MetadataElement: Decodable> {
    var role: Role
    var clientId: String?
    var connectionId: String?
    var audio: Bool?
    var video: Bool?
    var metadata: Metadata?
    var metadataList: [MetadataElement]
    var minutes: Int
    var channelConnections: Int
    var channelUpstreamConnections: Int
    var channelDownstreamConnections: Int
}

public struct SignalingNotifySpotlightChanged {
    var clientId: String?
    var connectionId: String?
    var spotlightId: String
    var fixed: Bool?
    var audio: Bool?
    var video: Bool?
}

public struct SignalingNotifyNetworkStatus {
    var unstableLevel: Int
}

/**
 "pong" シグナリングメッセージを表します。
 このメッセージはサーバーから "ping" シグナリングメッセージを受信すると
 サーバーに送信されます。
 "ping" 受信後、一定時間内にこのメッセージを返さなければ、
 サーバーとの接続が解除されます。
 */
public struct SignalingPong {}

// MARK: -
// MARK: Codable

private var simulcastTable: PairTable<String, SignalingSimulcast> =
    PairTable(name: "SignalingSimulcast",
              pairs: [("low", .low),
                      ("middle", .middle),
                      ("high", .high)])

/// :nodoc:
extension SignalingSimulcast: Encodable {
    
    public func encode(to encoder: Encoder) throws {
        try simulcastTable.encode(self, to: encoder)
    }
    
}

/// :nodoc:
extension SignalingConnect: Encodable {
    
    enum CodingKeys: String, CodingKey {
        case role
        case channel_id
        case metadata
        case signaling_notify_metadata
        case sdp
        case multistream
        case plan_b
        case spotlight
        case simulcast
        case video
        case audio
        case vad
    }
    
    enum VideoCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
    }
    
    enum AudioCodingKeys: String, CodingKey {
        case codec_type
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(channelId, forKey: .channel_id)
        try container.encodeIfPresent(sdp, forKey: .sdp)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(notifyMetadata,
                                      forKey: .signaling_notify_metadata)
        try container.encodeIfPresent(multistreamEnabled,
                                      forKey: .multistream)
        try container.encodeIfPresent(planBEnabled, forKey: .plan_b)
        
        if videoEnabled {
            if videoCodec != .default || videoBitRate != nil {
                var videoContainer = container
                    .nestedContainer(keyedBy: VideoCodingKeys.self,
                                     forKey: .video)
                if videoCodec != .default {
                    try videoContainer.encode(videoCodec, forKey: .codec_type)
                }
                try videoContainer.encodeIfPresent(videoBitRate,
                                                   forKey: .bit_rate)
            }
        } else {
            try container.encode(false, forKey: .video)
        }
        
        if audioEnabled {
            switch audioCodec {
            case .default:
                break
            default:
                var audioContainer = container
                    .nestedContainer(keyedBy: AudioCodingKeys.self, forKey: .audio)
                try audioContainer.encode(audioCodec, forKey: .codec_type)
            }
        } else {
            try container.encode(false, forKey: .audio)
        }
        
        try container.encodeIfPresent(maxNumberOfSpeakers, forKey: .vad)
    }
    
}

/// :nodoc:
extension SignalingOffer.Configuration: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case iceServers
        case iceTransportPolicy
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iceServerInfos = try container.decode([ICEServerInfo].self,
                                              forKey: .iceServers)
        iceTransportPolicy = try container.decode(ICETransportPolicy.self,
                                                  forKey: .iceTransportPolicy)
    }
    
}

/// :nodoc:
extension SignalingOffer: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case client_id
        case connection_id
        case sdp
        case config
        case metadata
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .client_id)
        connectionId = try container.decode(String.self, forKey: .connection_id)
        sdp = try container.decode(String.self, forKey: .sdp)
        configuration =
            try container.decodeIfPresent(Configuration.self,
                                          forKey: .config)
        metadata =
            try container.decodeIfPresent(Metadata.self,
                                          forKey: .metadata)
    }
    
}

/// :nodoc:
extension SignalingAnswer: Encodable {
    
    enum CodingKeys: String, CodingKey {
        case sdp
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sdp, forKey: .sdp)
    }
    
}

/// :nodoc:
extension SignalingCandidate: Encodable {
    
    enum CodingKeys: String, CodingKey {
        case candidate
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidate, forKey: .candidate)
    }
    
}

/// :nodoc:
extension SignalingUpdate: Codable {
    
    enum CodingKeys: String, CodingKey {
        case sdp
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sdp = try container.decode(String.self, forKey: .sdp)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sdp, forKey: .sdp)
    }
    
}

/// :nodoc:
extension SignalingPush: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case data
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(PushData.self, forKey: .data)
    }
    
}

/// :nodoc:
extension SignalingNotifyConnection: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case role
        case client_id
        case connection_id
        case audio
        case video
        case metadata
        case metadata_list
        case minutes
        case channel_connections
        case channel_upstream_connections
        case channel_downstream_connections
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
        connectionId = try container.decodeIfPresent(String.self, forKey: .connection_id)
        audio = try container.decodeIfPresent(Bool.self, forKey: .connection_id)
        video = try container.decodeIfPresent(Bool.self, forKey: .video)
        metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
        metadataList =
            try container.decode([MetadataElement].self,
                                 forKey: .metadata_list)
        minutes = try container.decode(Int.self, forKey: .minutes)
        channelConnections =
            try container.decode(Int.self, forKey: .channel_connections)
        channelUpstreamConnections =
            try container.decode(Int.self, forKey: .channel_upstream_connections)
        channelDownstreamConnections =
            try container.decode(Int.self, forKey: .channel_downstream_connections)
    }
    
}

/// :nodoc:
extension SignalingNotifySpotlightChanged: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case client_id
        case connection_id
        case spotlight_id
        case fixed
        case audio
        case video
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String?.self, forKey: .client_id)
        connectionId = try container.decode(String?.self, forKey: .connection_id)
        spotlightId = try container.decode(String.self, forKey: .spotlight_id)
        fixed = try container.decodeIfPresent(Bool.self, forKey: .fixed)
        audio = try container.decodeIfPresent(Bool.self, forKey: .audio)
        video = try container.decodeIfPresent(Bool.self, forKey: .video)
    }
    
}

/// :nodoc:
extension SignalingNotifyNetworkStatus: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case unstable_level
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unstableLevel = try container.decode(Int.self, forKey: .unstable_level)
    }
    
}

/// :nodoc:
extension SignalingPong: Encodable {
    
    public func encode(to encoder: Encoder) throws {
        // エンコードするプロパティはない
    }
    
}
