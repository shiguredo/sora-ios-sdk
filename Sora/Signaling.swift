import Foundation
import WebRTC

/**
 シグナリングの種別です。
 */
public enum Signaling {
    
    /// "connect" シグナリング
    case connect(SignalingConnect)
    
    /// "offer" シグナリング
    case offer(SignalingOffer)
    
    /// "answer" シグナリング
    case answer(SignalingAnswer)
    
    /// "update" シグナリング
    case update(SignalingUpdate)
    
    /// "candidate" シグナリング
    case candidate(SignalingCandidate)
    
    /// "notify" シグナリング ("connection.created", "connection.updated", "connection.destroyed")
    case notifyConnection(SignalingNotifyConnection)
    
    /// "notify" シグナリング ("spotlight.changed")
    case notifySpotlightChanged(SignalingNotifySpotlightChanged)
    
    /// "notify" シグナリング ("network.status")
    case notifyNetworkStatus(SignalingNotifyNetworkStatus)
    
    /// "ping" シグナリング
    case ping
    
    /// "pong" シグナリング
    case pong(SignalingPong)
    
    /// "disconnect" シグナリング
    case disconnect
    
    /// "pong" シグナリング
    case push(SignalingPush)
    
    /// :nodoc:
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

/**
 サイマルキャストの品質を表します。
 */
public enum SimulcastQuality {

    /// 低画質
    case low
    
    /// 中画質
    case middle
    
    /// 高画質
    case high
    
}

/**
 シグナリングに含まれるメタデータ (任意のデータ) を表します。
 サーバーから受信するシグナリングにメタデータが含まれる場合は、
 `decoder` プロパティに JSON デコーダーがセットされます。
 受信したメタデータを任意のデータ型に変換するには、このデコーダーを使ってください。
 */
public struct SignalingMetadata {
    
    /// シグナリングに含まれるメタデータの JSON デコーダー
    public var decoder: Decoder
    
}

/**
 シグナリングに含まれる、同チャネルに接続中のクライアントに関するメタデータ (任意のデータ) を表します。
 */
public struct SignalingClientMetadata {

    /// クライアント ID
    public var clientId: String?
    
    /// 接続 ID
    public var connectionId: String?
    
    /// メタデータ
    public var metadata: SignalingMetadata
    
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
    public var metadata: Encodable?
    
    /// notify メタデータ
    public var notifyMetadata: Encodable?
    
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
    
    /// 音声ビットレート
    public var audioBitRate: Int?

    /// スポットライト
    public var spotlight: Int?

    /// サイマルキャストの可否
    public var simulcastEnabled: Bool

    /// サイマルキャストの品質
    public var simulcastQuality: SimulcastQuality

    /// :nodoc:
    public var soraClient: String?

    /// :nodoc:
    public var webRTCVersion: String?

    /// :nodoc:
    public var environment: String?

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

    /**
     RTP ペイロードに含まれる映像・音声エンコーディングの情報です。

     次のリンクも参考にしてください。
     https://w3c.github.io/webrtc-pc/#rtcrtpencodingparameters
     */
    public struct Encoding {

        /// RTP ストリーム ID
        public let rid: String?

        /// 最大ビットレート
        public let maxBitrate: Int?

        /// 最大フレームレート
        public let maxFramerate: Double?

        /// 映像解像度を送信前に下げる度合
        public let scaleResolutionDownBy: Double?

        /// RTP エンコーディングに関するパラメーター
        public var rtpEncodingParameters: RTCRtpEncodingParameters {
            get {
                let params = RTCRtpEncodingParameters()
                params.rid = rid
                if let value = maxBitrate {
                    params.maxBitrateBps = NSNumber(value: value)
                }
                if let value = maxFramerate {
                    params.maxFramerate = NSNumber(value: value)
                }
                if let value = scaleResolutionDownBy {
                    params.scaleResolutionDownBy = NSNumber(value: value)
                }
                return params
            }
        }

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

