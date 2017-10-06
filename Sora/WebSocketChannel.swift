import Foundation
import SocketRocket

public enum WebSocketStatusCode {
    
    case normal // 1000
    case goingAway // 1001
    case protocolError // 1002
    case unhandledType // 1003
    case noStatusReceived // 1005
    case abnormal // 1006
    case invalidUTF8 // 1007
    case policyViolated // 1008
    case messageTooBig // 1009
    case missingExtension // 1010
    case internalError // 1011
    case serviceRestart // 1012
    case tryAgainLater // 1013
    case tlsHandshake // 1015
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
        (.tlsHandshake, 1015)
    ]
    
    // MARK: - 初期化
    
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

public enum WebSocketChannelState {
    case connecting
    case connected
    case disconnecting
    case disconnected
}

public enum WebSocketMessage {
    case text(String)
    case binary(Data)
}

public class WebSocketChannelHandlers {
    
    public var onFailureHandler: ((Error) -> Void)?
    public var onPongHandler: ((Data) -> Void)?
    public var onMessageHandler: ((WebSocketMessage) ->Void)?
    
}

public protocol WebSocketChannel {
    
    // MARK: - プロパティ
    
    var url: URL { get }
    var state: WebSocketChannelState { get }
    var handlers: WebSocketChannelHandlers { get }
    
    // MARK: - 初期化
    
    init(url: URL)
    
    // MARK: - 接続
    
    func connect(handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    // MARK: メッセージの送信
    
    func send(message: WebSocketMessage)
    
}

class BasicWebSocketChannel: WebSocketChannel {

    var url: URL
    var sslEnabled: Bool = true
    var handlers: WebSocketChannelHandlers = WebSocketChannelHandlers()

    var state: WebSocketChannelState {
        get { return context.state }
    }

    var context: BasicWebSocketChannelContext!
    
    required init(url: URL) {
        self.url = url
        context = BasicWebSocketChannelContext(channel: self)
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        context.connect(handler: handler)
    }
    
    func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    func send(message: WebSocketMessage) {
        Logger.debug(type: .webSocketChannel, message: "send message")
        context.send(message: message)
    }

}

class BasicWebSocketChannelContext: NSObject, SRWebSocketDelegate {
    
    weak var channel: BasicWebSocketChannel!
    var nativeChannel: SRWebSocket
    
    var state: WebSocketChannelState = .disconnected {
        didSet {
            Logger.trace(type: .webSocketChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var onConnectHandler: ((Error?) -> Void)?

    init(channel: BasicWebSocketChannel) {
        self.channel = channel
        nativeChannel = SRWebSocket(url: channel.url)
        super.init()
        nativeChannel.delegate = self
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .webSocketChannel, message: "try connecting")
        state = .connecting
        onConnectHandler = handler
        nativeChannel.open()
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .webSocketChannel, message: "try disconnecting")
            state = .disconnecting
            nativeChannel.close()
            state = .disconnected
            if let error = error {
                Logger.debug(type: .webSocketChannel, message: "failure \(error)")
                channel.handlers.onFailureHandler?(error)
            }
            onConnectHandler?(error)
            onConnectHandler = nil
            Logger.debug(type: .webSocketChannel, message: "did disconnect")
        }
    }
    
    func send(message: WebSocketMessage) {
        var nativeMsg: Any!
        switch message {
        case .text(let text):
            Logger.debug(type: .webSocketChannel, message: text)
            nativeMsg = text
        case .binary(let data):
            Logger.debug(type: .webSocketChannel, message: "\(data)")
            nativeMsg = data
        }
        nativeChannel.send(nativeMsg)
    }
    
    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        Logger.debug(type: .webSocketChannel, message: "connected")
        state = .connected
        onConnectHandler?(nil)
        onConnectHandler = nil
    }
    
    func webSocket(_ webSocket: SRWebSocket!,
                   didCloseWithCode code: Int,
                   reason: String?,
                   wasClean: Bool) {
        Logger.debug(type: .webSocketChannel,
                  message: "closed with code \(code) \(reason ?? "")")
        if code != SRStatusCodeNormal.rawValue {
            let statusCode = WebSocketStatusCode(rawValue: code)
            let error = SoraError.webSocketError(error: nil,
                                                 statusCode: statusCode,
                                                 reason: reason)
            disconnect(error: error)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        Logger.debug(type: .webSocketChannel, message: "failed")
        disconnect(error: error)
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        Logger.debug(type: .webSocketChannel, message: "receive message")
        Logger.debug(type: .webSocketChannel, message: "\(message)")
        var newMessage: WebSocketMessage?
        if let text = message as? String {
            newMessage = .text(text)
        } else if let data = message as? Data {
            newMessage = .binary(data)
        }
        if let message = newMessage {
            channel.handlers.onMessageHandler?(message)
        } else {
            Logger.debug(type: .webSocketChannel,
                      message: "received message is not string or binary (discarded)")
            // discard
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceivePong pongPayload: Data!) {
        Logger.debug(type: .webSocketChannel, message: "receive poing payload")
        Logger.debug(type: .webSocketChannel, message: "\(pongPayload)")
        channel.handlers.onPongHandler?(pongPayload)
    }
    
    func webSocketShouldConvertTextFrame(toString webSocket: SRWebSocket!) -> Bool {
        return true
    }
    
}
