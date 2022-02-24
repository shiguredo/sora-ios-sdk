import Foundation
import WebRTC

/// :nodoc:
private func serializeMetadataList(_ data: Any?) -> [SignalingNotifyMetadata]? {
    guard let array = data as? [[String: Any]] else {
        Logger.info(type: .signaling,
                    message: "downcast failed in serializeMetadataList. data: \(String(describing: data))")
        return nil
    }

    let result = array.map { (dict: [String: Any]) -> SignalingNotifyMetadata in
        var signalingNotifyMetadata = SignalingNotifyMetadata()
        if dict.keys.contains("client_id"), let clinetId = dict["client_id"] as? String? {
            signalingNotifyMetadata.clientId = clinetId
        }

        if dict.keys.contains("connection_id"), let connectionId = dict["connection_id"] as? String? {
            signalingNotifyMetadata.connectionId = connectionId
        }

        if dict.keys.contains("authn_metadata") {
            signalingNotifyMetadata.authnMetadata = dict["authn_metadata"]
        }

        if dict.keys.contains("authz_metadata") {
            signalingNotifyMetadata.authzMetadata = dict["authz_metadata"]
        }

        if dict.keys.contains("metadata") {
            signalingNotifyMetadata.metadata = dict["metadata"]
        }

        return signalingNotifyMetadata
    }

    return result
}

/// :nodoc:
private func updateMetadata(signaling: Signaling, data: Data) -> Signaling {
    var json: [String: Any]
    do {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        json = jsonObject as! [String: Any]
    } catch {
        // JSON のシリアライズが失敗した場合は、引数として渡された signaling をそのまま返し、処理を継続する
        Logger.error(type: .signaling,
                     message: "updateMetadata failed. error: \(error.localizedDescription), data: \(data)")
        return signaling
    }

    switch signaling {
    case var .offer(message):
        // TODO: if json.keys.contains("key") を if let に書き換えたい
        if json.keys.contains("metadata") {
            message.metadata = json["metadata"]
        }
        if let dataChannels = json["data_channels"] as? [[String: Any]] {
            message.dataChannels = dataChannels
        }
        return .offer(message)
    case var .push(message):
        if json.keys.contains("data") {
            message.data = json["data"]
        }
        return .push(message)
    case var .notify(message):
        if json.keys.contains("authn_metadata") {
            message.authnMetadata = json["authn_metadata"]
        }
        if json.keys.contains("authz_metadata") {
            message.authzMetadata = json["authz_metadata"]
        }
        if json.keys.contains("metadata") {
            message.metadata = json["metadata"]
        }
        if json.keys.contains("metadata_list") {
            message.metadataList = serializeMetadataList(json["metadata_list"])
        }
        if json.keys.contains("data") {
            message.data = serializeMetadataList(json["data"])
        }
        return .notify(message)
    default:
        return signaling
    }
}

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

    /// "re-offer" シグナリング
    case reOffer(SignalingReOffer)

    /// "re-answer" シグナリング
    case reAnswer(SignalingReAnswer)

    /// "candidate" シグナリング
    case candidate(SignalingCandidate)

    /// "notify" シグナリング
    case notify(SignalingNotify)

    /// "ping" シグナリング
    case ping(SignalingPing)

    /// "pong" シグナリング
    case pong(SignalingPong)

    /// "disconnect" シグナリング
    case disconnect(SignalingDisconnect)

    /// "pong" シグナリング
    case push(SignalingPush)

    /// "switch" シグナリング
    case switched(SignalingSwitched)

    /// "redirect" シグナリング
    case redirect(SignalingRedirect)

    /// :nodoc:
    public static func decode(_ data: Data) -> Result<Signaling, Error> {
        do {
            let decoder = JSONDecoder()
            var signaling = try decoder.decode(Signaling.self, from: data)
            signaling = updateMetadata(signaling: signaling, data: data)
            return .success(signaling)
        } catch {
            return .failure(error)
        }
    }

    /// :nodoc:
    public func typeName() -> String {
        switch self {
        case .connect:
            return "connect"
        case .offer:
            return "offer"
        case .answer:
            return "answer"
        case .update:
            return "update"
        case .reOffer:
            return "re-offer"
        case .reAnswer:
            return "re-answer"
        case .candidate:
            return "candidate"
        case .notify:
            return "notify"
        case .ping:
            return "ping"
        case .pong:
            return "pong"
        case .disconnect:
            return "disconnect"
        case .push:
            return "push"
        case .switched:
            return "switched"
        case .redirect:
            return "redirect"
        }
    }
}

