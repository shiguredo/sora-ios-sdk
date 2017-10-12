import Foundation

/// メディアチャネルのイベントハンドラです。
public final class MediaChannelHandlers {
    
    /// 接続成功時に呼ばれるブロック
    public var onConnectHandler: ((Error?) -> Void)?
    
    /// 接続解除時に呼ばれるブロック
    public var onDisconnectHandler: ((Error?) -> Void)?
    
    /// 接続中にエラーが発生したときに呼ばれるブロック
    public var onFailureHandler: ((Error) -> Void)?
    
    /// シグナリングメッセージの受信時に呼ばれるブロック
    public var onMessageHandler: ((SignalingMessage) -> Void)?
    
    /// ストリームが追加されたときに呼ばれるブロック
    public var onAddStreamHandler: ((MediaStream) -> Void)?
    
    /// ストリームが除去されたときに呼ばれるブロック
    public var onRemoveStreamHandler: ((MediaStream) -> Void)?
    
    /// サーバーからのイベント通知の受信時に呼ばれるハンドラ
    public var onEventHandler: ((Event) -> Void)?
    
}

// MARK: -

public final class MediaChannel {
    
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
    
    /// イベントハンドラ
    public let handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    /// 内部処理で使われるイベントハンドラ
    let internalHandlers: MediaChannelHandlers = MediaChannelHandlers()

    /// クライアントの設定
    public let configuration: Configuration
    
    /**
     クライアント ID 。接続後にセットされます。
     */
    public var clientId: String? {
        get {
            return peerChannel.clientId
        }
    }
    
    /// シグナリングチャネル
    public let signalingChannel: SignalingChannel
    
    /// ピアチャネル
    public let peerChannel: PeerChannel
    
    /// ストリームのリスト
    public var streams: [MediaStream] {
        return peerChannel.streams
    }
    
    /// 先頭のストリーム
    public var mainStream: MediaStream? {
        return streams.first
    }
    
    /// 接続状態
    public private(set) var state: State = .disconnected {
        didSet {
            Logger.trace(type: .mediaChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    /// 接続中であれば ``true``
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    private let aliveMonitor: AliveMonitor = AliveMonitor()
    private var connectionTimer: ConnectionTimer?
    private let manager: Sora
    
    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter manager: `Sora` オブジェクト
     - parameter configuration: クライアントの設定
     */
    init(manager: Sora, configuration: Configuration) {
        Logger.debug(type: .mediaChannel,
                  message: "create signaling channel (\(configuration._signalingChannelType))")
        Logger.debug(type: .mediaChannel,
                  message: "create peer channel (\(configuration._peerChannelType))")
        
        self.manager = manager
        self.configuration = configuration
        self.signalingChannel = configuration._signalingChannelType
            .init(configuration: configuration)
        self.peerChannel = configuration._peerChannelType
            .init(configuration: configuration,
                  signalingChannel: signalingChannel)
        
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
    
    /**
     サーバーに接続します。
     
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter timeout: タイムアウトまでの秒数
     - parameter handler: 接続試行後に呼ばれるブロック
     - parameter error: (接続失敗時) エラー
     */
    public func connect(webRTCConfiguration: WebRTCConfiguration,
                        timeout: Int = Configuration.defaultConnectionTimeout,
                        handler: @escaping (_ error: Error?) -> Void) {
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
        
        peerChannel.internalHandlers.onAddStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "added a stream")
            self.internalHandlers.onAddStreamHandler?(stream)
            self.handlers.onAddStreamHandler?(stream)
        }
        
        peerChannel.internalHandlers.onRemoveStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "removed a stream")
            self.internalHandlers.onRemoveStreamHandler?(stream)
            self.handlers.onRemoveStreamHandler?(stream)
        }
        
        peerChannel.internalHandlers.onNotifyHandler = { message in
            Logger.debug(type: .mediaChannel, message: "receive event notification")
            let event = Event(message: message)
            self.internalHandlers.onEventHandler?(event)
            self.handlers.onEventHandler?(event)
        }
        
        peerChannel.internalHandlers.onSnapshotHandler = { snapshot in
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
                self.internalHandlers.onConnectHandler?(error)
                self.handlers.onConnectHandler?(error)
                return
            }
            Logger.debug(type: .mediaChannel, message: "did connect")
            self.state = .connected
            handler(nil)
            self.internalHandlers.onConnectHandler?(nil)
            self.handlers.onConnectHandler?(nil)
        }
    }

    /**
     接続を解除します。
     
     - parameter error: 接続解除の原因となったエラー
     */
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
            internalHandlers.onDisconnectHandler?(error)
            handlers.onDisconnectHandler?(error)
            if let error = error {
                internalHandlers.onFailureHandler?(error)
                handlers.onFailureHandler?(error)
            }
        }
    }
    
}

extension MediaChannel: CustomStringConvertible {
    
    public var description: String {
        get {
            return "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
        }
    }
    
}

// :nodoc:
extension MediaChannel: Equatable {
    
    public static func ==(lhs: MediaChannel, rhs: MediaChannel) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    
}
