import Foundation

/**
 ストリームの方向を表します。
 シグナリングメッセージで使われます。
 */
public enum SignalingRole: String {
    
    /// この列挙子は sendonly に置き換えられました。
    @available(*, deprecated, renamed: "sendonly",
    message: "この列挙子は sendonly に置き換えられました。")
    case upstream
    
    /// この列挙子は recvonly に置き換えられました。
    @available(*, deprecated, renamed: "recvonly",
    message: "この列挙子は recvonly に置き換えられました。")
    case downstream
    
    /// 送信のみ
    case sendonly
    
    /// 受信のみ
    case recvonly
    
    /// 送受信
    case sendrecv
    
}

/**
 シグナリングチャネルのイベントハンドラです。
 */
public final class SignalingChannelHandlers {

    /// このプロパティは onDisconnect に置き換えられました。
    @available(*, deprecated, renamed: "onDisconnect",
    message: "このプロパティは onDisconnect に置き換えられました。")
    public var onDisconnectHandler: ((Error?) -> Void)? {
           get { onDisconnect }
           set { onDisconnect = newValue }
       }
    
    /// このプロパティは onReceive に置き換えられました。
    @available(*, deprecated, renamed: "onReceive",
    message: "このプロパティは onReceive に置き換えられました。")
    public var onReceiveSignalingHandler: ((Signaling) -> Void)? {
           get { onReceive }
           set { onReceive = newValue }
       }

    /// このプロパティは onDisconnect に置き換えられました。
    @available(*, deprecated, renamed: "onSend",
    message: "このプロパティは onSend に置き換えられました。")
    public var onSendSignalingHandler: ((Signaling) -> Signaling)? {
           get { onSend }
           set { onSend = newValue }
       }
    
    /// 接続解除時に呼ばれるクロージャー
    public var onDisconnect: ((Error?) -> Void)?
    
    /// シグナリング受信時に呼ばれるクロージャー
    public var onReceive: ((Signaling) -> Void)?

    /// シグナリング送信時に呼ばれるクロージャー
    public var onSend: ((Signaling) -> Signaling)?
    
    /// 初期化します。
    public init() {}
    
}

/**
 シグナリングチャネルの機能を定義したプロトコルです。
 デフォルトの実装は非公開 (`internal`) であり、カスタマイズはイベントハンドラでのみ可能です。
 ソースコードは公開していますので、実装の詳細はそちらを参照してください。
 
 シグナリングチャネルとピアチャネル `PeerChannel` はそれぞれ独立してサーバーに接続され、両者は協調してメディアチャネル `MediaChannel` の接続を確立します。
 シグナリングチャネルの接続はメディアチャネルの接続後も維持され、
 メディアチャネルが接続を解除されるとシグナリングチャネルの接続も解除されます。
 また、メディアチャネルの接続中にシグナリングチャネルの接続が解除されると、
 メディアチャネルの接続も解除されます。
 
 シグナリングメッセージは WebSocket チャネル `WebSocketChannel` を使用してサーバーに送信されます。
 */
public protocol SignalingChannel: AnyObject {

    // MARK: - プロパティ
    
    /// クライアントの設定
    var configuration: Configuration { get }
    
    /// WebSocket チャネル
    var webSocketChannel: WebSocketChannel { get }
    
    /// 接続状態
    var state: ConnectionState { get }
    
    var ignoreDisconnectWebSocket: Bool { get set }
    // MARK: - イベントハンドラ
    
    /// イベントハンドラ
    var handlers: SignalingChannelHandlers { get set }
    
    /**
     内部処理で使われるイベントハンドラ。
     このハンドラをカスタマイズに使うべきではありません。
     */
    var internalHandlers: SignalingChannelHandlers { get set }

    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter configuration: クライアントの設定
     */
    init(configuration: Configuration)

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
     サーバーにシグナリングメッセージを送信します。
     
     - parameter message: シグナリングメッセージ
     */
    func send(message: Signaling)
    
    /**
     サーバーに任意のメッセージを送信します。
     Sora は仕様にないメッセージを受信すると WebSocket の接続を解除します。
     任意のメッセージを送信する際は注意してください。
     
     - parameter text: メッセージ
     */
    func send(text: String)
    
}