/**
 サイマルキャストでの映像の種類を表します。
 */
public enum SimulcastRid {
    /// r0
    case r0

    /// r1
    case r1

    /// r2
    case r2
}

/**
 スポットライトの映像の種類を表します 。
 */
public enum SpotlightRid {
    /**
     SpotlightRid が設定されていない状態

     変数の型を SpotlightRid? にした場合、 .none が Optional.none と SpotlightRid.none の
     どちらを指しているか分かりにくいという問題がありました。
     この問題を解決するため、変数に値が設定されていない状態を表す .unspecified を定義するとともに、
     SpotlightRid を Optional にラップせずに利用することとしました。
     */
    case unspecified

    /// 映像を受信しない
    case none

    /// r0
    case r0

    /// r1
    case r1

    /// r2
    case r2
}

/**
 シグナリングに含まれるメタデータ (任意のデータ) を表します。
 サーバーから受信するシグナリングにメタデータが含まれる場合は、
 `decoder` プロパティに JSON デコーダーがセットされます。
 受信したメタデータを任意のデータ型に変換するには、このデコーダーを使ってください。
 */
@available(*, unavailable,
           message: "SignalingMetadata を利用して、メタデータをデコードする方法は廃止されました。 Any? を任意の型にキャストしてデコードしてください。")
public struct SignalingMetadata {}

@available(*, unavailable, renamed: "SignalingNotifyMetadata",
           message: "SignalingClientMetadata は SignalingNotifyMetadata に置き換えられました。")
public struct SignalingClientMetadata {}

/**
 シグナリングに含まれる、同チャネルに接続中のクライアントに関するメタデータ (任意のデータ) を表します。
 */
public struct SignalingNotifyMetadata {
    /// クライアント ID
    public var clientId: String?

    /// 接続 ID
    public var connectionId: String?

    /// シグナリング接続時にクライアントが指定した値
    public var authnMetadata: Any?

    /// Sora の認証ウェブフックの戻り値で指定された値
    public var authzMetadata: Any?

    /// メタデータ
    public var metadata: Any?
}

/// メッセージの方向
public enum MessagingDirection: String, Encodable {
    /// 送受信
    case sendrecv

    /// 送信のみ
    case sendonly

    /// 受信のみ
    case recvonly
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

    /// クライアント ID
    public var clientId: String?

    /// メタデータ
    public var metadata: Encodable?

    /// notify メタデータ
    public var notifyMetadata: Encodable?

    /// SDP 。クライアントの判別に使われます。
    public var sdp: String?

    /// マルチストリームの可否
    public var multistreamEnabled: Bool?

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

    /// スポットライトの可否
    public var spotlightEnabled: Configuration.Spotlight

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

    /// スポットライト機能でフォーカスした場合に受信する映像の種類
    public var spotlightFocusRid: SpotlightRid

    /// スポットライト機能でフォーカスしていない場合に受信する映像の種類
    public var spotlightUnfocusRid: SpotlightRid

    /// サイマルキャストの可否
    public var simulcastEnabled: Bool

    /// サイマルキャストでの映像の種類
    public var simulcastRid: SimulcastRid?

    /// :nodoc:
    public var soraClient: String?

    /// :nodoc:
    public var webRTCVersion: String?

    /// :nodoc:
    public var environment: String?

    /// DataChannel 経由のシグナリングを利用する
    public var dataChannelSignaling: Bool?

    /// DataChannel 経由のシグナリングを有効にした際、 WebSocket の接続が切れても Sora との接続を切断しない
    public var ignoreDisconnectWebSocket: Bool?

    /// type: redicret 受信後の再接続
    public var redirect: Bool?
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
        /// エンコーディングの有効・無効
        public let active: Bool

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

    /// クライアント ID
    public let clientId: String

    /// 接続 ID
    public let connectionId: String

    /// SDP メッセージ
    public let sdp: String

    /// クライアントが更新すべき設定
    public let configuration: Configuration?

    /// メタデータ
    public var metadata: Any?

    /// エンコーディング
    public let encodings: [Encoding]?

