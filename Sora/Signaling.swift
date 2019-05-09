import Foundation

public enum Signaling {
    case connect(SignalingConnect)
    case offer(SignalingOffer)
    case answer(SignalingAnswer)
    case update(SignalingUpdate)
    case candidate(SignalingCandidate)
    case notifyConnection(SignalingNotifyConnection)
    case notifySpotlightChanged(SignalingNotifySpotlightChanged)
    case notifyNetworkStatus(SignalingNotifyNetworkStatus)
    case ping
    case pong(SignalingPong)
    case disconnect
    case push(SignalingPush)
    
    public func typeName() -> String {
        switch self {
        case .connect(_):
            return "connect"
        case .offer(_):
            return "offer"
        case .answer(_):
            return "answer"
        case .update(_):
            return "update"
        case .candidate(_):
            return "candidate"
        case .notifyConnection(let notify):
            return "notify(\(notify.eventType))"
        case .notifySpotlightChanged(_):
            return "notify(spotlight.changed)"
        case .notifyNetworkStatus(_):
            return "notify(network.status)"
        case .ping:
            return "ping"
        case .pong(_):
            return "pong"
        case .disconnect:
            return "disconnect"
        case .push(_):
            return "push"
        }
    }
    
}

public enum Simulcast {
    case low
    case middle
    case high
}

public struct SignalingMetadata {
    public var data: Encodable?
    public var decoder: Decoder?
    
    public init(data: Encodable) {
        self.data = data
    }
    
}

/**
 "connect" シグナリングメッセージを表します。
 このメッセージはシグナリング接続の確立後、最初に送信されます。
 */
public struct SignalingConnect {
    
    /// ロール
    public var role: SignalingRole
    
    /// チャネル ID
    public var channelId: String
    
    /// メタデータ
    public var metadata: SignalingMetadata?
    
    /// notify メタデータ
    public var notifyMetadata: SignalingMetadata?
    
    /// SDP 。クライアントの判別に使われます。
    public var sdp: String?
    
    /// マルチストリームの可否
    public var multistreamEnabled: Bool?
    
    /// Plan B の可否
    public var planBEnabled: Bool?
    
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
    
    /// サイマルキャスト
    public var simulcast: Simulcast?
    
}

/**
 "offer" シグナリングメッセージを表します。
 このメッセージは SDK が "connect" を送信した後に、サーバーから送信されます。
 */
public struct SignalingOffer {
    
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
    public let metadata: SignalingMetadata?
    
}

public struct SignalingAnswer {
    
    /// SDP メッセージ
    public let sdp: String

}

public struct SignalingCandidate {
    
    public let candidate: ICECandidate
    
}

public struct SignalingUpdate {
    
    /// SDP メッセージ
    public let sdp: String
    
}

/**
 "push" シグナリングメッセージを表します。
 このメッセージは Sora のプッシュ API を使用して送信されたデータです。
 */
public struct SignalingPush {
    
    /// プッシュ通知で送信される JSON データ
    public let data: SignalingMetadata
    
}

public enum SignalingNotifyEventType {
    case connectionCreated
    case connectionUpdated
    case connectionDestroyed
    case spotlightChanged
    case networkStatus
}

public struct SignalingNotifyConnection {

    var eventType: SignalingNotifyEventType
    var role: Role
    var clientId: String?
    var connectionId: String?
    var audio: Bool?
    var video: Bool?
    var metadata: SignalingMetadata?
    var metadataList: [SignalingMetadata]
    var minutes: Int
    var connectionCount: Int
    var upstreamConnectionCount: Int
    var downstreamConnectionCount: Int
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

/// :nodoc:
extension Signaling: Codable {
    
    enum MessageType: String {
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
    
