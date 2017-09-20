import Foundation

public struct SignalingConnectRequest {
    
    public var role: SignalingRole
    public var channelId: String
    public var metadata: String?
    public var multistreamEnabled: Bool
    public var videoEnabled: Bool
    public var videoCodec: VideoCodec
    public var videoBitRate: Int?
    public var audioEnabled: Bool
    public var audioCodec: AudioCodec

}

public struct SignalingOfferRequest {
    
    public struct Configuration {
        var iceServerInfos: [ICEServerInfo]
        var iceTransportPolicy: ICETransportPolicy
    }
    
    public var clientId: String
    public var sdp: String
    public var configuration: Configuration?
    
}

public enum SignalingEventType: String {
    
    case connectionCreated = "connection.created"
    case connectionUpdated = "connection.updated"
    case connectionDestroyed = "connection.destroyed"
    
}

public struct SignalingNotifyMessage {
    
    public var eventType: SignalingEventType
    public var role: SignalingRole
    public var connectionTime: Int
    public var connectionCount: Int
    public var publisherCount: Int
    public var subscriberCount: Int
    
}

public struct SignalingPongMessage {}

public enum SignalingMessage {
    
    case connect(request: SignalingConnectRequest)
    case offer(request: SignalingOfferRequest)
    case answer(sdp: String)
    case candidate(ICECandidate)
    case notify(message: SignalingNotifyMessage)
    case ping
    case pong
    
}

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

extension SignalingConnectRequest: Codable {
    
    enum CodingKeys: String, CodingKey {
        case role
        case channelId = "channel_id"
        case metadata
        case multistream
        case video
        case audio
    }
    
    enum VideoCodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case bitRate = "bit_rate"
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
        }
     
        if videoEnabled {
            switch (videoCodec, videoBitRate) {
            case (.default, nil):
                try container.encode(true, forKey: .video)
            case (let codec, let rate):
                var videoContainer = container
                    .nestedContainer(keyedBy: VideoCodingKeys.self,
                                     forKey: .video)
                try videoContainer.encode(codec, forKey: .codecType)
                try videoContainer.encode(rate, forKey: .bitRate)
            }
        } else {
            try container.encode(false, forKey: .video)
        }
        
        if audioEnabled {
            switch audioCodec {
            case .default:
                try container.encode(true, forKey: .audio)
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

extension SignalingOfferRequest.Configuration: Codable {
    
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

extension SignalingOfferRequest: Codable {
    
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
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

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

extension SignalingMessage: Codable {
    
    enum MessageType: String {
        case connect
        case offer
        case answer
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
            self = .offer(request: try SignalingOfferRequest(from: decoder))
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
        case .connect(request: let request):
            try container.encode(MessageType.connect.rawValue, forKey: .type)
            try request.encode(to: encoder)
        case .offer(request: let request):
            try container.encode(MessageType.offer.rawValue, forKey: .type)
            try request.encode(to: encoder)
        case .answer(sdp: let sdp):
            try container.encode(MessageType.answer.rawValue, forKey: .type)
            try container.encode(sdp, forKey: .sdp)
        case .candidate(let candidate):
            try container.encode(MessageType.candidate.rawValue, forKey: .type)
            try container.encode(candidate.sdp, forKey: .candidate)
        case .notify(message: _):
            fatalError("not supported encoding 'notify'")
        case .ping:
            fatalError("not supported encoding 'ping'")
        case .pong:
            try container.encode(MessageType.pong.rawValue, forKey: .type)
        }
    }
    
}
