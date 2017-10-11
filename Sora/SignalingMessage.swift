import Foundation

public struct SignalingConnectMessage {
    
    public var role: SignalingRole
    public var channelId: String
    public var metadata: String?
    public var multistreamEnabled: Bool
    public var videoEnabled: Bool
    public var videoCodec: VideoCodec
    public var videoBitRate: Int?
    public var snapshotEnabled: Bool
    public var audioEnabled: Bool
    public var audioCodec: AudioCodec

}

public struct SignalingOfferMessage {
    
    public struct Configuration {
        public let iceServerInfos: [ICEServerInfo]
        public let iceTransportPolicy: ICETransportPolicy
    }
    
    public let clientId: String
    public let sdp: String
    public let configuration: Configuration?
    
}

public enum SignalingEventType: String {
    
    case connectionCreated = "connection.created"
    case connectionUpdated = "connection.updated"
    case connectionDestroyed = "connection.destroyed"
    
}

public struct SignalingUpdateOfferMessage {
    
    public let sdp: String
    
}

public struct SignalingSnapshotMessage {
    
    public let channelId: String
    public let webP: String
    
}

public struct SignalingNotifyMessage {
    
    public let eventType: SignalingEventType
    public let role: SignalingRole
    public let connectionTime: Int
    public let connectionCount: Int
    public let publisherCount: Int
    public let subscriberCount: Int
    
}

public struct SignalingPongMessage {}

// MARK: -

public enum SignalingMessage {
    
    case connect(message: SignalingConnectMessage)
    case offer(message: SignalingOfferMessage)
    case answer(sdp: String)
    case candidate(ICECandidate)
    case update(sdp: String)
    case snapshot(SignalingSnapshotMessage)
    case notify(message: SignalingNotifyMessage)
    case ping
    case pong
    
}

// MARK: -
// MARK: Codable

/// :nodoc:
extension SignalingRole: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let roleStr = try container.decode(String.self)
        guard let role = SignalingRole(rawValue: roleStr) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid 'role' value")
        }
        self = role
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    
}

/// :nodoc:
extension SignalingConnectMessage: Codable {
    
    enum CodingKeys: String, CodingKey {
        case role
        case channelId = "channel_id"
        case metadata
        case multistream
        case plan_b
        case video
        case audio
    }
    
    enum VideoCodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case bitRate = "bit_rate"
        case snapshot
    }
    
    enum AudioCodingKeys: String, CodingKey {
        case codecType = "codec_type"
    }
    
    public init(from decoder: Decoder) throws {
        fatalError("not supported")
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(channelId, forKey: .channelId)
        
        if let metadata = metadata {
            try container.encode(metadata, forKey: .metadata)
        }
        
        if multistreamEnabled {
            try container.encode(true, forKey: .multistream)
            try container.encode(true, forKey: .plan_b)
        }
     
        if videoEnabled {
            if videoCodec != .default || videoBitRate != nil || snapshotEnabled {
                var videoContainer = container
                    .nestedContainer(keyedBy: VideoCodingKeys.self,
                                     forKey: .video)
                if videoCodec != .default {
                    try videoContainer.encode(videoCodec, forKey: .codecType)
                }
                if let bitRate = videoBitRate {
                    try videoContainer.encode(bitRate, forKey: .bitRate)
                }
                if snapshotEnabled {
                    try videoContainer.encode(true, forKey: .snapshot)
                }
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
                try audioContainer.encode(audioCodec, forKey: .codecType)
            }
        } else {
            try container.encode(false, forKey: .audio)
        }
    }
    
}

/// :nodoc:
extension SignalingOfferMessage.Configuration: Codable {
    
    enum CodingKeys: String, CodingKey {
        case iceServerInfos = "iceServers"
        case iceTransportPolicy = "iceTransportPolicy"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iceServerInfos = try container.decode([ICEServerInfo].self,
                                              forKey: .iceServerInfos)
        iceTransportPolicy = try container.decode(ICETransportPolicy.self,
                                                  forKey: .iceTransportPolicy)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

/// :nodoc:
extension SignalingOfferMessage: Codable {
    
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case sdp
        case configuration = "config"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        sdp = try container.decode(String.self, forKey: .sdp)
        if container.contains(.configuration) {
            configuration = try container.decode(Configuration.self,
                                                 forKey: .configuration)
        } else {
            configuration = nil
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

/// :nodoc:
extension SignalingUpdateOfferMessage: Codable {
    
    enum CodingKeys: String, CodingKey {
        case sdp
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sdp = try container.decode(String.self, forKey: .sdp)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

/// :nodoc:
extension SignalingSnapshotMessage: Codable {
    
    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case webP = "base64ed_webp"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decode(String.self, forKey: .channelId)
        webP = try container.decode(String.self, forKey: .webP)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

/// :nodoc:
extension SignalingNotifyMessage: Codable {
    
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case role
        case connectionTime = "minutes"
        case connectionCount = "channel_connections"
        case publisherCount = "channel_upstream_connections"
        case subscriberCount = "channel_downstream_connections"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = SignalingEventType(rawValue:
            try container.decode(String.self, forKey: .eventType))!
        role = SignalingRole(rawValue:
            try container.decode(String.self, forKey: .role))!
        connectionTime = try container.decode(Int.self, forKey: .connectionTime)
        connectionCount = try container.decode(Int.self, forKey: .connectionCount)
        publisherCount = try container.decode(Int.self, forKey: .publisherCount)
        subscriberCount = try container.decode(Int.self, forKey: .subscriberCount)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

/// :nodoc:
extension SignalingMessage: Codable {
    
    enum MessageType: String {
        case connect
        case offer
        case answer
        case update
        case snapshot
        case candidate
        case notify
        case ping
        case pong
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case sdp
        case candidate
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "offer":
            self = .offer(message: try SignalingOfferMessage(from: decoder))
        case "update":
            let update = try SignalingUpdateOfferMessage(from: decoder)
            self = .update(sdp: update.sdp)
        case "snapshot":
            self = .snapshot(try SignalingSnapshotMessage(from: decoder))
        case "notify":
            self = .notify(message: try SignalingNotifyMessage(from: decoder))
        case "ping":
            self = .ping
        default:
            fatalError("not supported decoding '\(type)'")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connect(message: let message):
            try container.encode(MessageType.connect.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .offer(message: let message):
            try container.encode(MessageType.offer.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case .answer(sdp: let sdp):
            try container.encode(MessageType.answer.rawValue, forKey: .type)
            try container.encode(sdp, forKey: .sdp)
        case .candidate(let candidate):
            try container.encode(MessageType.candidate.rawValue, forKey: .type)
            try container.encode(candidate.sdp, forKey: .candidate)
        case .update(sdp: let sdp):
            try container.encode(MessageType.update.rawValue, forKey: .type)
            try container.encode(sdp, forKey: .sdp)
        case .snapshot(_):
            fatalError("not supported encoding 'snapshot'")
        case .notify(message: _):
            fatalError("not supported encoding 'notify'")
        case .ping:
            fatalError("not supported encoding 'ping'")
        case .pong:
            try container.encode(MessageType.pong.rawValue, forKey: .type)
        }
    }
    
}
