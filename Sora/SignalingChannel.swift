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

public class SignalingChannelHandlers {
    
    public var onFailureHandler: ((Error) -> Void)?
    public var onMessageHandler: ((SignalingMessage) -> Void)?
    
}

public protocol SignalingChannel: AliveMonitorable {

    var configuration: Configuration { get }
    var webSocketChannel: WebSocketChannel? { get }
    var state: SignalingChannelState { get }
    var handlers: SignalingChannelHandlers { get }
    
    init(configuration: Configuration)

    func connect(handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    func send(message: SignalingMessage)
    
}

public class BasicSignalingChannel: SignalingChannel {

    public var handlers: SignalingChannelHandlers = SignalingChannelHandlers()
    public var webSocketChannelHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    
    public var configuration: Configuration
    
    public var state: SignalingChannelState = .disconnected {
        didSet {
            Logger.trace(type: .signalingChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    public var webSocketChannel: WebSocketChannel?

    public var aliveState: AliveState {
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
    
    private var connectionTimer: ConnectionTimer?
    private var onConnectHandler: ((Error?) -> Void)?
    
    public required init(configuration: Configuration) {
        self.configuration = configuration
        self.webSocketChannel = configuration
            .webSocketChannelType.init(url: configuration.url)
        
        webSocketChannel!.handlers.onFailureHandler = handleFailure
        webSocketChannel!.handlers.onMessageHandler = handleMessage
    }
    
    public func connect(handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .signalingChannel, message: "try connecting")
        onConnectHandler = handler
        state = .connecting
        
        connectionTimer = ConnectionTimer(target: self,
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
    
    public func disconnect(error: Error?) {
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
    
    public func send(message: SignalingMessage) {
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
