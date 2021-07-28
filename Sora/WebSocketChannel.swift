import Foundation
import Starscream

/**
 WebSocket のステータスコードを表します。
 */
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
        (.tlsHandshake, 1015)
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
        case .other(let value):
            return value
        }
    }
    
}

/**
 WebSocket の通信で送受信されるメッセージを表します。
 */
public enum WebSocketMessage {
    
    /// テキスト
    case text(String)
    
    /// バイナリ
    case binary(Data)
    
}

/**
 WebSocket チャネルのイベントハンドラです。
 */
public final class WebSocketChannelHandlers {
    
    /// このプロパティは onDisconnect に置き換えられました。
    @available(*, deprecated, renamed: "onDisconnect",
    message: "このプロパティは onDisconnect に置き換えられました。")
    public var onDisconnectHandler: ((Error?) -> Void)? {
        get { onDisconnect }
        set { onDisconnect = newValue }
    }
    
    /// このプロパティは onPong に置き換えられました。
    @available(*, deprecated, renamed: "onPong",
    message: "このプロパティは onPong に置き換えられました。")
    public var onPongHandler: ((Data?) -> Void)? {
        get { onPong }
        set { onPong = newValue }
    }
    
    /// このプロパティは onReceive に置き換えられました。
    @available(*, deprecated, renamed: "onReceive",
    message: "このプロパティは onReceive に置き換えられました。")
    public var onMessageHandler: ((WebSocketMessage) ->Void)? {
        get { onReceive }
        set { onReceive = newValue }
    }
    
    /// このプロパティは onDisconnect に置き換えられました。
    @available(*, deprecated, renamed: "onSend",
    message: "このプロパティは onSend に置き換えられました。")
    public var onSendHandler: ((WebSocketMessage) ->WebSocketMessage)? {
        get { onSend }
        set { onSend = newValue }
    }
    
    /// 接続解除時に呼ばれるクロージャー
    public var onDisconnect: ((Error?) -> Void)?
    
    /// pong の送信時に呼ばれるクロージャー
    public var onPong: ((Data?) -> Void)?
    
    /// メッセージ受信時に呼ばれるクロージャー
    public var onReceive: ((WebSocketMessage) ->Void)?
    
    /// メッセージ送信時に呼ばれるクロージャー
    public var onSend: ((WebSocketMessage) ->WebSocketMessage)?
    
    /// エラー発生時に呼ばれるクロージャー
    public var onError: ((Error?) -> Void)?

    /// 初期化します。
    public init() {}
    
}

/**
 WebSocket による通信を行うチャネルの機能を定義したプロトコルです。
 デフォルトの実装は非公開 (`internal`) であり、
 通信処理のカスタマイズはイベントハンドラでのみ可能です。
 ソースコードは公開していますので、実装の詳細はそちらを参照してください。
 
 WebSocket チャネルはシグナリングチャネル `SignalingChannel` により使用されます。
 */
public protocol WebSocketChannel: AnyObject {
    
    // MARK: - プロパティ
    
    /// サーバーの URL
    var url: URL { get }
    
    /// 接続状態
    var state: ConnectionState { get }
    
    /// イベントハンドラ
    var handlers: WebSocketChannelHandlers { get set }
    
    /**
     内部処理で使われるイベントハンドラ。
     このハンドラをカスタマイズに使うべきではありません。
     */
    var internalHandlers: WebSocketChannelHandlers { get set }

    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter url: サーバーの URL
     */
    init(url: URL)
    
    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter handler: 接続試行後に呼ばれるクロージャー
     - parameter error: (接続失敗時のみ) エラー
     */
    func connect(handler: @escaping (_ error: Error?) -> Void)
    
    /**
     接続を解除します。
     
     - parameter error: 接続解除の原因となったエラー
     */
    func disconnect(error: Error?)
    
    // MARK: メッセージの送信
    
    /**
     メッセージを送信します。
     
     - parameter message: 送信するメッセージ
     */
    func send(message: WebSocketMessage)
    
}

class BasicWebSocketChannel: WebSocketChannel {

    var url: URL
    var sslEnabled: Bool = true
    var handlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    var internalHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()

    var state: ConnectionState {
        get { return context.state }
    }

    var context: BasicWebSocketChannelContext!
    
    static var useStarscreamCustomEngine: Bool = true

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

class BasicWebSocketChannelContext: NSObject, WebSocketDelegate {
    
