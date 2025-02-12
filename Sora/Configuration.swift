import Foundation
import WebRTC

// MARK: デフォルト値

private let defaultPublisherStreamId: String = "mainStream"
private let defaultPublisherVideoTrackId: String = "mainVideo"
private let defaultPublisherAudioTrackId: String = "mainAudio"

/// プロキシに関する設定です
public struct Proxy: CustomStringConvertible {
  /// プロキシのホスト
  let host: String

  /// ポート
  let port: Int

  /// username
  /// プロキシに認証がかかっている場合に指定する
  let username: String?

  /// password
  /// プロキシに認証がかかっている場合に指定する
  let password: String?

  /// エージェント
  var agent: String = "Sora iOS SDK \(SDKInfo.version)"

  /**
     初期化します。
     - parameter host: プロキシのホスト名
     - parameter port: プロキシのポート
     - parameter agent: プロキシのエージェント
     - parameter username: プロキシ認証に使用するユーザー名
     - parameter password: プロキシ認証に使用するパスワード
     */
  public init(
    host: String, port: Int, agent: String? = nil, username: String? = nil,
    password: String? = nil
  ) {
    self.host = host
    self.port = port

    self.username = username
    self.password = password

    if let agent {
      self.agent = agent
    }
  }

  /// 文字列表現を返します。
  public var description: String {
    "host=\(host) port=\(port) agent=\(agent) username=\(username ?? "") password=\(String(repeating: "*", count: password?.count ?? 0))"
  }
}

