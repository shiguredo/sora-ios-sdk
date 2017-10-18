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

/**
 
 一度接続を行ったメディアチャネルは再利用できません。
 同じ設定で接続を行いたい場合は、新しい接続を行う必要があります。
 
 ## 接続が解除されるタイミング
 
 メディアチャネルの接続が解除される条件を以下に示します。
 いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル
 (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます。

 - シグナリングチャネル (`SignalingChannel`) の接続が解除される。
 - WebSocket チャネル (`WebSocketChannel`) の接続が解除される。
 - ピアチャネル (`PeerChannel`) の接続が解除される。
 - サーバーから受信したシグナリング `ping` に対して `pong` を返さない。
   これはピアチャネルの役目です。
 
 */
public final class MediaChannel {
        
    // MARK: - イベントハンドラ
    
    /// イベントハンドラ
    public let handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    /// 内部処理で使われるイベントハンドラ
    let internalHandlers: MediaChannelHandlers = MediaChannelHandlers()

    // MARK: - 接続情報
    
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
    
    /// 接続状態
    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .mediaChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    /// 接続中 (`state == .connected`) であれば ``true``
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    /// ストリームのリスト
    public var streams: [MediaStream] {
        return peerChannel.streams
    }
    
    /// 先頭のストリーム
    public var mainStream: MediaStream? {
        return streams.first
    }

    // MARK: 接続チャネル
    
    /// シグナリングチャネル
    public let signalingChannel: SignalingChannel
    
    /// ピアチャネル
    public let peerChannel: PeerChannel
    
    private var connectionTimer: ConnectionTimer
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
        signalingChannel = configuration._signalingChannelType
            .init(configuration: configuration)
        peerChannel = configuration._peerChannelType
            .init(configuration: configuration,
                  signalingChannel: signalingChannel)
        
        connectionTimer = ConnectionTimer(monitors: [
            .webSocketChannel(signalingChannel.webSocketChannel),
            .signalingChannel(signalingChannel),
            .peerChannel(peerChannel)],
                                          timeout: configuration.connectionTimeout)
    }
    
    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter timeout: タイムアウトまでの秒数
     - parameter handler: 接続試行後に呼ばれるブロック
     - parameter error: (接続失敗時) エラー
     */
    func connect(webRTCConfiguration: WebRTCConfiguration,
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
                stream.send(videoFrame: VideoFrame.snapshot(snapshot))
            }
        }
        
        peerChannel.connect() { error in
            self.connectionTimer.stop()

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
        
        connectionTimer.run {
            Logger.debug(type: .mediaChannel, message: "connection timeout")
            self.disconnect(error: SoraError.connectionTimeout)
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
            connectionTimer.stop()
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
    
    /// :nodoc:
    public var description: String {
        get {
            return "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
        }
    }
    
}

/// :nodoc:
extension MediaChannel: Equatable {
    
    public static func ==(lhs: MediaChannel, rhs: MediaChannel) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    
}
