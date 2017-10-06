import Foundation
import WebRTC

private let defaultPublisherStreamId: String = "mainStream"
private let defaultPublisherVideoTrackId: String = "mainVideo"
private let defaultPublisherAudioTrackId: String = "mainAudio"

public struct Configuration {
    
    // MARK: デフォルト値
    
    /// 映像の最大ビットレート
    public static let maxVideoVideoBitRate = 5000
    
    /// デフォルトの接続タイムアウト時間 (秒)
    public static let defaultConnectionTimeout = 10

    // MARK: - 接続に関する設定
    
    public var url: URL
    public var channelId: String
    public var role: Role
    public var metadata: String?
    public var connectionTimeout: Int = 30
    public var videoCodec: VideoCodec = .default
    public var videoBitRate: Int?
    public var videoCapturerOption: VideoCapturerOption = .camera
    public var audioCodec: AudioCodec = .default
    public var videoEnabled: Bool = true
    public var audioEnabled: Bool = true
    public var snapshotEnabled: Bool = false
    
    // MARK: WebRTC に関する設定
    
    public var webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()
    
    // MARK: - 接続チャネルに関する設定
    
    public var signalingChannelType: SignalingChannel.Type = BasicSignalingChannel.self
    public var webSocketChannelType: WebSocketChannel.Type = BasicWebSocketChannel.self
    public var peerChannelType: PeerChannel.Type = BasicPeerChannel.self
    
    // MARK: パブリッシャーに関する設定
    
    public var publisherStreamId: String = defaultPublisherStreamId
    public var publisherVideoTrackId: String = defaultPublisherVideoTrackId
    public var publisherAudioTrackId: String = defaultPublisherAudioTrackId
    
    // MARK: - 初期化
    
    public init(url: URL, channelId: String, role: Role) {
        self.url = url
        self.channelId = channelId
        self.role = role
    }
    
}

/**
 :nodoc:
 */
extension Configuration: Codable {
    
    enum CodingKeys: String, CodingKey {
        case url
        case channelId
        case role
        case metadata
        case connectionTimeout
        case videoCodec
        case videoBitRate
        case videoCapturerOption
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
        let role = try container.decode(Role.self, forKey: .role)
        self.init(url: url, channelId: channelId, role: role)
        if container.contains(.metadata) {
            metadata = try container.decode(String.self, forKey: .metadata)
        }
        connectionTimeout = try container.decode(Int.self,
                                                 forKey: .connectionTimeout)
        videoEnabled = try container.decode(Bool.self, forKey: .videoEnabled)
        videoCodec = try container.decode(VideoCodec.self, forKey: .videoCodec)
        videoCapturerOption = try container
            .decode(VideoCapturerOption.self, forKey: .videoCapturerOption)
        if container.contains(.videoBitRate) {
            videoBitRate = try container.decode(Int.self, forKey: .videoBitRate)
        }
        audioCodec = try container.decode(AudioCodec.self, forKey: .audioCodec)
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
        try container.encode(videoEnabled, forKey: .videoEnabled)
        try container.encode(videoCodec, forKey: .videoCodec)
        if let bitRate = self.videoBitRate {
            try container.encode(bitRate, forKey: .videoBitRate)
        }
        try container.encode(videoCapturerOption, forKey: .videoCapturerOption)
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        try container.encode(snapshotEnabled, forKey: .snapshotEnabled)

        // TODO: others
        
    }
    
}