    enum CodingKeys: String, CodingKey {
        case type
        case event_type
        case sdp
        case candidate
        case data
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "offer":
            self = .offer(try SignalingOffer(from: decoder))
        case "update":
            self = .update(try SignalingUpdate(from: decoder))
        case "notify":
            let eventType = try container.decode(SignalingNotifyEventType.self,
                                                 forKey: .event_type)
            switch eventType {
            case .connectionCreated,
                 .connectionUpdated,
                 .connectionDestroyed:
                self = .notifyConnection(try SignalingNotifyConnection(from: decoder))
            case .spotlightChanged:
                self = .notifySpotlightChanged(
                    try SignalingNotifySpotlightChanged(from: decoder))
            case .networkStatus:
                self = .notifyNetworkStatus(
                    try SignalingNotifyNetworkStatus(from: decoder))
            }
        case "ping":
            self = .ping
        case "push":
            self = .push(try SignalingPush(from: decoder))
        default:
            throw SoraError.unknownSignalingMessageType(type: type)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connect(let message):
            try container.encode(MessageType.connect.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .offer(let message):
            try container.encode(MessageType.offer.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .answer(let message):
            try container.encode(MessageType.answer.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .candidate(let message):
            try container.encode(MessageType.candidate.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .update(let message):
            try container.encode(MessageType.update.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .pong:
            try container.encode(MessageType.pong.rawValue, forKey: .type)
        case .disconnect:
            try container.encode(MessageType.disconnect.rawValue, forKey: .type)
        default:
            throw SoraError.invalidSignalingMessage
        }
    }
    
}

private var simulcastTable: PairTable<String, Simulcast> =
    PairTable(name: "Simulcast",
              pairs: [("low", .low),
                      ("middle", .middle),
                      ("high", .high)])

/// :nodoc:
extension Simulcast: Codable {
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
    public func encode(to encoder: Encoder) throws {
        try simulcastTable.encode(self, to: encoder)
    }
    
}

/// :nodoc:
extension SignalingMetadata: Codable {
    
    public init(from decoder: Decoder) throws {
        self.decoder = decoder
    }
    
    public func encode(to encoder: Encoder) throws {
        if let data = self.data {
            try data.encode(to: encoder)
        }
    }
    
}

/// :nodoc:
extension SignalingConnect: Codable {
    
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
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
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
        try container.encodeIfPresent(simulcast, forKey: .simulcast)
    }
    
}

/// :nodoc:
extension SignalingOffer.Configuration: Codable {
    
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
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

/// :nodoc:
extension SignalingOffer: Codable {
    
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
            try container.decodeIfPresent(SignalingMetadata.self,
                                          forKey: .metadata)
    }
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

/// :nodoc:
extension SignalingAnswer: Codable {
    
    enum CodingKeys: String, CodingKey {
        case sdp
    }
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sdp, forKey: .sdp)
    }
    
}

/// :nodoc:
extension SignalingCandidate: Codable {
    
    enum CodingKeys: String, CodingKey {
        case candidate
    }
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
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
extension SignalingPush: Codable {
    
    enum CodingKeys: String, CodingKey {
        case data
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(SignalingMetadata.self, forKey: .data)
    }
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

/// :nodoc:
extension SignalingNotifyConnection: Codable {
    
    enum CodingKeys: String, CodingKey {
        case event_type
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
        eventType = try container.decode(SignalingNotifyEventType.self,
                                         forKey: .event_type)
        role = try container.decode(Role.self, forKey: .role)
        clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
        connectionId = try container.decodeIfPresent(String.self,
                                                     forKey: .connection_id)
        audio = try container.decodeIfPresent(Bool.self, forKey: .connection_id)
        video = try container.decodeIfPresent(Bool.self, forKey: .video)
        metadata = try container.decodeIfPresent(SignalingMetadata.self,
                                                 forKey: .metadata)
        metadataList =
            try container.decode([SignalingMetadata].self,
                                 forKey: .metadata_list)
        minutes = try container.decode(Int.self, forKey: .minutes)
        connectionCount =
            try container.decode(Int.self, forKey: .channel_connections)
        upstreamConnectionCount =
            try container.decode(Int.self, forKey: .channel_upstream_connections)
        downstreamConnectionCount =
            try container.decode(Int.self, forKey: .channel_downstream_connections)
    }
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

private var signalingNotifyEventType: PairTable<String, SignalingNotifyEventType> =
    PairTable(name: "SignalingNotifyEventType",
              pairs: [("connection.created", .connectionCreated),
                      ("connection.updated", .connectionUpdated),
                      ("connection.destroyed", .connectionDestroyed),
                      ("spotlight.changed", .spotlightChanged),
                      ("newtork.status", .networkStatus)])

/// :nodoc:
extension SignalingNotifyEventType: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try signalingNotifyEventType.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try signalingNotifyEventType.encode(self, to: encoder)
    }
    
}

/// :nodoc:
extension SignalingNotifySpotlightChanged: Codable {
    
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
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

/// :nodoc:
extension SignalingNotifyNetworkStatus: Codable {
    
    enum CodingKeys: String, CodingKey {
        case unstable_level
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unstableLevel = try container.decode(Int.self, forKey: .unstable_level)
    }
    
    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
}

/// :nodoc:
extension SignalingPong: Codable {
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
    public func encode(to encoder: Encoder) throws {
        // エンコードするプロパティはない
    }
    
}