    /// データ・チャンネルの設定
    public var dataChannels: [[String: Any]]?
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
 "re-offer" メッセージ
 */
public struct SignalingReOffer {
    /// SDP メッセージ
    public let sdp: String
}

/**
 "re-answer" メッセージ
 */
public struct SignalingReAnswer {
    /// SDP メッセージ
    public let sdp: String
}

/**
 "push" シグナリングメッセージを表します。
 このメッセージは Sora のプッシュ API を使用して送信されたデータです。
 */
public struct SignalingPush {
    /// プッシュ通知で送信される JSON データ
    public var data: Any? = {}
}

/**
 "switched" シグナリングメッセージを表します。
 */
public struct SignalingSwitched {
    /// DataChannel 経由のシグナリングを有効にした際、 WebSocket の接続が切れても Sora との接続を切断しない
    public var ignoreDisconnectWebSocket: Bool?
}

/**
 "redirect" シグナリングメッセージを表します。
 */
public struct SignalingRedirect {
    /// redirect する URL
    public var location: String
}

/**
 "notify" シグナリングメッセージで通知されるイベントの種別です。
 詳細は Sora のドキュメントを参照してください。
 廃止されました。
 */
@available(*, unavailable, message: "SignalingNotifyEventType は廃止されました。")
public enum SignalingNotifyEventType {}

/// "notify" シグナリングメッセージを表します。
///
/// type:notify の event_type ごとに struct を定義するのではなく、 type: notify に対して1つの struct を定義しています。
/// そのため、アクセスする際は eventType をチェックする必要があります。
///
/// 上記の理由により、この struct では、 eventType 以外のパラメーターを Optional にする必要があります。
public struct SignalingNotify {
    // MARK: イベント情報

    /// イベントの種別
    public var eventType: String

    // MARK: 接続情報

    /// ロール
    public var role: SignalingRole?

    /// クライアント ID
    public var clientId: String?

    /// 接続 ID
    public var connectionId: String?

    /// 音声の可否
    public var audioEnabled: Bool?

    /// 映像の可否
    public var videoEnabled: Bool?

    /// メタデータ
    public var metadata: Any?

    /// シグナリング接続時にクライアントが指定した値
    public var authnMetadata: Any?

    /// Sora の認証ウェブフックの戻り値で指定された値
    public var authzMetadata: Any?

    /// メタデータのリスト
    public var metadataList: [SignalingNotifyMetadata]?

    /// メタデータのリスト
    public var data: [SignalingNotifyMetadata]?

    // MARK: 接続状態

    /// 接続時間 (分)
    public var connectionTime: Int?

    /// 接続中のクライアントの数
    public var connectionCount: Int?

    /// 接続中のパブリッシャーの数
    @available(*, deprecated, message: "このプロパティは channelSendonlyConnections と channelSendrecvConnections に置き換えられました。")
    public var publisherCount: Int?

    /// 接続中のサブスクライバーの数
    @available(*, deprecated, message: "このプロパティは channelRecvonlyConnections と channelSendrecvConnections に置き換えられました。")
    public var subscriberCount: Int?

    /// 接続中の送信専用接続の数
    public var channelSendonlyConnections: Int?

    /// 接続中の受信専用接続の数
    public var channelRecvonlyConnections: Int?

    /// 接続中の送受信可能接続の数
    public var channelSendrecvConnections: Int?

    /// スポットライト ID
    public var spotlightId: String?

    /// 固定の有無
    public var isFixed: Bool?

    /// ネットワークの不安定度
    public var unstableLevel: Int?