/// クライアントに関する設定です。
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

  /// シグナリングに利用する URL の候補
  public var urlCandidates: [URL]

  /// チャネル ID
  public var channelId: String

  /// クライアント ID
  public var clientId: String?

  /// バンドル ID
  public var bundleId: String?
  /// ロール
  public var role: Role

  /// マルチストリームの可否
  ///
  /// レガシーストリーム機能は 2025 年 6 月リリースの Sora にて廃止します
  /// そのため、multistreamEnabled の使用は非推奨です
  public var multistreamEnabled: Bool?

  /// :nodoc:
  var isMultistream: Bool {
    switch role {
    default:
      return multistreamEnabled ?? true
    }
  }

  /// :nodoc:
  var isSender: Bool {
    switch role {
    case .sendonly, .sendrecv:
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

  /// カメラの設定
  public var cameraSettings = CameraSettings.default

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
  public var spotlightNumber: Int?

  /// スポットライト機能でフォーカスした場合の映像の種類
  public var spotlightFocusRid: SpotlightRid = .unspecified

  /// スポットライト機能でフォーカスしていない場合の映像の種類
  public var spotlightUnfocusRid: SpotlightRid = .unspecified

  /// WebRTC に関する設定
  public var webRTCConfiguration = WebRTCConfiguration()

  /// `connect` シグナリングに含めるメタデータ
  public var signalingConnectMetadata: Encodable?

  /// `connect` シグナリングに含める通知用のメタデータ
  public var signalingConnectNotifyMetadata: Encodable?

  /// シグナリングにおける DataChannel の利用可否。
  /// `true` の場合、接続確立後のシグナリングを DataChannel 経由で行います。
  public var dataChannelSignaling: Bool?

  /// メッセージング機能で利用する DataChannel の設定
  public var dataChannels: Any?

  /// DataChannel 経由のシグナリングを利用している際に、 WebSocket が切断されても Sora との接続を継続するためのフラグ。
  /// 詳細: https://sora-doc.shiguredo.jp/DATA_CHANNEL_SIGNALING#07c227
  public var ignoreDisconnectWebSocket: Bool?

  /// 音声ストリーミング機能で利用する言語コード
  public var audioStreamingLanguageCode: String?

  /// プロキシに関する設定
  public var proxy: Proxy?

  /// 転送フィルターの設定
  ///
  /// この項目は 2025 年 12 月リリース予定の Sora にて廃止されます
  public var forwardingFilter: ForwardingFilter?

  /// リスト形式の転送フィルターの設定
  public var forwardingFilters: [ForwardingFilter]?

  /// VP9 向け映像コーデックパラメーター
  public var videoVp9Params: Encodable?

  /// AV1 向け映像コーデックパラメーター
  public var videoAv1Params: Encodable?

  /// H264 向け映像コーデックパラメーター
  public var videoH264Params: Encodable?

  // MARK: - イベントハンドラ

  /// WebSocket チャネルに関するイベントハンドラ
  public var webSocketChannelHandlers = WebSocketChannelHandlers()

  /// メディアチャネルに関するイベントハンドラ
  public var mediaChannelHandlers = MediaChannelHandlers()

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

  /**
     初期化します。

     - parameter url: サーバーの URL
     - parameter channelId: チャネル ID
     - parameter role: ロール
     - parameter multistreamEnabled: マルチストリームの可否(デフォルトは指定なし)
     */
  public init(
    url: URL,
    channelId: String,
    role: Role,
    multistreamEnabled: Bool? = nil
  ) {
    urlCandidates = [url]
    self.channelId = channelId
    self.role = role
    self.multistreamEnabled = multistreamEnabled
  }

  /**
     初期化します。
     - parameter urlCandidates: シグナリングに利用する URL の候補
     - parameter channelId: チャネル ID
     - parameter role: ロール
     - parameter multistreamEnabled: マルチストリームの可否(デフォルトは指定なし)
     */
  public init(
    urlCandidates: [URL],
    channelId: String,
    role: Role,
    multistreamEnabled: Bool? = nil
  ) {
    self.urlCandidates = urlCandidates
    self.channelId = channelId
    self.role = role
    self.multistreamEnabled = multistreamEnabled
  }
}

/// 転送フィルターのルールのフィールドの設定です。
public enum ForwardingFilterRuleField: String, Encodable {
  /// connection_id
  case connectionId = "connection_id"

  /// client_id
  case clientId = "client_id"

  /// kind
  case kind
}

/// 転送フィルターのルールの演算子の設定です。
public enum ForwardingFilterRuleOperator: String, Encodable {
  /// is_in
  case isIn = "is_in"

  /// is_not_in
  case isNotIn = "is_not_in"
}

/// 転送フィルターのルールの設定です。
public struct ForwardingFilterRule: Encodable {
  /// field
  public let field: ForwardingFilterRuleField

  /// operator
  public let `operator`: ForwardingFilterRuleOperator

  /// values
  public let values: [String]

  /**
     初期化します。

     - parameter field: field
     - parameter operator: operator
     - parameter values: values
     */
  public init(
    field: ForwardingFilterRuleField,
    operator: ForwardingFilterRuleOperator,
    values: [String]
  ) {
    self.field = field
    self.operator = `operator`
    self.values = values
  }
}

/// 転送フィルターのアクションの設定です。
public enum ForwardingFilterAction: String, Encodable {
  /// block
  case block

  /// allow
  case allow
}

/// 転送フィルターに関する設定です。
public struct ForwardingFilter {
  /// name
  public var name: String?

  /// priority
  public var priority: Int?

  /// action
  public var action: ForwardingFilterAction?

  /// rules
  public var rules: [[ForwardingFilterRule]]

  /// version
  public var version: String?

  /// metadata
  public var metadata: Encodable?

  /**
     初期化します。

     - parameter action: action (オプショナル)
     - parameter rules: rules
     - parameter version: version (オプショナル)
     - parameter metadata: metadata (オプショナル)
     */
  public init(
    name: String? = nil, priority: Int? = nil, action: ForwardingFilterAction? = nil,
    rules: [[ForwardingFilterRule]], version: String? = nil, metadata: Encodable? = nil
  ) {
    self.name = name
    self.priority = priority
    self.action = action
    self.rules = rules
    self.version = version
    self.metadata = metadata
  }
}

extension ForwardingFilter: Encodable {
  enum CodingKeys: String, CodingKey {
    case name
    case priority
    case action
    case rules
    case version
    case metadata
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(priority, forKey: .priority)
    try container.encodeIfPresent(action, forKey: .action)
    try container.encode(rules, forKey: .rules)
    try container.encodeIfPresent(version, forKey: .version)

    // この if をつけないと、常に "metadata": {} が含まれてしまう
    if metadata != nil {
      let metadataEnc = container.superEncoder(forKey: .metadata)
      try metadata?.encode(to: metadataEnc)
    }
  }
}
