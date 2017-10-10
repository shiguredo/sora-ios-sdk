import Foundation

public enum SignalingRole: String {
    case upstream
    case downstream
}

public enum SignalingChannelState {
    case connecting
    case connected
    case disconnecting
    case disconnected
}

/**
 シグナリングチャネルのイベントハンドラです。
 */
public class SignalingChannelHandlers {
    
    /// 接続中のエラー発生時に呼ばれるブロック
    public var onFailureHandler: ((Error) -> Void)?
    
    /// メッセージ受信時に呼ばれるブロック
    public var onMessageHandler: ((SignalingMessage) -> Void)?
    
}

public protocol SignalingChannel {

    // MARK: - プロパティ
    
    var configuration: Configuration { get }
    var webSocketChannel: WebSocketChannel? { get }
    var state: SignalingChannelState { get }
    var handlers: SignalingChannelHandlers { get }
    
    // MARK: - 初期化
    
    init(configuration: Configuration)

    // MARK: - 接続
    
    func connect(handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    // MARK: メッセージの送信
    
    func send(message: SignalingMessage)
    
}

class BasicSignalingChannel: SignalingChannel {

    var handlers: SignalingChannelHandlers = SignalingChannelHandlers()
    var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
    var configuration: Configuration
    
    var state: SignalingChannelState = .disconnected {
        didSet {
            Logger.trace(type: .signalingChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var webSocketChannel: WebSocketChannel?

    private var connectionTimer: ConnectionTimer?
    private var onConnectHandler: ((Error?) -> Void)?
    
    required init(configuration: Configuration) {
        self.configuration = configuration
        self.webSocketChannel = configuration
            ._webSocketChannelType.init(url: configuration.url)
        
        webSocketChannel!.handlers.onFailureHandler = handleFailure
        webSocketChannel!.handlers.onMessageHandler = handleMessage
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .signalingChannel, message: "try connecting")
        onConnectHandler = handler
        state = .connecting
        
        connectionTimer = ConnectionTimer(target: AliveMonitored.signalingChannel(self),
                                          timeout: configuration.connectionTimeout)
        connectionTimer!.run {
            Logger.debug(type: .signalingChannel, message: "connection timeout")
            self.disconnect(error: SoraError.connectionTimeout)
        }
        
        webSocketChannel!.connect { error in
            self.onConnectHandler?(error)
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
            state = .disconnecting
            webSocketChannel?.disconnect(error: error)
            state = .disconnected
            if let error = error {
                Logger.debug(type: .signalingChannel, message: "error = \(error)")
                handlers.onFailureHandler?(error)
            }
            onConnectHandler?(error)
            onConnectHandler = nil
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
            webSocketChannel!.send(message: .text(str))
        } catch {
            Logger.debug(type: .signalingChannel,
                      message: "JSON encoding failed")
            fatalError()
        }
    }
    
    func handleFailure(error: Error) {
        switch state {
        case .connected:
            Logger.debug(type: .signalingChannel, message: "WebSocket failure")
            disconnect(error: error)

        default:
            break
        }
    }
    
    func handleMessage(_ message: WebSocketMessage) {
        Logger.debug(type: .signalingChannel, message: "receive message")
        switch message {
        case .binary(_):
            Logger.debug(type: .signalingChannel, message: "discard binary message")
            break
            
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                Logger.debug(type: .signalingChannel, message: "invalid encoding")
                return
            }
            let decoder = JSONDecoder()
            do {
                let sigMessage = try decoder.decode(SignalingMessage.self, from: data)
                handlers.onMessageHandler?(sigMessage)
            } catch let error {
                Logger.debug(type: .signalingChannel,
                          message: "decode failed (\(error.localizedDescription))")
            }
        }
    }
    
}
