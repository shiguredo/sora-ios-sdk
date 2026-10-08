import AVFoundation
import Foundation

/// 購読 API が配送するイベントの種別です。
///
/// `enum` ではなく `RawRepresentable` な struct にしています。SDK が将来イベント種別を追加した
/// ときに、利用者が書いた網羅 `switch` が compile error にならないようにするためです (`enum` に
/// case を追加すると、網羅 `switch` を書いている利用者の既存コードが build できなくなります)。
/// 種別の判定は `event.kind == .disconnected` か、`default` を伴う `switch` で行います。
public struct SoraEventKind: RawRepresentable, Hashable, Sendable {
  /// 種別の識別子です。
  public let rawValue: String

  /// 識別子から種別を生成します。
  ///
  /// - parameter rawValue: 種別の識別子
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  // MARK: - 接続ライフサイクル

  /// 接続が確立した
  public static let connected = SoraEventKind(rawValue: "connected")

  /// 接続が失敗した
  public static let connectFailed = SoraEventKind(rawValue: "connectFailed")

  /// 接続が切断された
  public static let disconnected = SoraEventKind(rawValue: "disconnected")

  // MARK: - Sora インスタンス

  /// `Sora` の管理対象へメディアチャネルが追加された
  public static let mediaChannelAdded = SoraEventKind(rawValue: "mediaChannelAdded")

  /// `Sora` の管理対象からメディアチャネルが除去された
  public static let mediaChannelRemoved = SoraEventKind(rawValue: "mediaChannelRemoved")

  /// 音声入出力ルートが変更された
  public static let audioRouteChanged = SoraEventKind(rawValue: "audioRouteChanged")

  // MARK: - ストリーム

  /// ストリームが追加された
  public static let streamAdded = SoraEventKind(rawValue: "streamAdded")

  /// ストリームが除去された
  public static let streamRemoved = SoraEventKind(rawValue: "streamRemoved")

  /// 映像の有効フラグが変更された
  public static let videoEnabledChanged = SoraEventKind(rawValue: "videoEnabledChanged")

  /// 音声の有効フラグが変更された
  public static let audioEnabledChanged = SoraEventKind(rawValue: "audioEnabledChanged")

  // MARK: - シグナリングと DataChannel

  /// シグナリングの JSON 文字列を受信した
  public static let signalingReceivedJSON = SoraEventKind(rawValue: "signalingReceivedJSON")

  /// DataChannel が開いた
  public static let dataChannelOpened = SoraEventKind(rawValue: "dataChannelOpened")

  /// メッセージング用 DataChannel がすべて開いた
  public static let dataChannelAvailable = SoraEventKind(rawValue: "dataChannelAvailable")

  /// DataChannel のメッセージを受信した
  public static let dataChannelMessage = SoraEventKind(rawValue: "dataChannelMessage")
}

/// `Error` を actor / Task 境界へ渡せるようにした snapshot です。
///
/// `Error` の実体は `Sendable` であることを保証できないため、購読 API はエラーをこの値へ写して
/// 配送します。元の `Error` は保持しません。
///
/// `domain` と `code` は `Error` から `NSError` へのブリッジで得ます。`domain` はエラー型名、
/// `code` は `enum` の case の宣言順に依存するため、バージョン間で安定した識別子にはなりません。
/// `message` は `localizedDescription` のため locale に依存します。
public struct SoraEventError: Sendable, Equatable {
  /// エラーのドメイン
  public let domain: String

  /// エラーコード
  public let code: Int

  /// エラーの説明
  public let message: String

  /// 任意の `Error` から snapshot を作ります。
  ///
  /// - parameter error: 元のエラー
  init(_ error: Error) {
    let error = error as NSError
    self.domain = error.domain
    self.code = error.code
    self.message = error.localizedDescription
  }

  /// 値から snapshot を作ります。
  ///
  /// SDK が生成する値と同じ形の値をテストから作るための init です。利用者が `SoraEvent` を
  /// 組み立てることはできないため公開しません。
  ///
  /// - parameter domain: エラーのドメイン
  /// - parameter code: エラーコード
  /// - parameter message: エラーの説明
  init(domain: String, code: Int, message: String) {
    self.domain = domain
    self.code = code
    self.message = message
  }
}

/// 音声入出力ポートの snapshot です。
///
/// AVFoundation の class をイベントへ直接載せないために、ポートの値を snapshot に写します。
public struct SoraAudioPortSnapshot: Sendable, Equatable {
  /// ポート名
  public let name: String

  /// ポート種別 (`AVAudioSession.Port` の raw value)
  public let portType: String

  /// ポートの一意な識別子
  public let uid: String

  /// チャンネル数
  public let channelCount: Int

  /// データソースを持つ場合は `true`
  public let hasDataSource: Bool