class BasicSignalingChannel: SignalingChannel {
    var handlers: SignalingChannelHandlers = SignalingChannelHandlers()
    var internalHandlers: SignalingChannelHandlers = SignalingChannelHandlers()
    var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
    var ignoreDisconnectWebSocket: Bool = false
    
    var configuration: Configuration
    
    var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .signalingChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var webSocketChannel: WebSocketChannel

    private var onConnectHandler: ((Error?) -> Void)?
    
    required init(configuration: Configuration) {
        self.configuration = configuration
        self.webSocketChannel = configuration
            ._webSocketChannelType.init(url: configuration.url)
        BasicWebSocketChannel.useStarscreamCustomEngine = !configuration.allowsURLSessionWebSocketChannel
        webSocketChannel.internalHandlers.onDisconnect = { [weak self] error in
            if let self = self {
                Logger.debug(type: .signalingChannel, message: "ignoreDisconnectWebSocket: \(self.ignoreDisconnectWebSocket)")
                // ignoreDisconnectWebSocket == true の場合は、 WebSocketChannel 切断時に SignalingChannel を切断しない
                if !self.ignoreDisconnectWebSocket {
                    self.disconnect(error: error)
                }
            }
        }
        
        webSocketChannel.internalHandlers.onReceive = { [weak self] message in
            self?.handle(message: message)
        }
        webSocketChannel.handlers = configuration.webSocketChannelHandlers
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        if state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "SignalingChannel is already connected"))
            return
        }
        
        Logger.debug(type: .signalingChannel, message: "try connecting")
        onConnectHandler = handler
        state = .connecting

        webSocketChannel.connect { error in
            if self.onConnectHandler != nil {
                Logger.debug(type: .signalingChannel, message: "call connect(handler:)")
                self.onConnectHandler!(error)
                self.onConnectHandler = nil
            }
            
            if let error = error {
                Logger.debug(type: .signalingChannel,
                          message: "connecting failed (\(error))")
                self.disconnect(error: error)
                return
            }
            Logger.debug(type: .signalingChannel, message: "connected")
            self.state = .connected
        }
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .signalingChannel, message: "try disconnecting")
            if let error = error {
                Logger.error(type: .signalingChannel,
                             message: "error: \(error.localizedDescription)")
            }
            
            state = .disconnecting
            webSocketChannel.disconnect(error: error)
            state = .disconnected
            
            Logger.debug(type: .signalingChannel, message: "call onDisconnect")
            self.internalHandlers.onDisconnect?(error)
            self.handlers.onDisconnect?(error)
            
            if self.onConnectHandler != nil {
                Logger.debug(type: .signalingChannel, message: "call connect(handler:)")
                self.onConnectHandler!(error)
                self.onConnectHandler = nil
            }

            Logger.debug(type: .signalingChannel, message: "did disconnect")
        }
    }
    
    func send(message: Signaling) {
        Logger.debug(type: .signalingChannel, message: "send message")
        var message = internalHandlers.onSend?(message) ?? message
        message = handlers.onSend?(message) ?? message
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(message)
            let str = String(data: data, encoding: .utf8)!
            Logger.debug(type: .signalingChannel, message: str)
            webSocketChannel.send(message: .text(str))
        } catch {
            Logger.debug(type: .signalingChannel,
                      message: "JSON encoding failed")
        }
    }
    
    func send(text: String) {
        webSocketChannel.send(message: .text(text))
    }
    
    func handle(message: WebSocketMessage) {
        Logger.debug(type: .signalingChannel, message: "receive message")
        switch message {
        case .binary(_):
            Logger.debug(type: .signalingChannel, message: "discard binary message")
            break
            
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                Logger.error(type: .signalingChannel, message: "invalid encoding")
                return
            }
            
            switch Signaling.decode(data) {
            case .success(let signaling):
                Logger.debug(type: .signalingChannel, message: "call onReceiveSignaling")
                internalHandlers.onReceive?(signaling)
                handlers.onReceive?(signaling)
            case .failure(let error):
                Logger.error(type: .signalingChannel,
                          message: "decode failed (\(error.localizedDescription)) => \(text)")
            }
        }
    }
    
}