    /// TURN が利用しているトランスポート層のプロトコル
    public var turnTransportType: String?
}

/**
 "notify" シグナリングメッセージのうち、次のイベントを表します。

 - `connection.created`
 - `connection.updated`
 - `connection.destroyed`

 このメッセージは接続の確立後、チャネルへの接続数に変更があるとサーバーから送信されます。
 廃止されました。
 SignalingNotify を利用してください。
 */
@available(*, unavailable, message: "SignalingNotifyConnection は廃止されました。  SignalingNotify を利用してください。")
public struct SignalingNotifyConnection {}

/**
 "notify" シグナリングメッセージのうち、 `spotlight.changed` イベントを表します。
 廃止されました。
 SignalingNotify を利用してください。
 */
@available(*, unavailable, message: "SignalingNotifySpotlightChanged は廃止されました。 SignalingNotify を利用してください。")
public struct SignalingNotifySpotlightChanged {}

/**
 "notify" シグナリングメッセージのうち、 "network.status" イベントを表します。
 廃止されました。
 SignalingNotify を利用してください。
 */
@available(*, unavailable, message: "SignalingNotifyNetworkStatus は廃止されました。 SignalingNotify を利用してください。")
public struct SignalingNotifyNetworkStatus {}

/**
 "ping" シグナリングメッセージを表します。
 このメッセージはサーバーから送信されます。
 "ping" 受信後は一定時間内に "pong" を返さなければ、
 サーバーとの接続が解除されます。
 */
public struct SignalingPing {
    /// :nodoc:
    public var statisticsEnabled: Bool?
}

/**
 "pong" シグナリングメッセージを表します。
 このメッセージはサーバーから "ping" シグナリングメッセージを受信すると
 サーバーに送信されます。
 "ping" 受信後、一定時間内にこのメッセージを返さなければ、
 サーバーとの接続が解除されます。
 */
public struct SignalingPong {}

/**
 "disconnect" シグナリングメッセージを表します。
 */
public struct SignalingDisconnect {
    /// Sora との接続を切断する理由
    public var reason: String?
}

// MARK: -

// MARK: Codable

/// :nodoc:
extension Signaling: Codable {
    enum MessageType: String {
        case connect
        case offer
        case answer
        case update
        case reAnswer
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
            self = .notify(try SignalingNotify(from: decoder))
        case "ping":
            self = .ping(try SignalingPing(from: decoder))
        case "push":
            self = .push(try SignalingPush(from: decoder))
        case "re-offer":
            self = .reOffer(try SignalingReOffer(from: decoder))
        case "switched":
            self = .switched(try SignalingSwitched(from: decoder))
        case "redirect":
            self = .redirect(try SignalingRedirect(from: decoder))
        default:
            throw SoraError.unknownSignalingMessageType(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .connect(message):
            try container.encode(MessageType.connect.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case let .offer(message):
            try container.encode(MessageType.offer.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case let .answer(message):
            try container.encode(MessageType.answer.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case let .candidate(message):
            try container.encode(MessageType.candidate.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case let .update(message):
            try container.encode(MessageType.update.rawValue, forKey: .type)
            try message.encode(to: encoder)
        case let .reAnswer(message):
            try container.encode(typeName(), forKey: .type)
            try message.encode(to: encoder)
        case .pong:
            try container.encode(MessageType.pong.rawValue, forKey: .type)
        case let .disconnect(message):
            try container.encode(MessageType.disconnect.rawValue, forKey: .type)
            try message.encode(to: encoder)
        default:
            throw SoraError.invalidSignalingMessage
        }
    }
}

private var simulcastRidTable: PairTable<String, SimulcastRid> =
    PairTable(name: "simulcastRid",
              pairs: [("r0", .r0),
                      ("r1", .r1),
                      ("r2", .r2)])

/// :nodoc:
extension SimulcastRid: Codable {
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }

    public func encode(to encoder: Encoder) throws {
        try simulcastRidTable.encode(self, to: encoder)
    }
}

private var spotlightRidTable: PairTable<String, SpotlightRid> =
    PairTable(name: "spotlightRid",
              pairs: [("unspecified", .unspecified),
                      ("none", .none),
                      ("r0", .r0),
                      ("r1", .r1),
                      ("r2", .r2)])

/// :nodoc:
extension SpotlightRid: Codable {
    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }

    public func encode(to encoder: Encoder) throws {
        try spotlightRidTable.encode(self, to: encoder)
    }
}

/// :nodoc:
private var roleTable: PairTable<String, SignalingRole> =
    PairTable(name: "SignalingRole",
              pairs: [("upstream", .upstream),
                      ("downstream", .downstream),
                      ("sendonly", .sendonly),
                      ("recvonly", .recvonly),
                      ("sendrecv", .sendrecv)])

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
        case client_id
        case metadata
        case signaling_notify_metadata
        case sdp
        case multistream
        case spotlight
        case spotlight_number
        case spotlight_focus_rid
        case spotlight_unfocus_rid
        case simulcast
        case simulcast_rid
        case video
        case audio
        case sora_client
        case libwebrtc
        case environment
        case data_channel_signaling
        case ignore_disconnect_websocket
        case data_channels
        case redirect
    }

    enum VideoCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
    }

