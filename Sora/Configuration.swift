import Foundation
import WebRTC

// MARK: デフォルト値

private let defaultPublisherStreamId: String = "mainStream"
private let defaultPublisherVideoTrackId: String = "mainVideo"
private let defaultPublisherAudioTrackId: String = "mainAudio"

/**
 クライアントに関する設定です。
 */
public struct Configuration {
    
    // MARK: - 接続に関する設定
    
    /// サーバーの URL
    public var url: URL
    
    /// チャネル ID
    public var channelId: String
    
    /// ロール
    public var role: Role
    
    /// このプロパティは `signalingConnectMetadata` に置き換えられました。
    @available(*, deprecated, renamed: "signalingConnectMetadata",
    message: "このプロパティは signalingConnectMetadata に置き換えられました。")
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
    
    /// サイマルキャストの可否。 `true` であればサイマルキャストを有効にします。
    public var simulcastEnabled: Bool = false

    /// サイマルキャストの品質。
    /// ロールが `.subscriber` または `.groupSub` のときのみ有効です。
    /// デフォルトは `.high` です。
    public var simulcastQuality: SimulcastQuality = .high

    /**
     最大話者数。マルチストリーム時のみ有効です。
     
     このプロパティをセットすると、直近に発言した話者の映像のみを参加者に配信できます。
     映像の配信者数を制限できるため、参加者の端末やサーバーの負荷を減らすことが可能です。
     詳しくは Sora の音声検出 (VAD) 機能を参照してください。
    */
    public var maxNumberOfSpeakers: Int?

    /// WebRTC に関する設定
    public var webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()

    /// `connect` シグナリングに含めるメタデータ
    public var signalingConnectMetadata: Encodable?
    
    /// `connect` シグナリングに含める通知用のメタデータ
    public var signalingConnectNotifyMetadata: Encodable?
    
    // MARK: - イベントハンドラ
    
    /// シグナリングチャネルに関するイベントハンドラ
    public var signalingChannelHandlers: SignalingChannelHandlers = SignalingChannelHandlers()
    
    /// ピアチャネルに関するイベントハンドラ
    public var peerChannelHandlers: PeerChannelHandlers = PeerChannelHandlers()
    
    /// メディアチャネルに関するイベントハンドラ
    public var mediaChannelHandlers: MediaChannelHandlers = MediaChannelHandlers()

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
        case simulcastEnabled
        case simulcastQuality
        case maxNumberOfSpeakers
        case webRTCConfiguration
        case signalingConnectMetadata
        case signalingConnectNotifyMetadata
        case signalingChannelType
        case webSocketChannelType
        case peerChannelType
        case publisherStreamId
        case publisherVideoTrackId
        case publisherAudioTrackId
    }
    
    public init(from decoder: Decoder) throws {
        // NOTE: メタデータとイベントハンドラはサポートしない
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let channelId = try container.decode(String.self, forKey: .channelId)
        let role = try container.decode(Role.self, forKey: .role)
        self.init(url: url, channelId: channelId, role: role)
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
        if container.contains(.maxNumberOfSpeakers) {
            maxNumberOfSpeakers = try container.decode(Int.self,
                                                       forKey: .maxNumberOfSpeakers)
        }
        simulcastEnabled = try container.decode(Bool.self, forKey: .simulcastEnabled)
        simulcastQuality = try container.decode(SimulcastQuality.self,
                                                forKey: .simulcastQuality)
        webRTCConfiguration = try container.decode(WebRTCConfiguration.self,
                                                   forKey: .webRTCConfiguration)
        publisherStreamId = try container.decode(String.self,
                                                 forKey: .publisherStreamId)
        publisherVideoTrackId = try container.decode(String.self,
                                                     forKey: .publisherVideoTrackId)
        publisherAudioTrackId = try container.decode(String.self,
                                                     forKey: .publisherAudioTrackId)
        // TODO: channel types
    }
    
    public func encode(to encoder: Encoder) throws {
        // NOTE: メタデータとイベントハンドラはサポートしない
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(role, forKey: .role)
        try container.encode(simulcastEnabled, forKey: .simulcastEnabled)
        try container.encode(simulcastQuality, forKey: .simulcastQuality)
        try container.encode(connectionTimeout, forKey: .connectionTimeout)
        try container.encode(videoEnabled, forKey: .videoEnabled)
        try container.encode(videoCodec, forKey: .videoCodec)
        if let bitRate = self.videoBitRate {
            try container.encode(bitRate, forKey: .videoBitRate)
        }
        try container.encode(videoCapturerDevice, forKey: .videoCapturerDevice)
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        if let num = self.maxNumberOfSpeakers {
            try container.encode(num, forKey: .maxNumberOfSpeakers)
        }
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