  init(_ port: AVAudioSessionPortDescription) {
    self.name = port.portName
    self.portType = port.portType.rawValue
    self.uid = port.uid
    self.channelCount = port.channels?.count ?? 0
    self.hasDataSource = (port.dataSources?.isEmpty == false)
  }

  /// 値から snapshot を作ります。
  ///
  /// SDK が生成する値と同じ形の値をテストから作るための init です。
  init(
    name: String,
    portType: String,
    uid: String,
    channelCount: Int,
    hasDataSource: Bool
  ) {
    self.name = name
    self.portType = portType
    self.uid = uid
    self.channelCount = channelCount
    self.hasDataSource = hasDataSource
  }
}

/// 音声入出力ルートの snapshot です。
///
/// AVFoundation の class をイベントへ直接載せないために、入出力ポートの snapshot を持ちます。
public struct SoraAudioRouteSnapshot: Sendable, Equatable {
  /// 入力ポート
  public let inputs: [SoraAudioPortSnapshot]

  /// 出力ポート
  public let outputs: [SoraAudioPortSnapshot]

  init(_ route: AVAudioSessionRouteDescription) {
    self.inputs = route.inputs.map(SoraAudioPortSnapshot.init)
    self.outputs = route.outputs.map(SoraAudioPortSnapshot.init)
  }

  /// 値から snapshot を作ります。
  ///
  /// SDK が生成する値と同じ形の値をテストから作るための init です。
  init(inputs: [SoraAudioPortSnapshot], outputs: [SoraAudioPortSnapshot]) {
    self.inputs = inputs
    self.outputs = outputs
  }
}

/// 音声入出力ルートの変更イベントの payload です。
public struct SoraAudioRouteEvent: Sendable, Equatable {
  /// 変更理由
  public let reason: AVAudioSession.RouteChangeReason

  /// 変更前のルート
  public let previousRoute: SoraAudioRouteSnapshot

  init(reason: AVAudioSession.RouteChangeReason, previousRoute: AVAudioSessionRouteDescription) {
    self.reason = reason
    self.previousRoute = SoraAudioRouteSnapshot(previousRoute)
  }

  /// 値から payload を作ります。
  ///
  /// SDK が生成する値と同じ形の値をテストから作るための init です。
  init(reason: AVAudioSession.RouteChangeReason, previousRoute: SoraAudioRouteSnapshot) {
    self.reason = reason
    self.previousRoute = previousRoute
  }
}

/// 購読 API が配送するイベントです。
///
/// 種別 (`kind`) ごとに、該当する property だけが設定されます。`connected` /
/// `connectFailed` / `disconnected` は `Sora` の購読と `MediaChannel` の購読の両方で配送されるため、
/// 配送元によって payload が異なります。
///
/// | 種別 | 配送元 | 設定される payload |
/// | --- | --- | --- |
/// | `.connected` | `Sora` / `MediaChannel` | `connectionId`、`transportEpoch` |
/// | `.connectFailed` | `Sora` (設定エラー) | `error` |
/// | `.connectFailed` | `Sora` / `MediaChannel` | `connectionId`、`transportEpoch`、`error` |
/// | `.disconnected` | `Sora` | `connectionId`、`transportEpoch`、`error` (エラーを伴う切断のみ) |
/// | `.disconnected` | `MediaChannel` | `connectionId`、`transportEpoch`、`closeEvent` |
/// | `.mediaChannelAdded` | `Sora` | `transportEpoch` (`connectionId` は接続前のため常に `nil`) |
/// | `.mediaChannelRemoved` | `Sora` | `connectionId`、`transportEpoch` |
/// | `.audioRouteChanged` | `Sora` | `audioRoute` |
/// | `.streamAdded` / `.streamRemoved` | `MediaChannel` | `connectionId`、`transportEpoch`、`streamId` |
/// | `.videoEnabledChanged` / `.audioEnabledChanged` | `MediaChannel` | `connectionId`、`transportEpoch`、`streamId`、`isEnabled` |
/// | `.signalingReceivedJSON` | `MediaChannel` | `connectionId` (offer の処理前は `nil`)、`transportEpoch`、`signalingJSON` |
/// | `.dataChannelOpened` | `MediaChannel` | `connectionId`、`transportEpoch`、`dataChannelLabel` |
/// | `.dataChannelAvailable` | `MediaChannel` | `connectionId`、`transportEpoch` |
/// | `.dataChannelMessage` | `MediaChannel` | `connectionId`、`transportEpoch`、`dataChannelLabel`、`dataChannelMessage` |
///
/// 接続 ID は offer を処理した時点で確定するため、offer の処理前に終端した接続のイベント
/// (`.connectFailed` / `.disconnected` / `.mediaChannelRemoved`) は `connectionId` が `nil` に
/// なります。`.transportEpoch` は接続に紐づかないイベント (`.audioRouteChanged` と、設定エラーの
/// `.connectFailed`) で `nil` になります。
///
/// payload には mutable な `MediaChannel` / `MediaStream` / raw WebRTC object を含めません。
/// すべて値として確定するため、配送後も購読者が保持できます (元の object の寿命に依存しません)。
public struct SoraEvent: Sendable {
  /// イベントの種別
  public let kind: SoraEventKind

