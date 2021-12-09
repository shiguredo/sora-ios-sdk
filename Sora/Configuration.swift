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
    
    /**
     スポットライトの設定
     */
    public enum Spotlight {
        
        /// 有効
        case enabled
        
        /// 無効
        case disabled
        
    }
    
    /// サーバーの URL
    public var url: URL
    
    /// チャネル ID
    public var channelId: String
    
    /// クライアント ID
    public var clientId: String?
    
    /// ロール
    public var role: Role
    
    /// マルチストリームの可否
    public var multistreamEnabled: Bool
    
    /// :nodoc:
    var isMultistream: Bool {
        switch role {
        case .group, .groupSub:
            return true
        default:
            return multistreamEnabled
        }
    }
    
    /// :nodoc:
    var isSender: Bool {
        switch role {
        case .publisher, .group, .sendonly, .sendrecv:
            return true
        default:
            return false
        }
    }
    
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
    /// 廃止されました。
    @available(*, unavailable, message: "videoCapturerDevice は廃止されました。")
    public var videoCapturerDevice: VideoCapturerDevice? = nil

    /// カメラの設定
    public var cameraSettings: CameraSettings = CameraSettings.default
    
    /// 音声コーデック。デフォルトは `.default` です。
    public var audioCodec: AudioCodec = .default

    /// 音声ビットレート。デフォルトは無指定です。
    public var audioBitRate: Int?

    /// 映像の可否。 `true` であれば映像を送受信します。
    /// デフォルトは `true` です。
    public var videoEnabled: Bool = true
    
    /// 音声の可否。 `true` であれば音声を送受信します。
    /// デフォルトは `true` です。
    public var audioEnabled: Bool = true
    
    /// サイマルキャストの可否。 `true` であればサイマルキャストを有効にします。
    public var simulcastEnabled: Bool = false

    /// サイマルキャストでの映像の種類。
    /// ロールが `.sendrecv` または `.recvonly` のときのみ有効です。
    public var simulcastRid: SimulcastRid?

    /// スポットライトの可否
    /// 詳しくは Sora のスポットライト機能を参照してください。
    public var spotlightEnabled: Spotlight = .disabled
    
    /// スポットライトの対象人数
    @available(*, deprecated, renamed: "spotlightNumber",
    message: "このプロパティは spotlightNumber に置き換えられました。")
    public var spotlight: Int? {
        get {
            spotlightNumber
        }
        set {
            spotlightNumber = newValue
        }
    }

    /// スポットライトの対象人数
    @available(*, deprecated, renamed: "spotlightNumber",
    message: "このプロパティは spotlightNumber に置き換えられました。")
    public var activeSpeakerLimit: Int? {
        get {
            spotlightNumber
        }
        set {
            spotlightNumber = newValue
        }
    }

    /// スポットライトの対象人数
    public var spotlightNumber: Int?
    
    /// スポットライト機能でフォーカスした場合の映像の種類
    public var spotlightFocusRid: SpotlightRid = .unspecified

    /// スポットライト機能でフォーカスしていない場合の映像の種類
    public var spotlightUnfocusRid: SpotlightRid = .unspecified

    /// WebRTC に関する設定
    public var webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()

    /// `connect` シグナリングに含めるメタデータ
    public var signalingConnectMetadata: Encodable?
    
    /// `connect` シグナリングに含める通知用のメタデータ
    public var signalingConnectNotifyMetadata: Encodable?

    /// シグナリングにおける DataChannel の利用可否。
    /// `true` の場合、接続確立後のシグナリングを DataChannel 経由で行います。
    public var dataChannelSignaling: Bool?

    /// DataChannel 経由のシグナリングを利用している際に、 WebSocket が切断されても Sora との接続を継続するためのフラグ。
    /// 詳細: https://sora-doc.shiguredo.jp/DATA_CHANNEL_SIGNALING#07c227
    public var ignoreDisconnectWebSocket: Bool?
    
    // MARK: - イベントハンドラ
    
    /// WebSocket チャネルに関するイベントハンドラ
    public var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
    /// シグナリングチャネルに関するイベントハンドラ
    @available(*, unavailable, message: "廃止されました。 mediaChannelHandlers を利用してください。")
    public var signalingChannelHandlers: SignalingChannelHandlers = SignalingChannelHandlers()
    
    /// ピアチャネルに関するイベントハンドラ
    @available(*, unavailable, message: "廃止されました。 mediaChannelHandlers を利用してください。")
    public var peerChannelHandlers: PeerChannelHandlers = PeerChannelHandlers()
    
    /// メディアチャネルに関するイベントハンドラ
    public var mediaChannelHandlers: MediaChannelHandlers = MediaChannelHandlers()

    // MARK: - 接続チャネルに関する設定
    /**
     生成されるシグナリングチャネルの型。
     何も指定しなければデフォルトのシグナリングチャネルが生成されます。
     */
    @available(*, unavailable, message: "signalingChannelType は廃止されました。")
    public var signalingChannelType: Any? = nil

    /**
     生成される WebSocket チャネルの型。
     何も指定しなければデフォルトの WebSocket チャネルが生成されます。
     */
    public var webSocketChannelType: WebSocketChannel.Type?

    /**
     生成されるピアチャネルの型。
     何も指定しなければデフォルトのピアチャネルが生成されます。
     */
    @available(*, unavailable, message: "peerChannelType は廃止されました。")
    public var peerChannelType: Any? = nil

    var _webSocketChannelType: WebSocketChannel.Type {
        get {
            var type: WebSocketChannel.Type = BasicWebSocketChannel.self
            if #available(iOS 13, *) {
                if allowsURLSessionWebSocketChannel {
                    type = URLSessionWebSocketChannel.self
                }
            }
            return type
        }
    }
    
    
    /// :nodoc:
    public var allowsURLSessionWebSocketChannel: Bool = true
    
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
     このイニシャライザーは ``init(url:channelId:role:multistreamEnabled:)`` に置き換えられました。
     以降はマルチストリームの可否を明示的に指定してください。
     このイニシャライザーはマルチストリームを無効にして初期化します。
     
     - parameter url: サーバーの URL
     - parameter channelId: チャネル ID
     - parameter role: ロール
     */
    ///
    @available(*, deprecated, renamed: "init(url:channelId:role:multistreamEnabled:)",
    message: "このイニシャライザーは init(url:channelId:role:multistreamEnabled:) に置き換えられました。")
    public init(url: URL,
                channelId: String,
                role: Role) {
        self.url = url
        self.channelId = channelId
        self.role = role
        self.multistreamEnabled = false
    }
    
    /**
     初期化します。
     
     - parameter url: サーバーの URL
     - parameter channelId: チャネル ID
     - parameter role: ロール
     - parameter multistreamEnabled: マルチストリームの可否
     */
    public init(url: URL,
                channelId: String,
                role: Role,
                multistreamEnabled: Bool) {
        self.url = url
        self.channelId = channelId
        self.role = role
        self.multistreamEnabled = multistreamEnabled
    }
    
}

