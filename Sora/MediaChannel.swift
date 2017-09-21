import Foundation

public class MediaChannelHandlers {
    
    public let onFailureHandler: Callback1<Error, Void> = Callback1(repeats: true)
    public let onMessageHandler: Callback1<SignalingMessage, Void> = Callback1(repeats: true)
    public let onAddStreamHandler: Callback1<MediaStream, Void> = Callback1(repeats: true)
    public let onRemoveStreamHandler: Callback1<MediaStream, Void> = Callback1(repeats: true)
    public let onEventHandler: Callback1<Event, Void> = Callback1(repeats: true)
    
    public func onFailure(handler: @escaping (Error) -> Void) {
        onFailureHandler.onExecute(handler: handler)
    }
    
    public func onMessage(handler: @escaping (SignalingMessage) -> Void) {
        onMessageHandler.onExecute(handler: handler)
    }
    
    public func onAddStream(handler: @escaping (MediaStream) -> Void) {
        onAddStreamHandler.onExecute(handler: handler)
    }
    
    public func onRemoveStream(handler: @escaping (MediaStream) -> Void) {
        onRemoveStreamHandler.onExecute(handler: handler)
    }
    
    public func onEvent(handler: @escaping (Event) -> Void) {
        onEventHandler.onExecute(handler: handler)
    }
    
}

// MARK: -

open class MediaChannel {
    
    public enum State {
        case connecting
        case connected
        case disconnecting
        case disconnected
        case waitingOffer
        case waitingPeer
    }
    
    public let handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    public let configuration: Configuration
    public private(set) var clientId: String?
    public let peerChannel: PeerChannel
    
    public var streams: [MediaStream] {
        return peerChannel.streams
    }
    
    public var mainStream: MediaStream? {
        return streams.first
    }
    
    public private(set) var state: State = .disconnected {
        didSet {
            Log.trace(type: .mediaChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    private let aliveMonitor: AliveMonitor = AliveMonitor()
    private var connectionTimer: ConnectionTimer?
    private var onConnectHandler: Callback1<Error?, Void> = Callback1(repeats: false)
    
    public init(configuration: Configuration) {
        Log.debug(type: .mediaChannel,
                  message: "create signaling channel (\(configuration.signalingChannelType))")
        Log.debug(type: .mediaChannel,
                  message: "create peer channel (\(configuration.peerChannelType))")
        
        self.configuration = configuration
        self.peerChannel = configuration.peerChannelType
            .init(configuration: configuration)
        
        /*
         aliveMonitor.addObject(signalingChannel)
         if let channel = signalingChannel.webSocketChannel {
         aliveMonitor.addObject(channel)
         }
         aliveMonitor.addObject(peerChannel)
         aliveMonitor.onChange(handler: self.handleChannelStateChanges)
         */
    }
    
    public func connect(timeout: Int = Configuration.defaultConnectionTimeout,
                        handler: @escaping (Error?) -> Void) {
        Log.debug(type: .mediaChannel, message: "try connecting")
        state = .connecting
        onConnectHandler.onExecute(handler: handler)
        
        let timer = ConnectionTimer(target: self, timeout: configuration.connectionTimeout)
        timer.run {
            Log.debug(type: .mediaChannel, message: "connection timeout")
            self.disconnect(error: SoraError.connectionTimeout)
        }
        connectionTimer = timer
        
        peerChannel.handlers.onAddStream { stream in
            Log.debug(type: .mediaChannel, message: "added a stream")
            self.handlers.onAddStreamHandler.execute(stream)
        }
        
        peerChannel.handlers.onRemoveStream { stream in
            Log.debug(type: .mediaChannel, message: "removed a stream")
            self.handlers.onRemoveStreamHandler.execute(stream)
        }
        
        peerChannel.handlers.onNotify { message in
            Log.debug(type: .mediaChannel, message: "receive event notification")
            self.handlers.onEventHandler.execute(Event(message: message))
        }
        
        peerChannel.connect { error in
            if let error = error {
                Log.debug(type: .mediaChannel, message: "failed connecting")
                self.disconnect(error: error)
                return
            }
            Log.debug(type: .mediaChannel, message: "did connect")
            self.state = .connected
            self.onConnectHandler.execute(error)
        }
    }
    
    public func handleChannelStateChanges(objects: [AliveMonitorable]) {
        // TODO
    }
    
    public func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Log.debug(type: .mediaChannel, message: "try disconnecting")
            state = .disconnecting
            peerChannel.disconnect(error: error)
            
            Log.debug(type: .mediaChannel, message: "did disconnect")
            state = .disconnected
            
            if let error = error {
                handlers.onFailureHandler.execute(error)
            }
            onConnectHandler.execute(error)
        }
    }
    
}

// MARK: - AliveMonitorable

extension MediaChannel: AliveMonitorable {
    
    public var aliveState: AliveState {
        switch state {
        case .connected:
            return .available
        case .disconnecting, .disconnected:
            return .unavailable
        default:
            return .connecting
        }
    }
    
}