    enum AudioCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
    }

    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(channelId, forKey: .channel_id)
        try container.encodeIfPresent(clientId, forKey: .client_id)
        try container.encodeIfPresent(sdp, forKey: .sdp)
        let metadataEnc = container.superEncoder(forKey: .metadata)
        try metadata?.encode(to: metadataEnc)
        let notifyEnc = container.superEncoder(forKey: .signaling_notify_metadata)
        try notifyMetadata?.encode(to: notifyEnc)
        try container.encodeIfPresent(multistreamEnabled,
                                      forKey: .multistream)
        try container.encodeIfPresent(soraClient, forKey: .sora_client)
        try container.encodeIfPresent(webRTCVersion, forKey: .libwebrtc)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encodeIfPresent(dataChannelSignaling, forKey: .data_channel_signaling)
        try container.encodeIfPresent(ignoreDisconnectWebSocket, forKey: .ignore_disconnect_websocket)
        try container.encodeIfPresent(redirect, forKey: .redirect)

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
            try container.encode(true, forKey: .simulcast)
            switch role {
            case .downstream, .sendrecv, .recvonly:
                try container.encodeIfPresent(simulcastRid, forKey: .simulcast_rid)
            default:
                break
            }
        }

        switch spotlightEnabled {
        case .enabled:
            try container.encode(true, forKey: .spotlight)
            try container.encodeIfPresent(spotlightNumber, forKey: .spotlight_number)
            if spotlightFocusRid != .unspecified {
                try container.encode(spotlightFocusRid, forKey: .spotlight_focus_rid)
            }
            if spotlightUnfocusRid != .unspecified {
                try container.encode(spotlightUnfocusRid, forKey: .spotlight_unfocus_rid)
            }
        case .disabled:
            break
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
        case active
        case maxBitrate
        case maxFramerate
        case scaleResolutionDownBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rid = try container.decodeIfPresent(String.self, forKey: .rid)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
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
extension SignalingReOffer: Codable {
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
extension SignalingReAnswer: Codable {
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
    public init(from decoder: Decoder) throws {}

    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
}

/// :nodoc:
extension SignalingNotify: Codable {
    enum CodingKeys: String, CodingKey {
        case event_type
        case role
        case client_id
        case connection_id
        case audio
        case video
        case minutes
        case channel_connections
        case channel_upstream_connections
        case channel_downstream_connections
        case channel_sendonly_connections
        case channel_recvonly_connections
        case channel_sendrecv_connections
        case spotlight_id
        case fixed
        case unstable_level
        case turn_transport_type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self,
                                         forKey: .event_type)
        role = try container.decodeIfPresent(SignalingRole.self, forKey: .role)
        clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
        connectionId = try container.decodeIfPresent(String.self,
                                                     forKey: .connection_id)
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audio)
        videoEnabled = try container.decodeIfPresent(Bool.self, forKey: .video)
        connectionTime = try container.decodeIfPresent(Int.self, forKey: .minutes)
        connectionCount =
            try container.decodeIfPresent(Int.self, forKey: .channel_connections)
        publisherCount =
            try container.decodeIfPresent(Int.self, forKey: .channel_upstream_connections)
        subscriberCount =
            try container.decodeIfPresent(Int.self, forKey: .channel_downstream_connections)
        channelSendonlyConnections =
            try container.decodeIfPresent(Int.self, forKey: .channel_sendonly_connections)
        channelRecvonlyConnections =
            try container.decodeIfPresent(Int.self, forKey: .channel_recvonly_connections)
        channelSendrecvConnections =
            try container.decodeIfPresent(Int.self, forKey: .channel_sendrecv_connections)
        spotlightId =
            try container.decodeIfPresent(String.self, forKey: .spotlight_id)
        isFixed =
            try container.decodeIfPresent(Bool.self, forKey: .fixed)
        unstableLevel =
            try container.decodeIfPresent(Int.self, forKey: .unstable_level)
        turnTransportType =
            try container.decodeIfPresent(String.self, forKey: .turn_transport_type)
    }

    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
}

/// :nodoc:
extension SignalingPing: Codable {
    enum CodingKeys: String, CodingKey {
        case stats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statisticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .stats)
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

/// :nodoc:
extension SignalingDisconnect: Codable {
    enum CodingKeys: String, CodingKey {
        case reason
    }

    public init(from decoder: Decoder) throws {
        throw SoraError.invalidSignalingMessage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
    }
}

extension SignalingSwitched: Decodable {
    enum CodingKeys: String, CodingKey {
        case ignore_disconnect_websocket
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ignoreDisconnectWebSocket = try container.decode(Bool.self, forKey: .ignore_disconnect_websocket)
    }
}

/// :nodoc:
extension SignalingRedirect: Decodable {
    enum CodingKeys: String, CodingKey {
        case location
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decode(String.self, forKey: .location)
    }
}