/// :nodoc:
extension Configuration: Codable {
    
    enum CodingKeys: String, CodingKey {
        case url
        case channelId
        case clientId
        case role
        case multistreamEnabled
        case metadata
        case connectionTimeout
        case videoCodec
        case videoBitRate
        case videoCapturerDevice
        case audioCodec
        case audioBitRate
        case videoEnabled
        case audioEnabled
        case simulcastEnabled
        case simulcastRid
        case spotlightEnabled
        case spotlightNumber
        case spotlightFocusRid
        case spotlightUnfocusRid
        case webRTCConfiguration
        case signalingConnectMetadata
        case signalingConnectNotifyMetadata
        case webSocketChannelType
        case publisherStreamId
        case publisherVideoTrackId
        case publisherAudioTrackId
    }
    
    public init(from decoder: Decoder) throws {
        // NOTE: メタデータとイベントハンドラはサポートしない
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let channelId = try container.decode(String.self, forKey: .channelId)
        let clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        let role = try container.decode(Role.self, forKey: .role)
        let multistreamEnabled = try container.decode(Bool.self, forKey: .multistreamEnabled)
        self.init(url: url,
                  channelId: channelId,
                  role: role,
                  multistreamEnabled: multistreamEnabled)
        connectionTimeout = try container.decode(Int.self,
                                                 forKey: .connectionTimeout)
        videoEnabled = try container.decode(Bool.self, forKey: .videoEnabled)
        if container.contains(.videoBitRate) {
            videoBitRate = try container.decode(Int.self, forKey: .videoBitRate)
        }
        audioCodec = try container.decode(AudioCodec.self, forKey: .audioCodec)
        audioEnabled = try container.decode(Bool.self, forKey: .audioEnabled)
        audioBitRate = try container.decodeIfPresent(Int.self, forKey: .audioBitRate)
        spotlightEnabled = try container.decode(Spotlight.self, forKey: .spotlightEnabled)
        spotlightNumber = try container.decode(Int.self, forKey: .spotlightNumber)
        spotlightFocusRid = try container.decodeIfPresent(SpotlightRid.self, forKey: .spotlightFocusRid) ?? .unspecified
        spotlightUnfocusRid = try container.decodeIfPresent(SpotlightRid.self, forKey: .spotlightUnfocusRid) ?? .unspecified
        simulcastEnabled = try container.decode(Bool.self, forKey: .simulcastEnabled)
        simulcastRid = try container.decode(SimulcastRid.self,
                                                forKey: .simulcastRid)
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
        try container.encodeIfPresent(clientId, forKey: .clientId)
        try container.encode(role, forKey: .role)
        try container.encode(simulcastEnabled, forKey: .simulcastEnabled)
        try container.encode(simulcastRid, forKey: .simulcastRid)
        try container.encode(connectionTimeout, forKey: .connectionTimeout)
        try container.encode(videoEnabled, forKey: .videoEnabled)
        try container.encode(videoCodec, forKey: .videoCodec)
        if let bitRate = self.videoBitRate {
            try container.encode(bitRate, forKey: .videoBitRate)
        }
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        try container.encodeIfPresent(audioBitRate, forKey: .audioBitRate)
        try container.encodeIfPresent(spotlightNumber, forKey: .spotlightNumber)
        try container.encode(webRTCConfiguration, forKey: .webRTCConfiguration)
        if spotlightFocusRid != .unspecified {
            try container.encodeIfPresent(spotlightFocusRid, forKey: .spotlightFocusRid)
        }
        if spotlightUnfocusRid != .unspecified {
            try container.encodeIfPresent(spotlightUnfocusRid, forKey: .spotlightUnfocusRid)
        }
        try container.encode(publisherStreamId, forKey: .publisherStreamId)
        try container.encode(publisherVideoTrackId, forKey: .publisherVideoTrackId)
        try container.encode(publisherAudioTrackId, forKey: .publisherAudioTrackId)
        try container.encode(String(describing: type(of: _webSocketChannelType))
            ,
                             forKey: .webSocketChannelType)
    }
    
}

/// :nodoc:
extension Configuration.Spotlight: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "enabled":
            self = .enabled
        case "disabled":
            self = .disabled
        default:
            self = .disabled
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled:
            try container.encode("enabled")
        case .disabled:
            try container.encode("disabled")
        }
    }
    
}