  /// イベントが属する接続の ID
  ///
  /// 接続に紐づかないイベント (`.audioRouteChanged` と、設定エラーの `.connectFailed`) と、接続 ID が
  /// 確定する前のイベント (`.mediaChannelAdded`、offer を処理する前の `.signalingReceivedJSON`) では
  /// `nil` になります。
  public let connectionId: String?

  /// redirect を跨いだ接続の世代
  ///
  /// 接続 (`MediaChannel`) ごとの値で、接続の開始時は 0 です。redirect を受信するたびに増えるため、
  /// 通常は 0 (redirect なし) か 1 (redirect あり) になります (増加の上限は保証しないため、判定は
  /// 「0 か、1 以上か」で行ってください)。同じ接続のイベント列で古い世代のイベント (stale event) を
  /// 識別するために使います (別の接続の世代とは比較できません)。
  /// 接続に紐づかないイベント (`.audioRouteChanged` と、設定エラーの `.connectFailed`) では `nil` です。
  public let transportEpoch: Int?

  /// 配送元ごとの通し番号
  ///
  /// 接続 (`MediaChannel`) または `Sora` インスタンスごとの単調増加の値です。購読を開始する前に
  /// 配送されたイベントにも採番されるため、購読者が最初に観測する値は 1 とは限りません。
  /// 購読者は、値の飛びでイベントの欠落 (buffer の drop) を検出できます。
  /// 複数のスレッドから同時に配送されたイベントでは、buffer に入る順序と通し番号の順序が
  /// 一致しないことがあります。
  public private(set) var sequence: UInt64

  /// エラーの snapshot
  ///
  /// `.connectFailed` と、`Sora` の `.disconnected` のうちエラーを伴う切断で `nil` 以外に
  /// なります。`disconnect(error: nil)` による通常の切断では `nil` です。
  public let error: SoraEventError?

  /// 切断イベントの snapshot
  ///
  /// `MediaChannel` の `.disconnected` だけが保持します (`Sora` の `.disconnected` は
  /// `closeEvent` を持たず、エラーは `error` で渡されます)。
  public let closeEvent: SoraCloseEvent?

  /// ストリーム ID
  public let streamId: String?

  /// 映像または音声の有効フラグ
  public let isEnabled: Bool?

  /// 受信したシグナリングの JSON 文字列
  ///
  /// offer を処理する前に配送されるため、そのイベントの `connectionId` は `nil` になります。
  public let signalingJSON: String?

  /// DataChannel のラベル
  public let dataChannelLabel: String?

  /// DataChannel で受信したメッセージ
  ///
  /// 受信したデータをそのまま保持します。既定の buffer (256 件) をすべて大きなメッセージで
  /// 埋めると、購読者ごとにその分のメモリを保持します。高頻度で大きなメッセージを受信する場合は
  /// `subscribeEvents(bufferingPolicy:)` で buffer を小さくしてください。
  public let dataChannelMessage: Data?

  /// 音声入出力ルートの変更 payload
  public let audioRoute: SoraAudioRouteEvent?

  /// 購読 API の buffer の既定件数です。
  ///
  /// あふれた場合は最も古いイベントが破棄されます。
  public static let defaultBufferSize = 256

  /// 通し番号を差し替えたイベントを返します。
  ///
  /// 通し番号の採番は購読者を管理する storage だけが行います。setter を非公開にして、利用者が
  /// 任意の値を入れられないようにしています。
  ///
  /// - parameter sequence: 差し替える通し番号
  /// - returns: 通し番号を差し替えたイベント
  func assigningSequence(_ sequence: UInt64) -> SoraEvent {
    var event = self
    event.sequence = sequence
    return event
  }

  init(
    kind: SoraEventKind,
    connectionId: String? = nil,
    transportEpoch: Int? = nil,
    error: SoraEventError? = nil,
    closeEvent: SoraCloseEvent? = nil,
    streamId: String? = nil,
    isEnabled: Bool? = nil,
    signalingJSON: String? = nil,
    dataChannelLabel: String? = nil,
    dataChannelMessage: Data? = nil,
    audioRoute: SoraAudioRouteEvent? = nil
  ) {
    self.kind = kind
    self.connectionId = connectionId
    self.transportEpoch = transportEpoch
    self.sequence = 0
    self.error = error
    self.closeEvent = closeEvent
    self.streamId = streamId
    self.isEnabled = isEnabled
    self.signalingJSON = signalingJSON
    self.dataChannelLabel = dataChannelLabel
    self.dataChannelMessage = dataChannelMessage
    self.audioRoute = audioRoute
  }
}
