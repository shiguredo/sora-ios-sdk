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
    
    public init(rawValue: Int) {
        for pair in WebSocketStatusCode.table {
            if pair.1 == rawValue {
                self = pair.0
                return
            }
        }
        self = .other(rawValue)
    }
    
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
    
    public var onFailureHandler: Callback1<Error, Void> = Callback1(repeats: true)
    public var onPongHandler: Callback1<Data, Void> = Callback1(repeats: true)
    public var onMessageHandler: Callback1<WebSocketMessage, Void> = Callback1(repeats: true)
    
    public func onFailure(handler: @escaping (Error) -> Void) {
        onFailureHandler.onExecute(handler: handler)
    }
    
    public func onPong(handler: @escaping (Data) -> Void) {
        onPongHandler.onExecute(handler: handler)
    }
    
    public func onMessage(handler: @escaping (WebSocketMessage) ->Void) {
        onMessageHandler.onExecute(handler: handler)
    }
    
}

public protocol WebSocketChannel: AliveMonitorable {
    
    var url: URL { get }
    var state: WebSocketChannelState { get }
    var handlers: WebSocketChannelHandlers { get }
    
    init(url: URL)
    
    func connect(handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    func send(message: WebSocketMessage)
    

}

public class BasicWebSocketChannel: WebSocketChannel {

    public var url: URL
    public var sslEnabled: Bool = true
    public var handlers: WebSocketChannelHandlers = WebSocketChannelHandlers()

    public var state: WebSocketChannelState {
        get { return context.state }
    }
    
    public var aliveState: AliveState {
        get { return context.aliveState }
    }
    
    var context: BasicWebSocketChannelContext!
    
    public required init(url: URL) {
        self.url = url
        context = BasicWebSocketChannelContext(channel: self)
    }
    
    public func connect(handler: @escaping (Error?) -> Void) {
        context.connect(handler: handler)
    }
    
    public func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    public func send(message: WebSocketMessage) {
        Log.debug(type: .webSocketChannel, message: "send message")
        context.send(message: message)
    }

}

class BasicWebSocketChannelContext: NSObject, SRWebSocketDelegate, AliveMonitorable {
    
    weak var channel: BasicWebSocketChannel!
    var nativeChannel: SRWebSocket
    
    var state: WebSocketChannelState = .disconnected {
        didSet {
            Log.trace(type: .webSocketChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var aliveState: AliveState {
        get {
            switch state {
            case .connected:
                return .available
            case .connecting:
                return .connecting
            case .disconnecting, .disconnected:
                return .unavailable
            }
        }
    }
    
    var onConnectHandler: Callback1<Error?, Void> = Callback1(repeats: false)

    init(channel: BasicWebSocketChannel) {
        self.channel = channel
        nativeChannel = SRWebSocket(url: channel.url)
        super.init()
        nativeChannel.delegate = self
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        Log.debug(type: .webSocketChannel, message: "try connecting")
        state = .connecting
        onConnectHandler.onExecute(handler: handler)
        nativeChannel.open()
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Log.debug(type: .webSocketChannel, message: "try disconnecting")
            state = .disconnecting
            nativeChannel.close()
            state = .disconnected
            if let error = error {
                Log.debug(type: .webSocketChannel, message: "failure \(error)")
                channel.handlers.onFailureHandler.execute(error)
            }
            onConnectHandler.execute(error)
            Log.debug(type: .webSocketChannel, message: "did disconnect")
        }
    }
    
    func send(message: WebSocketMessage) {
        var nativeMsg: Any!
        switch message {
        case .text(let text):
            Log.debug(type: .webSocketChannel, message: text)
            nativeMsg = text
        case .binary(let data):
            Log.debug(type: .webSocketChannel, message: "\(data)")
            nativeMsg = data
        }
        nativeChannel.send(nativeMsg)
    }
    
    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        Log.debug(type: .webSocketChannel, message: "connected")
        state = .connected
        onConnectHandler.execute(nil)
    }
    
    func webSocket(_ webSocket: SRWebSocket!,
                   didCloseWithCode code: Int,
                   reason: String?,
                   wasClean: Bool) {
        Log.debug(type: .webSocketChannel,
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
        Log.debug(type: .webSocketChannel, message: "failed")
        disconnect(error: error)
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        Log.debug(type: .webSocketChannel, message: "receive message")
        Log.debug(type: .webSocketChannel, message: "\(message)")
        var newMessage: WebSocketMessage?
        if let text = message as? String {
            newMessage = .text(text)
        } else if let data = message as? Data {
            newMessage = .binary(data)
        }
        if let message = newMessage {
            channel.handlers.onMessageHandler.execute(message)
        } else {
            Log.debug(type: .webSocketChannel,
                      message: "received message is not string or binary (discarded)")
            // discard
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceivePong pongPayload: Data!) {
        Log.debug(type: .webSocketChannel, message: "receive poing payload")
        Log.debug(type: .webSocketChannel, message: "\(pongPayload)")
        channel.handlers.onPongHandler.execute(pongPayload)
    }
    
    func webSocketShouldConvertTextFrame(toString webSocket: SRWebSocket!) -> Bool {
        return true
    }
    
}
