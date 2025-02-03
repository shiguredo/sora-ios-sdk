import Foundation

/// WebSocket のステータスコードを表します。
public enum WebSocketStatusCode {
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

    /**
     初期化します。

     - parameter rawValue: ステータスコード
     */
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

    /**
     整数で表されるステータスコードを返します。

     - returns: ステータスコード
     */
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
        case let .other(value):
            return value
        }
    }
}

/// WebSocket の通信で送受信されるメッセージを表します。
public enum WebSocketMessage {
    /// テキスト
    case text(String)

    /// バイナリ
    case binary(Data)
}

/// WebSocket チャネルのイベントハンドラです。
public final class WebSocketChannelHandlers {
    /// 初期化します。
    public init() {}

    /// メッセージ受信時に呼ばれるクロージャー
    public var onReceive: ((WebSocketMessage) -> Void)?
}

final class WebSocketChannelInternalHandlers {
    public var onConnect: ((URLSessionWebSocketChannel) -> Void)?
    public var onDisconnectWithError: ((URLSessionWebSocketChannel, Error) -> Void)?
    public var onReceive: ((WebSocketMessage) -> Void)?
    public init() {}
}
