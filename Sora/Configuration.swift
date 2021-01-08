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
        
        /// スポットライトレガシー機能
        case legacy
        
    }
    
    /// サーバーの URL
    public var url: URL
    
    /// チャネル ID
    public var channelId: String
    
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
    
    /**
     映像キャプチャーの種別。デフォルトは無指定です。
     
     無指定の場合、 `Sora` はストリームへの接続完了時に `VideoCapturer` を自動的に設定**しません**。
     したがってこのオプションを使用する場合は、ストリームへの接続完了後、自身でストリームの `VideoCapturer` を設定しない限り、映像は配信されません。
     また無指定の場合、 `Sora` はストリームから切断したタイミングに `VideoCapturer` を自動的に終了**しません**。
     必要に応じて終了時に `VideoCapturer` を停止する処理を忘れないようにしてください。
     
     以下のような場合に無指定にすることをおすすめします。
     
     - カメラ以外の映像ソースから映像のキャプチャと配信を行いたいとき。
     - 映像のキャプチャ開始・終了タイミングを細かく調整したいとき。
     */
    public var videoCapturerDevice: VideoCapturerDevice?
    
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
    /// ロールが `.recvonly` のときのみ有効です。
    public var simulcastRid: SimulcastRid?

    /// スポットライトの可否
    /// 詳しくは Sora のスポットライト機能を参照してください。
    public var spotlightEnabled: Spotlight = .disabled
    
    /// スポットライトの対象人数
    @available(*, deprecated, renamed: "activeSpeakerLimit",
    message: "このプロパティは activeSpeakerLimit に置き換えられました。")
    public var spotlight: Int? {
        get {
            activeSpeakerLimit
        }
        set {
            activeSpeakerLimit = newValue
        }
    }

    /// スポットライトの対象人数
    public var activeSpeakerLimit: Int?
    
    /// WebRTC に関する設定
    public var webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()

    /// `connect` シグナリングに含めるメタデータ
    public var signalingConnectMetadata: Encodable?
    
    /// `connect` シグナリングに含める通知用のメタデータ
    public var signalingConnectNotifyMetadata: Encodable?
    
    // MARK: - イベントハンドラ
    
    /// WebSocket チャネルに関するイベントハンドラ
    public var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
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
            var type: WebSocketChannel.Type = BasicWebSocketChannel.self
            if #available(iOS 13, *) {
                if allowsURLSessionWebSocketChannel {
                    type = URLSessionWebSocketChannel.self
                }
            }
            return type
        }
    }
    
    var _peerChannelType: PeerChannel.Type {
        get {
            return peerChannelType ?? BasicPeerChannel.self
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
