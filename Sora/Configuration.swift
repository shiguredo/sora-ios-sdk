import Foundation
import WebRTC

private let defaultPublisherStreamId: String = "mainStream"
private let defaultPublisherVideoTrackId: String = "mainVideo"
private let defaultPublisherAudioTrackId: String = "mainAudio"

/**
 クライアントに関する設定です。
 */
public struct Configuration {
    
    // MARK: デフォルト値
    
    /// 映像の最大ビットレート
    public static let maxVideoVideoBitRate = 5000
    
    /// デフォルトの接続タイムアウト時間 (秒)
    public static let defaultConnectionTimeout = 10

    // MARK: - 接続に関する設定
    
    /// サーバーの URL
    public var url: URL
    
    /// チャネル ID
    public var channelId: String
    
    /// ロール
    public var role: Role
    
    /// メタデータ。 `connect` シグナリングメッセージにセットされます。
    public var metadata: String?
    
    /**
     接続試行中のタイムアウト (秒) 。
     指定した時間内に接続が成立しなければ接続試行を中止します。
     */
    public var connectionTimeout: Int = 30
    
    /// 映像コーデック。デフォルトは `.default` です。
    public var videoCodec: VideoCodec = .default
    
    /// 映像ビットレート。デフォルトは無指定です。
    public var videoBitRate: Int?
    
    /// 映像キャプチャーの種別。
    /// デフォルトは `.camera(settings: CameraVideoCapturer.Settings.default)` です。
    public var videoCapturerDevice: VideoCapturerDevice = .camera(settings: .default)
    
    /// 音声コーデック。デフォルトは `.default` です。
    public var audioCodec: AudioCodec = .default
    
    /// 映像の可否。 `true` であれば映像を送受信します。
    /// デフォルトは `true` です。
    public var videoEnabled: Bool = true
    
    /// 音声の可否。 `true` であれば音声を送受信します。
    /// デフォルトは `true` です。
    public var audioEnabled: Bool = true
    
    /// スナップショットの可否。 `true` であればスナップショットが有効になります。
    /// デフォルトは `false` です。
    public var snapshotEnabled: Bool = false
    
    /// WebRTC に関する設定
    public var webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()
    
    // MARK: - 接続チャネルに関する設定
    
    /**
     生成されるシグナリングチャネルの型。
     何も指定しなければデフォルトのシグナリングチャネルが生成されます。
     */
    public var signalingChannelType: SignalingChannel.Type?
    
    /**
     生成される WebSocket チャネルの型。
     何も指定しなければデフォルトの WebSocket チャネルが生成されます。
     */
    public var webSocketChannelType: WebSocketChannel.Type?
    
    /**
     生成されるピアチャネルの型。
     何も指定しなければデフォルトのピアチャネルが生成されます。
     */
    public var peerChannelType: PeerChannel.Type?
    
    var _signalingChannelType: SignalingChannel.Type {
        get {
            return signalingChannelType ?? BasicSignalingChannel.self
        }
    }
    
    var _webSocketChannelType: WebSocketChannel.Type {
        get {
            return webSocketChannelType ?? BasicWebSocketChannel.self
        }
    }
    
    var _peerChannelType: PeerChannel.Type {
        get {
            return peerChannelType ?? BasicPeerChannel.self
        }
    }
    
    // MARK: パブリッシャーに関する設定
    
    /// パブリッシャーのストリームの ID です。
    /// 通常、指定する必要はありません。
    public var publisherStreamId: String = defaultPublisherStreamId
    
    /// パブリッシャーの映像トラックの ID です。
    /// 通常、指定する必要はありません。
    public var publisherVideoTrackId: String = defaultPublisherVideoTrackId
    
    /// パブリッシャーの音声トラックの ID です。
    /// 通常、指定する必要はありません。
    public var publisherAudioTrackId: String = defaultPublisherAudioTrackId
    
    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter url: サーバーの URL
     - parameter channelId: チャネル ID
     - parameter role: ロール
     */
    public init(url: URL, channelId: String, role: Role) {
        self.url = url
        self.channelId = channelId
        self.role = role
    }
    
}

/// :nodoc:
extension Configuration: Codable {
    
    enum CodingKeys: String, CodingKey {
        case url
        case channelId
        case role
        case metadata
        case connectionTimeout
        case videoCodec
        case videoBitRate
        case videoCapturerDevice
        case audioCodec
        case videoEnabled
        case audioEnabled
        case snapshotEnabled
        case webRTCConfiguration
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
        videoCapturerDevice = try container
            .decode(VideoCapturerDevice.self, forKey: .videoCapturerDevice)
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
        try container.encode(videoCapturerDevice, forKey: .videoCapturerDevice)
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        try container.encode(snapshotEnabled, forKey: .snapshotEnabled)
        try container.encode(webRTCConfiguration, forKey: .webRTCConfiguration)
        try container.encode(publisherStreamId, forKey: .publisherStreamId)
        try container.encode(publisherVideoTrackId, forKey: .publisherVideoTrackId)
        try container.encode(publisherAudioTrackId, forKey: .publisherAudioTrackId)
        try container.encode(String(describing: type(of: _peerChannelType))
            ,
                             forKey: .peerChannelType)
        try container.encode(String(describing: type(of: _signalingChannelType))
            ,
                             forKey: .signalingChannelType)
        try container.encode(String(describing: type(of: _webSocketChannelType))
            ,
                             forKey: .webSocketChannelType)
    }
    
}
