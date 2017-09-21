import Foundation
import WebRTC

public enum Role {
    case publisher
    case subscriber
    case group
}

public enum VideoCodec {
    
    case `default`
    case vp8
    case vp9
    case h264
    
}

public enum AudioCodec {
    
    case `default`
    case opus
    case pcmu
    
}

public enum CameraPosition {
    case front
    case back
}

var iceTransportPolicyTable: [ICETransportPolicy: RTCIceTransportPolicy] =
    [.none: .none,
     .relay: .relay,
     .noHost: .noHost,
     .all: .all]

public enum ICETransportPolicy {
    
    case none
    case relay
    case noHost
    case all
    
    var nativeValue: RTCIceTransportPolicy {
        get {
            return iceTransportPolicyTable[self]!
        }
    }
    
}

public struct Configuration {
    
    public static let maxVideoVideoBitRate = 5000
    public static let defaultConnectionTimeout = 10
    public static let defaultPublisherStreamId: String = "mainStream"
    public static let defaultPublisherVideoTrackId: String = "mainVideo"
    public static let defaultPublisherAudioTrackId: String = "mainAudio"
    
    public var url: URL
    public var channelId: String
    public var role: Role
    public var metadata: String?
    public var connectionTimeout: Int = 30
    public var videoCodec: VideoCodec = .default
    public var videoBitRate: Int?
    public var audioCodec: AudioCodec = .default
    public var videoEnabled: Bool = true
    public var audioEnabled: Bool = true
    public var snapshotEnabled: Bool = false
    
    public var mandatoryConstraints: [String: String] = [:]
    public var optionalConstraints: [String: String] = [:]
    
    public var iceServerInfos: [ICEServerInfo]
    // offer 時にセットされる
    public var iceTransportPolicy: ICETransportPolicy = .none
    
    public var signalingChannelType: SignalingChannel.Type = BasicSignalingChannel.self
    public var webSocketChannelType: WebSocketChannel.Type = BasicWebSocketChannel.self
    public var peerChannelType: PeerChannel.Type = BasicPeerChannel.self
    
    public var publisherStreamId: String = Configuration.defaultPublisherStreamId
    public var publisherVideoTrackId: String = Configuration.defaultPublisherVideoTrackId
    public var publisherAudioTrackId: String = Configuration.defaultPublisherAudioTrackId
    
    var nativeConstraints: RTCMediaConstraints {
        get {
            return RTCMediaConstraints(mandatoryConstraints: mandatoryConstraints,
                                       optionalConstraints: optionalConstraints)
        }
    }
    
    var nativeConfiguration: RTCConfiguration {
        get {
            let config = RTCConfiguration()
            config.iceServers = iceServerInfos.map { info in
                return info.nativeValue
            }
            config.iceTransportPolicy = iceTransportPolicy.nativeValue
            return config
        }
    }
    
    public init(url: URL, channelId: String, role: Role) {
        self.url = url
        self.channelId = channelId
        self.role = role
        iceServerInfos = [
            ICEServerInfo(urls: [URL(string: "stun:stun.l.google.com:19302")!],
                          userName: nil,
                          credential: nil,
                          tlsSecurityPolicy: .secure)]
    }
    
}

var roleTable: PairTable<String, Role> =
    PairTable(pairs: [("publisher", .publisher),
                      ("subscriber", .subscriber),
                      ("group", .group)])

extension Role: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = roleTable.right(other: try container.decode(String.self))!
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(roleTable.left(other: self)!)
    }
    
}

var videoCodecTable: PairTable<String, VideoCodec> =
    PairTable(pairs: [("default", .default),
                      ("vp8", .vp8),
                      ("vp9", .vp9),
                      ("h264", .h264)])

extension VideoCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try videoCodecTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid codec type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(videoCodecTable.left(other: self)!)
    }
    
}

var audioCodecTable: PairTable<String, AudioCodec> =
    PairTable(pairs: [("default", .default),
                      ("opus", .opus),
                      ("pcmu", .pcmu)])

extension AudioCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try audioCodecTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid codec type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = audioCodecTable.left(other: self) {
            try container.encode(value)
        }
    }
    
}

extension ICEServerInfo: Codable {
    
    enum CodingKeys: String, CodingKey {
        case urls
        case userName = "username"
        case credential
    }
    
    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urls = try container.decode([URL].self, forKey: .urls)
        let userName = try container.decode(String.self, forKey: .userName)
        let credential = try container.decode(String.self, forKey: .credential)
        self.init(urls: urls,
                  userName: userName,
                  credential: credential,
                  tlsSecurityPolicy: .secure)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
}

extension ICETransportPolicy: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "relay" {
            self = .relay
        } else {
            throw DecodingError
                .dataCorruptedError(in: container,
                                    debugDescription: "invalid value")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}

extension Configuration: Codable {
    
    enum CodingKeys: String, CodingKey {
        case url
        case channelId
        case role
        case metadata
        case connectionTimeout
        case videoCodec
        case videoBitRate
        case audioCodec
        case videoEnabled
        case audioEnabled
        case snapshotEnabled
        case mandatoryConstraints
        case optionalConstraints
        case iceServerInfos
        case iceTransportPolicy
        case signalingChannelType
        case webSocketChannelType
        case peerChannelType
        case publisherStreamId
        case publisherVideoTrackId
        case publisherAudioTrackId
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let channelId = try container.decode(String.self, forKey: .channelId)
        self.init(url: url, channelId: channelId, role: .group)
        if container.contains(.metadata) {
            metadata = try container.decode(String.self, forKey: .metadata)
        }
        connectionTimeout = try container.decode(Int.self,
                                                 forKey: .connectionTimeout)
        videoCodec = try container.decode(VideoCodec.self, forKey: .videoCodec)
        if container.contains(.videoBitRate) {
            videoBitRate = try container.decode(Int.self, forKey: .videoBitRate)
        }
        audioCodec = try container.decode(AudioCodec.self, forKey: .audioCodec)
        videoEnabled = try container.decode(Bool.self, forKey: .videoEnabled)
        audioEnabled = try container.decode(Bool.self, forKey: .audioEnabled)
        snapshotEnabled = try container.decode(Bool.self, forKey: .snapshotEnabled)
        // TODO: others
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(role, forKey: .role)
        if let metadata = self.metadata {
            try container.encode(metadata, forKey: .metadata)
        }
        try container.encode(connectionTimeout, forKey: .connectionTimeout)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(videoEnabled, forKey: .videoEnabled)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        try container.encode(snapshotEnabled, forKey: .snapshotEnabled)
        // TODO: others
        
    }
    
}
