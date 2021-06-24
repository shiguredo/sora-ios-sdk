import Foundation

/// メディアチャネルのイベントハンドラです。
public final class MediaChannelHandlers {
    
    /// このプロパティは onConnect に置き換えられました。
    @available(*, deprecated, renamed: "onConnect",
    message: "このプロパティは onConnect に置き換えられました。")
    public var onConnectHandler: ((Error?) -> Void)? {
        get { onConnect }
        set { onConnect = newValue }
    }
    
    /// このプロパティは onDisconnect に置き換えられました。
    @available(*, deprecated, renamed: "onDisconnect",
    message: "このプロパティは onDisconnect に置き換えられました。")
    public var onDisconnectHandler: ((Error?) -> Void)? {
        get { onDisconnect }
        set { onDisconnect = newValue }
    }
    
    /// このプロパティは onAddStream に置き換えられました。
    @available(*, deprecated, renamed: "onAddStream",
    message: "このプロパティは onAddStream に置き換えられました。")
    public var onAddStreamHandler: ((MediaStream) -> Void)? {
        get { onAddStream }
        set { onAddStream = newValue }
    }
    
    /// このプロパティは onRemoveStream に置き換えられました。
    @available(*, deprecated, renamed: "onRemoveStream",
    message: "このプロパティは onRemoveStream に置き換えられました。")
    public var onRemoveStreamHandler: ((MediaStream) -> Void)? {
        get { onRemoveStream }
        set { onRemoveStream = newValue }
    }
    
    /// このプロパティは onReceiveSignaling に置き換えられました。
    @available(*, deprecated, renamed: "onReceiveSignaling",
    message: "このプロパティは onReceiveSignaling に置き換えられました。")
    public var onReceiveSignalingHandler: ((Signaling) -> Void)? {
        get { onReceiveSignaling }
        set { onReceiveSignaling = newValue }
    }
    
    /// 接続成功時に呼ばれるクロージャー
    public var onConnect: ((Error?) -> Void)?
    
    /// 接続解除時に呼ばれるクロージャー
    public var onDisconnect: ((Error?) -> Void)?
    
    /// ストリームが追加されたときに呼ばれるクロージャー
    public var onAddStream: ((MediaStream) -> Void)?
    
    /// ストリームが除去されたときに呼ばれるクロージャー
    public var onRemoveStream: ((MediaStream) -> Void)?
    
    /// シグナリング受信時に呼ばれるクロージャー
    public var onReceiveSignaling: ((Signaling) -> Void)?
    
    /// 初期化します。
    public init() {}
    
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
    public var handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    /// 内部処理で使われるイベントハンドラ
    var internalHandlers: MediaChannelHandlers = MediaChannelHandlers()
    
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
    
