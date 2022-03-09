import Foundation
import WebRTC

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

    /// シグナリングが DataChannel 経由に切り替わったタイミングで呼ばれるクロージャー
    public var onDataChannel: ((MediaChannel) -> Void)?

    /// DataChannel のメッセージ受信時に呼ばれるクロージャー
    public var onDataChannelMessage: ((MediaChannel, String, Data) -> Void)?

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
    public var handlers = MediaChannelHandlers()

    /// 内部処理で使われるイベントハンドラ
    var internalHandlers = MediaChannelHandlers()

    // MARK: - 接続情報

    /// クライアントの設定
    public let configuration: Configuration

    /**
     最初に type: connect メッセージを送信した URL (デバッグ用)

     Sora から type: redirect メッセージを受信した場合、 contactUrl と connectedUrl には異なる値がセットされます
     type: redirect メッセージを受信しなかった場合、 contactUrl と connectedUrl には同じ値がセットされます
     */
    public var contactUrl: URL? {
        signalingChannel.contactUrl
    }

    /// 接続中の URL
    public var connectedUrl: URL? {
        signalingChannel.connectedUrl
    }

    /// メディアチャンネルの内部で利用している RTCPeerConnection
    public var native: RTCPeerConnection? {
        peerChannel.nativeChannel
    }

    /**
     クライアント ID 。接続後にセットされます。
     */
    public var clientId: String? {
        peerChannel.clientId
    }

    /**
     接続 ID 。接続後にセットされます。
     */
    public var connectionId: String? {
        peerChannel.connectionId
    }

    /// 接続状態
    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .mediaChannel,
                         message: "changed state from \(oldValue) to \(state)")
        }
    }

    /// 接続中 (`state == .connected`) であれば ``true``
    public var isAvailable: Bool { state == .connected }

    /// 接続開始時刻。
    /// 接続中にのみ取得可能です。
    public private(set) var connectionStartTime: Date?

    /// 接続時間 (秒) 。
    /// 接続中にのみ取得可能です。
    public var connectionTime: Int? {
        if let start = connectionStartTime {
            return Int(Date().timeIntervalSince(start))
        } else {
            return nil
        }
    }

    // MARK: 接続中のチャネルの情報

    /// 同チャネルに接続中のクライアントの数。
    /// サーバーから通知を受信可能であり、かつ接続中にのみ取得可能です。
    public var connectionCount: Int? {
        switch (publisherCount, subscriberCount) {
        case let (.some(pub), .some(sub)):
            return pub + sub
        default:
            return nil
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
    let signalingChannel: SignalingChannel

    /// ウェブソケットチャンネル
    @available(*, unavailable, message: "webSocketChannel は廃止されました。")
    public var webSocketChannel: Any?

    /// ピアチャネル
    var peerChannel: PeerChannel {
        _peerChannel!
    }

    // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
    private var _peerChannel: PeerChannel?

    /// ストリームのリスト
    public var streams: [MediaStream] {
        peerChannel.streams
    }

    /**
     最初のストリーム。
     マルチストリームでは、必ずしも最初のストリームが 送信ストリームとは限りません。
     送信ストリームが必要であれば `senderStream` を使用してください。
     */
    public var mainStream: MediaStream? {
        streams.first
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

    private var connectionTimer: ConnectionTimer {
        _connectionTimer!
    }

    // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
    private var _connectionTimer: ConnectionTimer?

    private let manager: Sora

    // MARK: - インスタンスの生成

    /**
     初期化します。

     - parameter manager: `Sora` オブジェクト
     - parameter configuration: クライアントの設定
     */
    init(manager: Sora, configuration: Configuration) {
        self.manager = manager
        self.configuration = configuration
        signalingChannel = SignalingChannel.init(configuration: configuration)
        _peerChannel = PeerChannel.init(configuration: configuration,
                                        signalingChannel: signalingChannel,
                                        mediaChannel: self)
        handlers = configuration.mediaChannelHandlers

        _connectionTimer = ConnectionTimer(monitors: [
            .signalingChannel(signalingChannel),
            .peerChannel(_peerChannel!),
        ],
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
                 handler: @escaping (_ error: Error?) -> Void) -> ConnectionTask
    {
        let task = ConnectionTask()
        if state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "MediaChannel is already connected"))
            task.complete()
            return task
        }

        DispatchQueue.global().async { [weak self] in
            self?.basicConnect(connectionTask: task,
                               webRTCConfiguration: webRTCConfiguration,
                               timeout: timeout,
                               handler: handler)
        }
        return task
    }

    private func basicConnect(connectionTask: ConnectionTask,
                              webRTCConfiguration: WebRTCConfiguration,
                              timeout: Int,
                              handler: @escaping (Error?) -> Void)
    {
        Logger.debug(type: .mediaChannel, message: "try connecting")
        _handler = handler
        state = .connecting
        connectionStartTime = nil
        connectionTask.peerChannel = peerChannel

        signalingChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
            guard let weakSelf = self else {
                return
            }
            if weakSelf.state == .connecting || weakSelf.state == .connected {
                weakSelf.internalDisconnect(error: error, reason: reason)
            }
            connectionTask.complete()
        }

        peerChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
            guard let weakSelf = self else {
                return
            }
            if weakSelf.state == .connecting || weakSelf.state == .connected {
                weakSelf.internalDisconnect(error: error, reason: reason)
            }
            connectionTask.complete()
        }

        peerChannel.internalHandlers.onAddStream = { [weak self] stream in
            guard let weakSelf = self else {
                return
            }
            Logger.debug(type: .mediaChannel, message: "added a stream")
            Logger.debug(type: .mediaChannel, message: "call onAddStream")
            weakSelf.internalHandlers.onAddStream?(stream)
            weakSelf.handlers.onAddStream?(stream)
        }

        peerChannel.internalHandlers.onRemoveStream = { [weak self] stream in
            guard let weakSelf = self else {
                return
            }
            Logger.debug(type: .mediaChannel, message: "removed a stream")
            Logger.debug(type: .mediaChannel, message: "call onRemoveStream")
            weakSelf.internalHandlers.onRemoveStream?(stream)
            weakSelf.handlers.onRemoveStream?(stream)
        }

        peerChannel.internalHandlers.onReceiveSignaling = { [weak self] message in
            guard let weakSelf = self else {
                return
            }
            Logger.debug(type: .mediaChannel, message: "receive signaling")
            switch message {
            case let .notify(message):
                weakSelf.publisherCount = message.publisherCount
                weakSelf.subscriberCount = message.subscriberCount
            default:
                break
            }

            Logger.debug(type: .mediaChannel, message: "call onReceiveSignaling")
            weakSelf.internalHandlers.onReceiveSignaling?(message)
            weakSelf.handlers.onReceiveSignaling?(message)
        }

        peerChannel.connect { [weak self] error in
            guard let weakSelf = self else {
                return
            }

            weakSelf.connectionTimer.stop()
            connectionTask.complete()

            if let error = error {
                Logger.error(type: .mediaChannel, message: "failed to connect")
                weakSelf.internalDisconnect(error: error, reason: .signalingFailure)
                handler(error)

                Logger.debug(type: .mediaChannel, message: "call onConnect")
                weakSelf.internalHandlers.onConnect?(error)
                weakSelf.handlers.onConnect?(error)
                return
            }
            Logger.debug(type: .mediaChannel, message: "did connect")
            weakSelf.state = .connected
            handler(nil)
            Logger.debug(type: .mediaChannel, message: "call onConnect")
            weakSelf.internalHandlers.onConnect?(nil)
            weakSelf.handlers.onConnect?(nil)
        }

        connectionStartTime = Date()
        connectionTimer.run {
            Logger.error(type: .mediaChannel, message: "connection timeout")
            self.internalDisconnect(error: SoraError.connectionTimeout, reason: .signalingFailure)
        }
    }

    /**
     接続を解除します。

     - parameter error: 接続解除の原因となったエラー
     */
    public func disconnect(error: Error?) {
        // reason に .user を指定しているので、 disconnect は SDK 内部では利用しない
        internalDisconnect(error: error, reason: .user)
    }

    func internalDisconnect(error: Error?, reason: DisconnectReason) {
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
            peerChannel.disconnect(error: error, reason: reason)
            Logger.debug(type: .mediaChannel, message: "did disconnect")
            state = .disconnected

            Logger.debug(type: .mediaChannel, message: "call onDisconnect")
            internalHandlers.onDisconnect?(error)
            handlers.onDisconnect?(error)
        }
    }

    /// DataChannel を利用してメッセージを送信します
    public func sendMessage(label: String, data: Data) -> Error? {
        guard peerChannel.switchedToDataChannel else {
            return SoraError.messagingError(reason: "DataChannel is not open yet")
        }

        guard label.starts(with: "#") else {
            return SoraError.messagingError(reason: "label should start with #")
        }

        guard let dc = peerChannel.dataChannels[label] else {
            return SoraError.messagingError(reason: "no DataChannel found: label => \(label)")
        }

        let readyState = dc.readyState
        guard readyState == .open else {
            return SoraError.messagingError(reason: "readyState of the DataChannel is not open: label => \(label), readyState => \(readyState)")
        }

        let result = dc.send(data)

        return result ? nil : SoraError.messagingError(reason: "failed to send message: label => \(label)")
    }
}

extension MediaChannel: CustomStringConvertible {
    /// :nodoc:
    public var description: String {
        "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
    }
}

/// :nodoc:
extension MediaChannel: Equatable {
    public static func == (lhs: MediaChannel, rhs: MediaChannel) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}
