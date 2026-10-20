import Foundation

/// WebSocket のステータスコードを表します。
public enum WebSocketStatusCode: Sendable {
  /// 1000
  case normal

  /// 1001
  case goingAway

  /// 1002
  case protocolError

  /// 1003
  case unhandledType

  /// 1005
  case noStatusReceived

  /// 1006
  case abnormal

  /// 1007
  case invalidUTF8

  /// 1008
  case policyViolated

  /// 1009
  case messageTooBig

  /// 1010
  case missingExtension

  /// 1011
  case internalError

  /// 1012
  case serviceRestart

  /// 1013
  case tryAgainLater

  /// 1015
  case tlsHandshake

  /// その他のコード
  case other(Int)

  static let table: [(WebSocketStatusCode, Int)] = [
    (.normal, 1000),
    (.goingAway, 1001),
    (.protocolError, 1002),
    (.unhandledType, 1003),
    (.noStatusReceived, 1005),
    (.abnormal, 1006),
    (.invalidUTF8, 1007),
    (.policyViolated, 1008),
    (.messageTooBig, 1009),
    (.missingExtension, 1010),
    (.internalError, 1011),
    (.serviceRestart, 1012),
    (.tryAgainLater, 1013),
    (.tlsHandshake, 1015),
  ]

  // MARK: - インスタンスの生成

  /// 初期化します。
  ///
  /// - parameter rawValue: ステータスコード
  public init(rawValue: Int) {
    for pair in WebSocketStatusCode.table {
      if pair.1 == rawValue {
        self = pair.0
        return
      }
    }
    self = .other(rawValue)
  }

  // MARK: 変換

  /// 整数で表されるステータスコードを返します。
  ///
  /// - returns: ステータスコード
  public func intValue() -> Int {
    switch self {
    case .normal:
      return 1000
    case .goingAway:
      return 1001
    case .protocolError:
      return 1002
    case .unhandledType:
      return 1003
    case .noStatusReceived:
      return 1005
    case .abnormal:
      return 1006
    case .invalidUTF8:
      return 1007
    case .policyViolated:
      return 1008
    case .messageTooBig:
      return 1009
    case .missingExtension:
      return 1010
    case .internalError:
      return 1011
    case .serviceRestart:
      return 1012
    case .tryAgainLater:
      return 1013
    case .tlsHandshake:
      return 1015
    case .other(let value):
      return value
    }
  }
}

/// WebSocket の通信で送受信されるメッセージを表します。
public enum WebSocketMessage: Sendable {
  /// テキスト
  case text(String)

  /// バイナリ
  case binary(Data)
}

/// WebSocket チャネルのイベントハンドラです。
///
/// イベントハンドラのプロパティの get / set は、プロパティごとの `HandlerStorage` が持つ `NSLock` で
/// 排他します。
/// 利用する任意の executor からの設定と、URLSession の delegate callback からの読み取りが並行しても
/// データ競合しません。配送側は lock を解放してから取得済みの closure を呼びます
/// (`HandlerStorage` の doc 参照)。
///
/// 呼び出し元のスレッドは保証されない。UI 更新や共有状態の変更は main queue / main actor へ
/// 束ねること。
///
/// 配送のたびにプロパティを読むため、接続の途中で設定を変更しても次の配送から反映される
/// (プロパティごとの storage が排他するのは読み書きだけであり、配送側は lock を解放してから
/// 取得済みの closure を呼ぶ)。
///
/// Swift 6 言語モードで `@MainActor` の文脈からハンドラーを設定する場合は、クロージャに
/// `@Sendable` を付けるか `nonisolated` な関数へ処理を分離して隔離を外す。payload は
/// `WebSocketMessage` (`Sendable`) のため、main actor へそのまま渡せる。
///
/// 新しい購読 API では、受信したシグナリングの JSON 文字列が `MediaChannel` の
/// `signalingReceivedJSON` として配送される。生の `WebSocketMessage` (binary を含む) を受け取る
/// 経路はこの handler だけであり、新しい購読 API の対象外である。
public final class WebSocketChannelHandlers {
  /// 初期化します。
  public init() {}

  /// メッセージ受信時に呼ばれるクロージャー
  public var onReceive: ((WebSocketMessage) -> Void)? {
    get { onReceiveStorage.current }
    set { onReceiveStorage.current = newValue }
  }

  // MARK: - closure を保持する lock 付き storage

  /// `onReceive` を `NSLock` で排他して保持する storage です。
  private let onReceiveStorage = HandlerStorage<((WebSocketMessage) -> Void)?>(nil)
}

final class WebSocketChannelInternalHandlers {
  public var onConnect: ((URLSessionWebSocketChannel) -> Void)?
  public var onDisconnectWithError: ((URLSessionWebSocketChannel, Error) -> Void)?
  public var onReceive: ((WebSocketMessage) -> Void)?
  public init() {}
}