    /**
     接続 ID 。接続後にセットされます。
     */
    public var connectionId: String? {
        get {
            return peerChannel.connectionId
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
    
    /// 接続開始時刻。
    /// 接続中にのみ取得可能です。
    public private(set) var connectionStartTime: Date?
    
    /// 接続時間 (秒) 。
    /// 接続中にのみ取得可能です。
    public var connectionTime: Int? {
        get {
            if let start = connectionStartTime {
                return Int(Date().timeIntervalSince(start))
            } else {
                return nil
            }
        }
    }
    
    // MARK: 接続中のチャネルの情報
    
    /// 同チャネルに接続中のクライアントの数。
    /// サーバーから通知を受信可能であり、かつ接続中にのみ取得可能です。
    public var connectionCount: Int? {
        get {
            switch (publisherCount, subscriberCount) {
            case (.some(let pub), .some(let sub)):
                return pub + sub
            default:
                return nil
            }
        }
    }
    
    /// 同チャネルに接続中のクライアントのうち、パブリッシャーの数。
    /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
    public private(set) var publisherCount: Int?
    
    /// 同チャネルに接続中のクライアントの数のうち、サブスクライバーの数。
    /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
    public private(set) var subscriberCount: Int?
    
    // MARK: 接続チャネル
    
    /// シグナリングチャネル
    public let signalingChannel: SignalingChannel
    
    /// ピアチャネル
    public let peerChannel: PeerChannel
    
    /// ストリームのリスト
    public var streams: [MediaStream] {
        return peerChannel.streams
    }
    
    /**
     最初のストリーム。
     マルチストリームでは、必ずしも最初のストリームが 送信ストリームとは限りません。
     送信ストリームが必要であれば `senderStream` を使用してください。
     */
    public var mainStream: MediaStream? {
        return streams.first
    }
    
    /// 送信に使われるストリーム。
    /// ストリーム ID が `configuration.publisherStreamId` に等しいストリームを返します。
    public var senderStream: MediaStream? {
        streams.first { stream in
            stream.streamId == configuration.publisherStreamId
        }
    }
    
    /// 受信ストリームのリスト。
    /// ストリーム ID が `configuration.publisherStreamId` と異なるストリームを返します。
    public var receiverStreams: [MediaStream] {
        streams.filter { stream in
            stream.streamId != configuration.publisherStreamId
        }
    }
    
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
        signalingChannel.handlers =
            configuration.signalingChannelHandlers
        peerChannel = configuration._peerChannelType
            .init(configuration: configuration,
                  signalingChannel: signalingChannel)
        peerChannel.handlers =
            configuration.peerChannelHandlers
        handlers = configuration.mediaChannelHandlers
        
        connectionTimer = ConnectionTimer(monitors: [
            .webSocketChannel(signalingChannel.webSocketChannel),
            .signalingChannel(signalingChannel),
            .peerChannel(peerChannel)],
                                          timeout: configuration.connectionTimeout)
    }
    
    // MARK: - 接続
    
    private var _handler: ((_ error: Error?) -> Void)?

    private func executeHandler(error: Error?) {
        _handler?(error)
        _handler = nil
    }
    
    /**
     サーバーに接続します。
     
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter timeout: タイムアウトまでの秒数
     - parameter handler: 接続試行後に呼ばれるクロージャー
     - parameter error: (接続失敗時) エラー
     */
    func connect(webRTCConfiguration: WebRTCConfiguration,
                 timeout: Int = 30,
                 handler: @escaping (_ error: Error?) -> Void) -> ConnectionTask {
        let task = ConnectionTask()
        if state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "MediaChannel is already connected"))
            task.complete()
            return task
        }
        
        DispatchQueue.global().async {
            self.basicConnect(connectionTask: task,
                              webRTCConfiguration: webRTCConfiguration,
                              timeout: timeout,
                              handler: handler)
        }
        return task
    }
    
    private func basicConnect(connectionTask: ConnectionTask,
                              webRTCConfiguration: WebRTCConfiguration,
                              timeout: Int,
                              handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .mediaChannel, message: "try connecting")
        _handler = handler
        state = .connecting
        connectionStartTime = nil
        connectionTask.peerChannel = peerChannel

        signalingChannel.internalHandlers.onDisconnect = { error in
            if self.state == .connecting || self.state == .connected {
                self.disconnect(error: error)
            }
            connectionTask.complete()
        }
        
        peerChannel.internalHandlers.onDisconnect = { error in
            if self.state == .connecting || self.state == .connected {
                self.disconnect(error: error)
            }
            connectionTask.complete()
        }
        
        peerChannel.internalHandlers.onAddStream = { stream in
            Logger.debug(type: .mediaChannel, message: "added a stream")
            Logger.debug(type: .mediaChannel, message: "call onAddStream")
            self.internalHandlers.onAddStream?(stream)
            self.handlers.onAddStream?(stream)
        }
        
        peerChannel.internalHandlers.onRemoveStream = { stream in
            Logger.debug(type: .mediaChannel, message: "removed a stream")
            Logger.debug(type: .mediaChannel, message: "call onRemoveStream")
            self.internalHandlers.onRemoveStream?(stream)
            self.handlers.onRemoveStream?(stream)
        }
        
        peerChannel.internalHandlers.onReceiveSignaling = { message in
            Logger.debug(type: .mediaChannel, message: "receive signaling")
            switch message {
            case .notify(let message):
                self.publisherCount = message.publisherCount
                self.subscriberCount = message.subscriberCount
            default:
                break
            }
            
            Logger.debug(type: .mediaChannel, message: "call onReceiveSignaling")
            self.internalHandlers.onReceiveSignaling?(message)
            self.handlers.onReceiveSignaling?(message)
        }
        
        peerChannel.connect() { error in
            self.connectionTimer.stop()
            connectionTask.complete()
            
            if let error = error {
                Logger.error(type: .mediaChannel, message: "failed to connect")
                self.disconnect(error: error)
                handler(error)
                
                Logger.debug(type: .mediaChannel, message: "call onConnect")
                self.internalHandlers.onConnect?(error)
                self.handlers.onConnect?(error)
                return
            }
            Logger.debug(type: .mediaChannel, message: "did connect")
            self.state = .connected
            handler(nil)
            Logger.debug(type: .mediaChannel, message: "call onConnect")
            self.internalHandlers.onConnect?(nil)
            self.handlers.onConnect?(nil)
        }
        
        self.connectionStartTime = Date()
        connectionTimer.run {
            Logger.error(type: .mediaChannel, message: "connection timeout")
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
            if let error = error {
                Logger.error(type: .mediaChannel,
                             message: "error: \(error.localizedDescription)")
            }
            if state == .connecting {
                executeHandler(error: error)
            }
            
            state = .disconnecting
            connectionTimer.stop()
            peerChannel.disconnect(error: error)
            Logger.debug(type: .mediaChannel, message: "did disconnect")
            state = .disconnected
            
            Logger.debug(type: .mediaChannel, message: "call onDisconnect")
            internalHandlers.onDisconnect?(error)
            handlers.onDisconnect?(error)
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
