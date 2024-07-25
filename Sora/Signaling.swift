import Foundation
import WebRTC

/// :nodoc:
private func serializeData(_ data: Any?) -> [SignalingNotifyMetadata]? {
    guard let array = data as? [[String: Any]] else {
        Logger.info(type: .signaling,
                    message: "downcast failed in serializeData. data: \(String(describing: data))")
        return nil
    }

    let result = array.map { (dict: [String: Any]) -> SignalingNotifyMetadata in
        var signalingNotifyMetadata = SignalingNotifyMetadata()
        if let clinetId = dict["client_id"] as? String {
            signalingNotifyMetadata.clientId = clinetId
        }
        if let bundleId = dict["bundle_id"] as? String {
            signalingNotifyMetadata.bundleId = bundleId
        }
        if let connectionId = dict["connection_id"] as? String {
            signalingNotifyMetadata.connectionId = connectionId
        }

        if let authnMetadata = dict["authn_metadata"] {
            signalingNotifyMetadata.authnMetadata = authnMetadata
        }

        if let authzMetada = dict["authz_metadata"] {
            signalingNotifyMetadata.authzMetadata = authzMetada
        }

        if let metadata = dict["metadata"] {
            signalingNotifyMetadata.metadata = metadata
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
        if let metadata = json["metadata"] {
            message.metadata = metadata
        }
        if let dataChannels = json["data_channels"] as? [[String: Any]] {
            message.dataChannels = dataChannels
        }
        return .offer(message)
    case var .push(message):
        if let data = json["data"] {
            message.data = data
        }
        return .push(message)
    case var .notify(message):
        if let authnMetadata = json["authn_metadata"] {
            message.authnMetadata = authnMetadata
        }
        if let authzMetadata = json["authz_metadata"] {
            message.authzMetadata = authzMetadata
        }
        if let metadata = json["metadata"] {
            message.metadata = metadata
        }
        if let data = json["data"] {
            message.data = serializeData(data)
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
 シグナリングに含まれる、同チャネルに接続中のクライアントに関するメタデータ (任意のデータ) を表します。
 */
public struct SignalingNotifyMetadata {
    /// クライアント ID
    public var clientId: String?

    /// バンドル ID
    public var bundleId: String?

    /// 接続 ID
    public var connectionId: String?

    /// シグナリング接続時にクライアントが指定した値
    public var authnMetadata: Any?

    /// Sora の認証ウェブフックの戻り値で指定された値
    public var authzMetadata: Any?

    /// メタデータ
    public var metadata: Any?
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

    /// バンドル ID
    public var bundleId: String?

    /// メタデータ
    public var metadata: Encodable?

    /// notify メタデータ
    public var notifyMetadata: Encodable?

    /// SDP 。クライアントの判別に使われます。
    public var sdp: String?

    /// マルチストリームの可否
    @available(*, deprecated, message: "レガシーストリーム機能は 2025 年 6 月リリースの Sora にて廃止します。")
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

    /// 音声ストリーミング機能で利用する言語コード
    public var audioStreamingLanguageCode: String?

    /// type: redicret 受信後の再接続
    public var redirect: Bool?

    /// 転送フィルターの設定
    public var forwardingFilter: ForwardingFilter?

    /// VP9 向け映像コーデックパラメーター
    public var vp9Params: Encodable?

    /// AV1 向け映像コーデックパラメーター
    public var av1Params: Encodable?

    /// H264 向け映像コーデックパラメーター
    public var h264Params: Encodable?
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

        /// scalability mode
        public let scalabilityMode: String?

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
            params.scalabilityMode = scalabilityMode
            return params
        }
    }

    /// クライアント ID
    public let clientId: String

    /// バンドル ID
    public let bundleId: String?

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

    /// mid
    public let mid: [String: String]?

    /// サイマルキャスト有効 / 無効フラグ
    public let simulcast: Bool?
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
 "notify" シグナリングメッセージを表します。
 */
public struct SignalingNotify {
    // MARK: イベント情報

    /// イベントの種別
    public var eventType: String

    // MARK: 接続情報

    /// ロール
    public var role: SignalingRole?

    /// セッション ID
    public var sessionId: String?

    /// クライアント ID
    public var clientId: String?

    /// バンドル ID
    public var bundleId: String?

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
    public var data: [SignalingNotifyMetadata]?

    // MARK: 接続状態

    /// 接続時間 (分)
    public var connectionTime: Int?

    /// 接続中のクライアントの数
    public var connectionCount: Int?

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

    /// 転送フィルターで block または allow となった対象 (audio または video)
    public var kind: String?

    /// 転送フィルターで block または allow となった送信先の接続 ID
    public var destinationConnectionId: String?

    /// 転送フィルターで block または allow となった送信元の接続 ID
    public var sourceConnectionId: String?

    /// 停止された RTP ストリームの送信先接続 ID
    public var recvConnectionId: String?

    /// 停止された RTP ストリームの送信元接続 ID
    public var sendConnectionId: String?

    /// 再開された RTP ストリームの送信元接続 ID
    public var streamId: String?
}

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
            self = try .offer(SignalingOffer(from: decoder))
        case "update":
            self = try .update(SignalingUpdate(from: decoder))
        case "notify":
            self = try .notify(SignalingNotify(from: decoder))
        case "ping":
            self = try .ping(SignalingPing(from: decoder))
        case "push":
            self = try .push(SignalingPush(from: decoder))
        case "re-offer":
            self = try .reOffer(SignalingReOffer(from: decoder))
        case "switched":
            self = try .switched(SignalingSwitched(from: decoder))
        case "redirect":
            self = try .redirect(SignalingRedirect(from: decoder))
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
              pairs: [("sendonly", .sendonly),
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
        case bundle_id
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
        case audio_streaming_language_code
        case redirect
        case forwarding_filter
    }

    enum VideoCodingKeys: String, CodingKey {
        case codec_type
        case bit_rate
        case vp9_params
        case av1_params
        case h264_params
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
        try container.encodeIfPresent(bundleId, forKey: .bundle_id)
        try container.encodeIfPresent(sdp, forKey: .sdp)

        // try metadata?.encode(to: metadataEnc) で metadata が nil の時はエンコードが実行されないように実装しても、
        // container.superEncoder(forKey: .metadata) の呼び出し時点で子要素の準備までしてしまっているので
        // metadata が nil の場合でも、`"metadata": {}` になってしまう。
        // これを回避するために metadata が nil でない場合のみ、container.superEncoder(forKey: .metadata) を呼び出して
        // encode(to:) を実行するような実装にしている。
        if let metadata {
            let metadataEnc = container.superEncoder(forKey: .metadata)
            try metadata.encode(to: metadataEnc)
        }
        if let notifyMetadata {
            let notifyEnc = container.superEncoder(forKey: .signaling_notify_metadata)
            try notifyMetadata.encode(to: notifyEnc)
        }
        try container.encodeIfPresent(multistreamEnabled,
                                      forKey: .multistream)
        try container.encodeIfPresent(soraClient, forKey: .sora_client)
        try container.encodeIfPresent(webRTCVersion, forKey: .libwebrtc)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encodeIfPresent(dataChannelSignaling, forKey: .data_channel_signaling)
        try container.encodeIfPresent(ignoreDisconnectWebSocket, forKey: .ignore_disconnect_websocket)
        try container.encodeIfPresent(audioStreamingLanguageCode, forKey: .audio_streaming_language_code)
        try container.encodeIfPresent(redirect, forKey: .redirect)
        try container.encodeIfPresent(forwardingFilter, forKey: .forwarding_filter)

        if videoEnabled {
            if videoCodec != .default || videoBitRate != nil || vp9Params != nil || av1Params != nil || h264Params != nil {
                var videoContainer = container
                    .nestedContainer(keyedBy: VideoCodingKeys.self,
                                     forKey: .video)
                if videoCodec != .default {
                    try videoContainer.encode(videoCodec, forKey: .codec_type)
                }
                try videoContainer.encodeIfPresent(videoBitRate,
                                                   forKey: .bit_rate)
                if let vp9Params {
                    let vp9ParamsEnc = videoContainer.superEncoder(forKey: .vp9_params)
                    try vp9Params.encode(to: vp9ParamsEnc)
                }
                if let av1Params {
                    let av1ParamsEnc = videoContainer.superEncoder(forKey: .av1_params)
                    try av1Params.encode(to: av1ParamsEnc)
                }
                if let h264Params {
                    let h264ParamsEnc = videoContainer.superEncoder(forKey: .h264_params)
                    try h264Params.encode(to: h264ParamsEnc)
                }
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
            case .sendrecv, .recvonly:
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
        case scalabilityMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rid = try container.decodeIfPresent(String.self, forKey: .rid)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        maxBitrate = try container.decodeIfPresent(Int.self, forKey: .maxBitrate)
        maxFramerate = try container.decodeIfPresent(Double.self, forKey: .maxFramerate)
        scaleResolutionDownBy = try container.decodeIfPresent(Double.self,
                                                              forKey: .scaleResolutionDownBy)
        scalabilityMode = try container.decodeIfPresent(String.self,
                                                        forKey: .scalabilityMode)
    }

    public func encode(to encoder: Encoder) throws {
        throw SoraError.invalidSignalingMessage
    }
}

/// :nodoc:
extension SignalingOffer: Codable {
    enum CodingKeys: String, CodingKey {
        case client_id
        case bundle_id
        case connection_id
        case sdp
        case config
        case encodings
        case mid
        case simulcast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .client_id)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundle_id)
        connectionId = try container.decode(String.self, forKey: .connection_id)
        sdp = try container.decode(String.self, forKey: .sdp)
        configuration =
            try container.decodeIfPresent(Configuration.self,
                                          forKey: .config)
        encodings =
            try container.decodeIfPresent([Encoding].self,
                                          forKey: .encodings)
        mid = try container.decodeIfPresent([String: String].self, forKey: .mid)
        simulcast = try container.decodeIfPresent(Bool.self, forKey: .simulcast)
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
        case session_id
        case client_id
        case bundle_id
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
        case kind
        case destination_connection_id
        case source_connection_id
        case recv_connection_id
        case send_connection_id
        case stream_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self,
                                         forKey: .event_type)
        role = try container.decodeIfPresent(SignalingRole.self, forKey: .role)
        sessionId = try container.decodeIfPresent(String.self, forKey: .session_id)
        clientId = try container.decodeIfPresent(String.self, forKey: .client_id)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundle_id)
        connectionId = try container.decodeIfPresent(String.self,
                                                     forKey: .connection_id)
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audio)
        videoEnabled = try container.decodeIfPresent(Bool.self, forKey: .video)
        connectionTime = try container.decodeIfPresent(Int.self, forKey: .minutes)
        connectionCount =
            try container.decodeIfPresent(Int.self, forKey: .channel_connections)
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
        kind =
            try container.decodeIfPresent(String.self, forKey: .kind)
        destinationConnectionId =
            try container.decodeIfPresent(String.self, forKey: .destination_connection_id)
        sourceConnectionId =
            try container.decodeIfPresent(String.self, forKey: .source_connection_id)
        recvConnectionId =
            try container.decodeIfPresent(String.self, forKey: .recv_connection_id)
        sendConnectionId =
            try container.decodeIfPresent(String.self, forKey: .send_connection_id)
        streamId =
            try container.decodeIfPresent(String.self, forKey: .stream_id)
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