    /// エンコーディング
    public let encodings: [Encoding]?

}

/**
 "answer" シグナリングメッセージを表します。
 */
public struct SignalingAnswer {
    
    /// SDP メッセージ
    public let sdp: String

}

/**
 "candidate" シグナリングメッセージを表します。
 */
public struct SignalingCandidate {
    
    /// ICE candidate
    public let candidate: ICECandidate
    
}

/**
 "update" シグナリングメッセージを表します。
 */
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

/**
 "notify" シグナリングメッセージで通知されるイベントの種別です。
 詳細は Sora のドキュメントを参照してください。
 */
public enum SignalingNotifyEventType {
    
    /// "connection.created"
    case connectionCreated
    
    /// "connection.updated"
    case connectionUpdated
    
    /// "connection.destroyed"
    case connectionDestroyed
    
    /// "spotlight.changed"
    case spotlightChanged
    
    /// "network.status"
    case networkStatus
    
}

/**
 "notify" シグナリングメッセージのうち、次のイベントを表します。
 
 - `connection.created`
 - `connection.updated`
 - `connection.destroyed`
 
 このメッセージは接続の確立後、チャネルへの接続数に変更があるとサーバーから送信されます。
 */
public struct SignalingNotifyConnection {

    // MARK: イベント情報
    
    /// イベントの種別
    public var eventType: SignalingNotifyEventType
    
    // MARK: 接続情報
    
    /// ロール
    public var role: SignalingRole
    
    /// クライアント ID
    public var clientId: String?
    
    /// 接続 ID
    public var connectionId: String?
    
    /// 音声の可否
    public var audioEnabled: Bool?
    
    /// 映像の可否
    public var videoEnabled: Bool?
    
    /// メタデータ
    public var metadata: SignalingMetadata?
    
    /// メタデータのリスト
    public var metadataList: [SignalingClientMetadata]?
    
    // MARK: 接続状態
    
    /// 接続時間
    public var connectionTime: Int
    
    /// 接続中のクライアントの数
    public var connectionCount: Int
    
    /// 接続中のパブリッシャーの数
    public var publisherCount: Int
    
    /// 接続中のサブスクライバーの数
    public var subscriberCount: Int
    
}

/**
 "notify" シグナリングメッセージのうち、 `spotlight.changed` イベントを表します。
 */
public struct SignalingNotifySpotlightChanged {
    
    /// クライアント ID
    public var clientId: String?
    
    /// 接続 ID
    public var connectionId: String?
    
    /// スポットライト ID
    public var spotlightId: String
    
    /// 固定の有無
    public var isFixed: Bool?
    
    /// 音声の可否
    public var audioEnabled: Bool?
    
    /// 映像の可否
    public var videoEnabled: Bool?
    
}

/**
 "notify" シグナリングメッセージのうち、 "network.status" イベントを表します。
 */
public struct SignalingNotifyNetworkStatus {
    
    /// ネットワークの不安定度
    public var unstableLevel: Int
    
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

private var simulcastQualityTable: PairTable<String, SimulcastQuality> =
    PairTable(name: "SimulcastQuality",
              pairs: [("low", .low),
                      ("middle", .middle),
                      ("high", .high)])

/// :nodoc:
extension SimulcastQuality: Codable {
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
    public func encode(to encoder: Encoder) throws {
        try simulcastQualityTable.encode(self, to: encoder)
    }
    
}

/// :nodoc:
extension SignalingMetadata: Decodable {
    
    public init(from decoder: Decoder) throws {
        self.decoder = decoder
    }
    
}

/// :nodoc:
extension SignalingClientMetadata: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case client_id
        case connection_id
        case metadata
    }
    
    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
            connectionId = try container.decodeIfPresent(String.self, forKey: .connection_id)
            metadata = try container.decode(SignalingMetadata.self, forKey: .metadata)
        } catch {
            metadata = try SignalingMetadata(from: decoder)
        }

    }
    
}