    func didReceive(event: WebSocketEvent, client socket: WebSocket) {
        switch event {
        case .connected(_):
            onOpen(socket: socket)
        case .disconnected(let reason, let code):
            let error = SoraError.webSocketClosed(statusCode: WebSocketStatusCode.init(rawValue: Int(code)),
                                                  reason: reason)
            onClose(socket: socket, error: error)
        case .text(let text):
            onMessage(socket: socket, text: text)
        case .binary(let data):
            onData(socket: socket, data: data)
        case .ping(_):
            break
        case .pong(let data):
            onPong(socket: socket, data: data)
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            break
        case .error(let error):
            channel.handlers.onError?(error)
        }
    }
    
    weak var channel: BasicWebSocketChannel!
    var nativeChannel: WebSocket
    
    var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .webSocketChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var onConnectHandler: ((Error?) -> Void)?

    init(channel: BasicWebSocketChannel) {
        self.channel = channel
        nativeChannel = WebSocket(request: URLRequest(url: channel.url),
                                  useCustomEngine: BasicWebSocketChannel.useStarscreamCustomEngine)
        super.init()
        nativeChannel.delegate = self
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        if channel.state.isConnecting {
            // TODO: onError と handler のどちらを利用すべきなのか? 両方?
            handler(SoraError.connectionBusy(reason:
                "WebSocketChannel is already connected"))
            return
        }
        
        Logger.debug(type: .webSocketChannel, message: "try connecting")
        state = .connecting
        onConnectHandler = handler
        nativeChannel.connect()
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .webSocketChannel, message: "try disconnecting")
            if error != nil {
                Logger.debug(type: .webSocketChannel,
                             message: "error: \(error!.localizedDescription)")
            }
            
            state = .disconnecting
            nativeChannel.disconnect()
            state = .disconnected
            
            Logger.debug(type: .webSocketChannel, message: "call onDisconnect")
            channel.internalHandlers.onDisconnect?(error)
            channel.handlers.onDisconnect?(error)
            
            if onConnectHandler != nil {
                Logger.debug(type: .webSocketChannel, message: "call connect(handler:)")
                onConnectHandler!(error)
                onConnectHandler = nil
            }
            
            Logger.debug(type: .webSocketChannel, message: "did disconnect")
        }
    }
    
    func send(message: WebSocketMessage) {
        var message = channel.internalHandlers.onSend?(message) ?? message
        message = channel.handlers.onSend?(message) ?? message
        switch message {
        case .text(let text):
            Logger.debug(type: .webSocketChannel, message: text)
            nativeChannel.write(string: text)
        case .binary(let data):
            Logger.debug(type: .webSocketChannel, message: "\(data)")
            nativeChannel.write(data: data)
        }
    }
    
    func callMessageHandler(message: WebSocketMessage) {
        Logger.debug(type: .webSocketChannel, message: "call onMessage")
        channel.internalHandlers.onReceive?(message)
        channel.handlers.onReceive?(message)
    }
    
    private func onOpen(socket: WebSocketClient) {
        Logger.debug(type: .webSocketChannel, message: "connected")
        state = .connected
        if onConnectHandler != nil {
            Logger.debug(type: .webSocketChannel, message: "call connect(handler:)")
            onConnectHandler!(nil)
            onConnectHandler = nil
        }
    }
    
    private func onClose(socket: WebSocketClient, error: Error?) {
        if let error = error {
            Logger.error(type: .webSocketChannel,
                         message: "disconnected => (\(error.localizedDescription))")
            disconnect(error: SoraError.webSocketError(error))
        } else {
            Logger.error(type: .webSocketChannel,
                         message: "disconnected")
            disconnect(error: nil)
        }
    }
    
    private func onMessage(socket: WebSocketClient, text: String) {
        Logger.debug(type: .webSocketChannel, message: "receive text message => \(text)")
        callMessageHandler(message: .text(text))
    }
    
    private func onData(socket: WebSocketClient, data: Data) {
        Logger.debug(type: .webSocketChannel, message: "receive binary message => \(data)")
        callMessageHandler(message: .binary(data))
    }

    private func onPong(socket: WebSocketClient, data: Data?) {
        Logger.debug(type: .webSocketChannel,
                     message: "receive poing payload => \(data?.description ?? "empty")")
        Logger.debug(type: .webSocketChannel, message: "call onPong")
        channel.internalHandlers.onPong?(data)
        channel.handlers.onPong?(data)
    }

}
