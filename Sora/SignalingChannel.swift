import Foundation
import AVFoundation

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
@available(*, unavailable, message: "TODO")
public class SignalingChannelHandlers {}

class SignalingChannelInternalHandlers {
    
    /// 接続解除時に呼ばれるクロージャー
    var onDisconnect: ((Error?, DisconnectReason) -> Void)?
    
    /// シグナリング受信時に呼ばれるクロージャー
    var onReceive: ((Signaling) -> Void)?

    /// シグナリング送信時に呼ばれるクロージャー
    var onSend: ((Signaling) -> Signaling)?
    
    /// 初期化します。
    init() {}
    
}

class SignalingChannel {
    
    var internalHandlers: SignalingChannelInternalHandlers = SignalingChannelInternalHandlers()
    var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
    var ignoreDisconnectWebSocket: Bool = false
    var dataChannelSignaling: Bool = false
    
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
                    self.disconnect(error: error, reason: error != nil ? .webSocket : .noError)
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
                self.disconnect(error: error, reason: .webSocket)
                return
            }
            Logger.debug(type: .signalingChannel, message: "connected")
            self.state = .connected
        }
    }
    
    func disconnect(error: Error?, reason: DisconnectReason) {
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
            self.internalHandlers.onDisconnect?(error, reason)
            
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
        let message = internalHandlers.onSend?(message) ?? message
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
            case .failure(let error):
                Logger.error(type: .signalingChannel,
                          message: "decode failed (\(error.localizedDescription)) => \(text)")
            }
        }
    }
    
}
