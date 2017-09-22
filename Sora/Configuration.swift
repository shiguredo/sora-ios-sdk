import Foundation
import WebRTC

public struct Configuration {
    
    class WebRTCConfiguration {
        var iceServerInfos: [ICEServerInfo]
        var iceTransportPolicy: ICETransportPolicy = .none
        
        var nativeValue: RTCConfiguration {
            let config = RTCConfiguration()
            config.iceServers = iceServerInfos.map { info in
                return info.nativeValue
            }
            config.iceTransportPolicy = iceTransportPolicy.nativeValue
            return config
        }
        
        init() {
            self.iceServerInfos = [
                ICEServerInfo(urls: [URL(string: "stun:stun.l.google.com:19302")!],
                              userName: nil,
                              credential: nil,
                              tlsSecurityPolicy: .secure)]
        }
        
    }
    
    class MediaConstraints {
        var mandatoryConstraints: [String: String] = [:]
        var optionalConstraints: [String: String] = [:]
        
        var nativeValue: RTCMediaConstraints {
            return RTCMediaConstraints(mandatoryConstraints: mandatoryConstraints,
                                       optionalConstraints: optionalConstraints)
        }
        
    }
    
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
    
    let mediaConstraints: MediaConstraints = MediaConstraints()
    let webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()
    
    public var signalingChannelType: SignalingChannel.Type = BasicSignalingChannel.self
    public var webSocketChannelType: WebSocketChannel.Type = BasicWebSocketChannel.self
    public var peerChannelType: PeerChannel.Type = BasicPeerChannel.self
    
    public var publisherStreamId: String = Configuration.defaultPublisherStreamId
    public var publisherVideoTrackId: String = Configuration.defaultPublisherVideoTrackId
    public var publisherAudioTrackId: String = Configuration.defaultPublisherAudioTrackId
    
    public init(url: URL, channelId: String, role: Role) {
        self.url = url
        self.channelId = channelId
        self.role = role
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
