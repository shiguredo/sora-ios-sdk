import Foundation

public class MediaChannelHandlers {
    
    public var onConnectHandler: ((Error?) -> Void)?
    public var onDisconnectHandler: ((Error?) -> Void)?
    public var onFailureHandler: ((Error) -> Void)?
    public var onMessageHandler: ((SignalingMessage) -> Void)?
    public var onAddStreamHandler: ((MediaStream) -> Void)?
    public var onRemoveStreamHandler: ((MediaStream) -> Void)?
    public var onEventHandler: ((Event) -> Void)?
    
}

// MARK: -

public class MediaChannel {
    
    /**
     `MediaChannel` の接続状態を表します。
     */
    public enum State {
        
        /// 接続試行中
        case connecting
        
        /// 接続済み
        case connected
        
        /// 接続解除試行中
        case disconnecting
        
        /// 接続解除済み
        case disconnected

    }
    
    // MARK: - プロパティ
    
    public let handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    public let configuration: Configuration
    
    /**
     クライアント ID 。接続後にセットされます。
     */
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
            Logger.trace(type: .mediaChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    private let aliveMonitor: AliveMonitor = AliveMonitor()
    private var connectionTimer: ConnectionTimer?
    
    // MARK: - 初期化
    
    public init(configuration: Configuration) {
        Logger.debug(type: .mediaChannel,
                  message: "create signaling channel (\(configuration.signalingChannelType))")
        Logger.debug(type: .mediaChannel,
                  message: "create peer channel (\(configuration.peerChannelType))")
        
        self.configuration = configuration
        self.peerChannel = configuration.peerChannelType
            .init(configuration: configuration)
        
        /*
         aliveMonitor.add(signalingChannel)
         if let channel = signalingChannel.webSocketChannel {
         aliveMonitor.add(channel)
         }
         aliveMonitor.add(peerChannel)
         aliveMonitor.onChange(handler: self.handleChannelStateChanges)
         */
    }
    
    // MARK: - 接続
    
    public func connect(webRTCConfiguration: WebRTCConfiguration,
                        timeout: Int = Configuration.defaultConnectionTimeout,
                        handler: @escaping (Error?) -> Void) {
        DispatchQueue.global().async {
            self.basicConnect(webRTCConfiguration: webRTCConfiguration,
                              timeout: timeout,
                              handler: handler)
        }
    }
    
    private func basicConnect(webRTCConfiguration: WebRTCConfiguration,
                              timeout: Int,
                              handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .mediaChannel, message: "try connecting")
        state = .connecting
        
        let timer = ConnectionTimer(target: AliveMonitored.mediaChannel(self),
                                    timeout: configuration.connectionTimeout)
        timer.run {
            Logger.debug(type: .mediaChannel, message: "connection timeout")
            self.disconnect(error: SoraError.connectionTimeout)
        }
        connectionTimer = timer
        
        peerChannel.handlers.onAddStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "added a stream")
            self.handlers.onAddStreamHandler?(stream)
        }
        
        peerChannel.handlers.onRemoveStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "removed a stream")
            self.handlers.onRemoveStreamHandler?(stream)
        }
        
        peerChannel.handlers.onNotifyHandler = { message in
            Logger.debug(type: .mediaChannel, message: "receive event notification")
            self.handlers.onEventHandler?(Event(message: message))
        }
        
        peerChannel.handlers.onSnapshotHandler = { snapshot in
            Logger.debug(type: .mediaStream, message: "receive snapshot")
            if let stream = self.mainStream {
                stream.render(videoFrame: VideoFrame.snapshot(snapshot))
            }
        }
        
        peerChannel.connect(webRTCConfiguration: webRTCConfiguration) { error in
            if let error = error {
                Logger.debug(type: .mediaChannel, message: "failed connecting")
                self.disconnect(error: error)
                handler(error)
                self.handlers.onConnectHandler?(error)
                return
            }
            Logger.debug(type: .mediaChannel, message: "did connect")
            self.state = .connected
            handler(nil)
            self.handlers.onConnectHandler?(nil)
        }
    }

    public func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .mediaChannel, message: "try disconnecting")
            state = .disconnecting
            connectionTimer?.stop()
            connectionTimer = nil
            peerChannel.disconnect(error: error)
            Logger.debug(type: .mediaChannel, message: "did disconnect")
            state = .disconnected
            handlers.onDisconnectHandler?(error)
            if let error = error {
                handlers.onFailureHandler?(error)
            }
        }
    }
    
}