private var roleTable: PairTable<String, SignalingRole> =
    PairTable(name: "SignalingRole",
              pairs: [("upstream", .upstream),
                      ("downstream", .downstream)])

/// :nodoc:
extension SignalingRole: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try roleTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try roleTable.encode(self, to: encoder)
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
        case sora_client
        case libwebrtc
        case environment
    }
    
    enum VideoCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
    }
    
    enum AudioCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
    }

    enum SimulcastQualityCodingKeys: String, CodingKey {
        case quality
    }
    
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(channelId, forKey: .channel_id)
        try container.encodeIfPresent(sdp, forKey: .sdp)
        let metadataEnc = container.superEncoder(forKey: .metadata)
        try metadata?.encode(to: metadataEnc)
        let notifyEnc = container.superEncoder(forKey: .signaling_notify_metadata)
        try notifyMetadata?.encode(to: notifyEnc)
        try container.encodeIfPresent(multistreamEnabled,
                                      forKey: .multistream)
        try container.encodeIfPresent(planBEnabled, forKey: .plan_b)
        try container.encodeIfPresent(spotlight, forKey: .spotlight)
        try container.encodeIfPresent(soraClient, forKey: .sora_client)
        try container.encodeIfPresent(webRTCVersion, forKey: .libwebrtc)
        try container.encodeIfPresent(environment, forKey: .environment)

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
            if audioCodec != .default || audioBitRate != nil {
                var audioContainer = container
                    .nestedContainer(keyedBy: AudioCodingKeys.self,
                                     forKey: .audio)
                if audioCodec != .default {
                    try audioContainer.encode(audioCodec, forKey: .codec_type)
                }
                try audioContainer.encodeIfPresent(audioBitRate,
                                                   forKey: .bit_rate)
            }
        } else {
            try container.encode(false, forKey: .audio)
        }
        
        if simulcastEnabled {
            switch role {
            case .downstream:
                var simulcastContainer = container
                        .nestedContainer(keyedBy: SimulcastQualityCodingKeys.self, forKey: .simulcast)
                try simulcastContainer.encode(simulcastQuality, forKey: .quality)
            default:
                try container.encode(true, forKey: .simulcast)
            }
        }
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
extension SignalingOffer.Encoding: Codable {

    enum CodingKeys: String, CodingKey {
        case rid
        case maxBitrate
        case maxFramerate
        case scaleResolutionDownBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rid = try container.decodeIfPresent(String.self, forKey: .rid)
        maxBitrate = try container.decodeIfPresent(Int.self, forKey: .maxBitrate)
        maxFramerate = try container.decodeIfPresent(Double.self, forKey: .maxFramerate)
        scaleResolutionDownBy = try container.decodeIfPresent(Double.self,
                forKey: .scaleResolutionDownBy)
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
        case encodings
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
        encodings =
            try container.decodeIfPresent([Encoding].self,
                                          forKey: .encodings)
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
        role = try container.decode(SignalingRole.self, forKey: .role)
        clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
        connectionId = try container.decodeIfPresent(String.self,
                                                     forKey: .connection_id)
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audio)
        videoEnabled = try container.decodeIfPresent(Bool.self, forKey: .video)
        metadata = try container.decodeIfPresent(SignalingMetadata.self,
                                                 forKey: .metadata)
        metadataList =
            try container.decodeIfPresent([SignalingClientMetadata].self,
                                          forKey: .metadata_list)
        connectionTime = try container.decode(Int.self, forKey: .minutes)
        connectionCount =
            try container.decode(Int.self, forKey: .channel_connections)
        publisherCount =
            try container.decode(Int.self, forKey: .channel_upstream_connections)
        subscriberCount =
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
                      ("network.status", .networkStatus)])

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
        isFixed = try container.decodeIfPresent(Bool.self, forKey: .fixed)
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audio)
        videoEnabled = try container.decodeIfPresent(Bool.self, forKey: .video)
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
