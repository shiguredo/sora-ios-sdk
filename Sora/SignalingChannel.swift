import Foundation

/**
 ストリームの方向を表します。
 シグナリングメッセージで使われます。
 */
public enum SignalingRole: String {
    
    /// アップストリーム (パブリッシャー)
    case upstream
    
    /// ダウンストリーム (サブスクライバー)
    case downstream
    
}

/**
 シグナリングチャネルのイベントハンドラです。
 */
public final class SignalingChannelHandlers {
    
    /// 接続解除時に呼ばれるブロック
    public var onDisconnectHandler: ((Error?) -> Void)?
    
    /**
     メッセージ受信時に呼ばれるブロック。
     受信したメッセージをシグナリングメッセージとして解析できれば、
     `message` にシグナリングメッセージが指定されます。
     */
    public var onMessageHandler: ((_ message: SignalingMessage?, _ text: String) -> Void)?
    
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
public protocol SignalingChannel: class {

    // MARK: - プロパティ
    
    /// クライアントの設定
    var configuration: Configuration { get }
    
    /// WebSocket チャネル
    var webSocketChannel: WebSocketChannel { get }
    
    /// 接続状態
    var state: ConnectionState { get }
    
    // MARK: - イベントハンドラ
    
    /// イベントハンドラ
    var handlers: SignalingChannelHandlers { get }
    
    /**
     内部処理で使われるイベントハンドラ。
     このハンドラをカスタマイズに使うべきではありません。
     */
    var internalHandlers: SignalingChannelHandlers { get }

    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter configuration: クライアントの設定
     */
    init(configuration: Configuration)

    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter handler: 接続試行後に呼ばれるブロック
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
    func send(message: SignalingMessage)
    
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
        
        webSocketChannel.internalHandlers.onDisconnectHandler = { error in
            self.disconnect(error: error)
        }
        
        webSocketChannel.internalHandlers.onMessageHandler = handleMessage
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
                Logger.debug(type: .signalingChannel, message: "call connect(handler:) handler")
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
            
            Logger.debug(type: .signalingChannel, message: "call onDisconnectHandler")
            self.internalHandlers.onDisconnectHandler?(error)
            self.handlers.onDisconnectHandler?(error)
            
            if self.onConnectHandler != nil {
                Logger.debug(type: .signalingChannel, message: "call connect(handler:) handler")
                self.onConnectHandler!(error)
                self.onConnectHandler = nil
            }

            Logger.debug(type: .signalingChannel, message: "did disconnect")
        }
    }
    
    func send(message: SignalingMessage) {
        Logger.debug(type: .signalingChannel, message: "send message")
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(message)
            let str = String(data: data, encoding: .utf8)!
            Logger.debug(type: .signalingChannel, message: str)
            webSocketChannel.send(message: .text(str))
        } catch {
            Logger.debug(type: .signalingChannel,
                      message: "JSON encoding failed")
            fatalError()
        }
    }
    
    func send(text: String) {
        webSocketChannel.send(message: .text(text))
    }
    
    func handleMessage(_ message: WebSocketMessage) {
        Logger.debug(type: .signalingChannel, message: "receive message")
        switch message {
        case .binary(_):
            Logger.debug(type: .signalingChannel, message: "discard binary message")
            break
            
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                Logger.error(type: .signalingChannel, message: "invalid encoding")
                
                Logger.debug(type: .signalingChannel, message: "call onMessageHandler")
                internalHandlers.onMessageHandler?(nil, text)
                handlers.onMessageHandler?(nil, text)
                return
            }
            
            let decoder = JSONDecoder()
            var sigMessage: SignalingMessage?
            do {
                sigMessage = try decoder.decode(SignalingMessage.self, from: data)
            } catch let error {
                Logger.error(type: .signalingChannel,
                          message: "decode failed (\(error.localizedDescription))")
            }
            
            Logger.debug(type: .signalingChannel, message: "call onMessageHandler")
            internalHandlers.onMessageHandler?(sigMessage, text)
            handlers.onMessageHandler?(sigMessage, text)
        }
    }
    
}
