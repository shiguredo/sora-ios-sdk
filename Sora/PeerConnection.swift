import Foundation
import WebRTC
import SocketRocket
import Unbox
import SDWebImage

public enum StatusCode: Int {
    
    case signalingFailure = 4490
    
}

public class PeerConnection {
    
    public enum State: String {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }
    
    public static let nativeFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCEnableMetrics()
        return RTCPeerConnectionFactory()
    }()
    
    public weak var connection: Connection?
    public weak var mediaConnection: MediaConnection?
    public var role: Role
    public var metadata: String?
    var mediaStreamId: String?
    public var mediaOption: MediaOption
    public var clientId: String?
    
    public var state: State {
        willSet { onChangeStateHandler?(newValue) }
    }
    
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    var mediaCapturer: MediaCapturer? {
        get { return context?.mediaCapturer }
    }
    
    public var nativePeerConnection: RTCPeerConnection? {
        get { return context?.nativePeerConnection }
    }
    
    var context: PeerConnectionContext?
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    init(connection: Connection,
         mediaConnection: MediaConnection,
         role: Role,
         metadata: String? = nil,
         mediaStreamId: String? = nil,
         mediaOption: MediaOption = MediaOption()) {
        self.connection = connection
        self.mediaConnection = mediaConnection
        self.role = role
        self.metadata = metadata
        self.mediaStreamId = mediaStreamId
        self.mediaOption = mediaOption
        self.state = .disconnected
    }
    
    // MARK: ピア接続
    
    // 接続に成功すると nativePeerConnection プロパティがセットされる
    func connect(timeout: Int, handler: @escaping ((ConnectionError?) -> Void)) {
        eventLog?.markFormat(type: .PeerConnection, format: "connect")
        switch state {
        case .connected, .connecting, .disconnecting:
            handler(ConnectionError.connectionBusy)
        case .disconnected:
            state = .connecting
            context = PeerConnectionContext(peerConnection: self, role: role)
            context!.connect(timeout: timeout, handler: handler)
        }
    }
    
    func disconnect(handler: @escaping (ConnectionError?) -> Void) {
        eventLog?.markFormat(type: .PeerConnection, format: "disconnect")
        switch state {
        case .disconnecting:
            handler(ConnectionError.connectionBusy)
        case .disconnected:
            handler(ConnectionError.connectionDisconnected)
        case .connecting, .connected:
            assert(nativePeerConnection == nil, "nativePeerConnection must not be nil")
            state = .disconnecting
            context?.disconnect(handler: handler)
        }
    }
    
    func terminate() {
        eventLog?.markFormat(type: .PeerConnection, format: "terminate")
        state = .disconnected
        context = nil
    }
    
    // MARK: WebSocket
    
    func send(message: Messageable) -> ConnectionError? {
        let message = message.message()
        switch state {
        case .connected:
            return context!.send(message)
        case .disconnected:
            return ConnectionError.connectionDisconnected
        default:
            return ConnectionError.connectionBusy
        }
    }
    
    // MARK: イベントハンドラ
    
    var onChangeStateHandler: ((State) -> Void)?

    public func onChangeState(handler: @escaping (State) -> Void) {
        onChangeStateHandler = handler
    }
    
}

// 接続状態を監視する
class ConnectionMonitor {
    
    enum State {
        case stop
        case monitoring
        case terminated
    }
    
    weak var context: PeerConnectionContext!
    var state: State = .stop
    var error: ConnectionError?
    var deadline: DispatchTime
    var handler: (ConnectionError?) -> Void
    var timeoutWorkItem: DispatchWorkItem!
    var validationTimer: Timer!
    
    init(context: PeerConnectionContext,
         timeout: Int,
         handler: @escaping (ConnectionError?) -> Void) {
        self.context = context
        self.deadline = .now() + .seconds(timeout)
        self.handler = handler
    }
    
    func run() {
        guard state == .stop else { return }
        
        state = .monitoring
        
        timeoutWorkItem = DispatchWorkItem {
            if self.state == .monitoring {
                self.terminate(error: ConnectionError.connectionWaitTimeout)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: self.deadline,
                                          execute: timeoutWorkItem)
        
        validationTimer = Timer(timeInterval: 1.0, repeats: true) { timer in
            self.validate()
        }
        RunLoop.main.add(validationTimer, forMode: .commonModes)
    }
    
    func terminate(error: ConnectionError? = nil) {
        guard state == .monitoring else { return }
        
        self.error = error
        timeoutWorkItem.cancel()
        validationTimer.invalidate()
        state = .terminated
        handler(error)
    }
    
    func validate() {
        context.eventLog?.markFormat(type: .ConnectionMonitor,
                                     format: "validate connection state")

        switch context.webSocketReadyState {
        case nil, SRReadyState.CLOSED?:
            break
        default:
            return
        }

        switch context.nativeSignalingState {
        case nil, RTCSignalingState.closed?:
            break
        default:
            return
        }
        
        switch context.nativeICEConnectionState {
        case nil, RTCIceConnectionState.closed?:
            break
        default:
            return
        }
        
        terminate()
    }
    
    func completeConnection() {
        timeoutWorkItem?.cancel()
    }
    
}

class PeerConnectionContext: NSObject, SRWebSocketDelegate, RTCPeerConnectionDelegate {
    
    enum State: String {
        case signalingConnecting
        case signalingConnected
        case peerConnectionReady
        case peerConnectionOffered
        case peerConnectionAnswering
        case peerConnectionAnswered
        case peerConnectionConnecting
        case updateOffered
        case connected
        case disconnecting
        case disconnected
        case terminated
    }

    weak var peerConnection: PeerConnection?
    var role: Role
    
    private var _state: State = .disconnected
    
    var state: State {
        get {
            if peerConnection == nil {
                return .terminated
            } else {
                return _state
            }
        }
        set {
            _state = newValue
            switch newValue {
            case .connected:
                peerConnection?.state = .connected
            case .disconnecting:
                peerConnection?.state = .disconnecting
            case .disconnected:
                peerConnection?.state = .disconnected
            default:
                peerConnection?.state = .connecting
            }
        }
    }
    
    var webSocket: SRWebSocket?
    var nativePeerConnection: RTCPeerConnection?
    
    // 内容はそれぞれ SRWebSocket, RTCPeerConnection のプロパティと同じだが、
    // こちらはデリゲートの呼び出し時にセットする。
    // SRWebSocket, RTCPeerConnection の状態に関するプロパティは
    // デリゲートの呼び出し前に変更されるので、
    // プロパティの監視で接続解除を判断すると終了処理を適切に行えない
    var webSocketReadyState: SRReadyState?
    var nativeSignalingState: RTCSignalingState?
    var nativeICEConnectionState: RTCIceConnectionState?
    
    var upstream: RTCMediaStream?
    var mediaCapturer: MediaCapturer?
    var monitor: ConnectionMonitor?
    
    var connection: Connection! {
        get { return peerConnection?.connection }
    }
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    var mediaConnection: MediaConnection! {
        get { return peerConnection?.mediaConnection }
    }
    
    private var timeoutTimer: Timer?
    
    private var connectCompletionHandler: ((ConnectionError?) -> Void)?
    private var disconnectCompletionHandler: ((ConnectionError?) -> Void)?
    
    init(peerConnection: PeerConnection, role: Role) {
        self.peerConnection = peerConnection
        self.role = role
        super.init()
    }
    
    // MARK: ピア接続
    
    func connect(timeout: Int, handler: @escaping ((ConnectionError?) -> Void)) {
        let URL = connection!.URL
        if state != .disconnected {
            handler(ConnectionError.connectionBusy)
            return
        } else if URL.scheme != "ws" && URL.scheme != "wss" {
            handler(ConnectionError.invalidProtocol)
            return
        }
        
        eventLog?.markFormat(type: .WebSocket,
                             format: String(format: "open %@", URL.description))
        state = .signalingConnecting
        connectCompletionHandler = handler

        monitor = ConnectionMonitor(context: self, timeout: timeout) { error in
            self.finishTermination(error: error)
        }
        monitor!.run()
        webSocket = SRWebSocket(url: URL)
        webSocket!.delegate = self
        webSocket!.open()
        webSocketReadyState = SRReadyState.CONNECTING
    }
    
    func disconnect(handler: @escaping ((ConnectionError?) -> Void)) {
        switch state {
        case .disconnected, .terminated:
            handler(ConnectionError.connectionDisconnected)
        case .disconnecting:
            handler(ConnectionError.connectionBusy)
        default:
            disconnectCompletionHandler = handler
            terminate()
        }
    }

    // MARK: 終了処理
    
    func terminate(error: ConnectionError? = nil) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            eventLog?.markFormat(type: .Signaling,
                                 format: "begin terminate all connections")
            state = .disconnecting
            nativePeerConnection?.close()
            webSocket?.close()
            monitor!.terminate(error: error)
        }
    }
    
    func terminateByPeerConnection(error: Error) {
        peerConnectionEventHandlers?
            .onFailureHandler?(nativePeerConnection!, error)
        terminate(error: ConnectionError.peerConnectionError(error))
    }
    
    func finishTermination(error: ConnectionError?) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "finish termination")
        
        monitor = nil
        if nativePeerConnection != nil {
            peerConnectionEventHandlers?.onDisconnectHandler?(nativePeerConnection!)
        }
        
        // この順にクリアしないと落ちる
        mediaCapturer = nil
        if nativePeerConnection != nil {
            nativePeerConnection!.delegate = nil
        }
        nativePeerConnection = nil
        webSocket?.delegate = nil
        webSocket = nil
        
        state = .disconnected
        if let error = error {
            signalingEventHandlers?.onFailureHandler?(error)
            mediaConnection?.callOnFailureHandler(error)
        }
        signalingEventHandlers?.onDisconnectHandler?()
        if let handler = connectCompletionHandler {
            handler(error ?? .connectionCancelled)
            connectCompletionHandler = nil
        }
        disconnectCompletionHandler?(error)
        disconnectCompletionHandler = nil
        mediaConnection?.callOnDisconnectHandler(error)
        peerConnection?.terminate()
        peerConnection = nil
        
        webSocketReadyState = nil
        nativeSignalingState = nil
        nativeICEConnectionState = nil
    }

    func send(_ message: Messageable) -> ConnectionError? {
        switch state {
        case .disconnected, .terminated:
            eventLog?.markFormat(type: .WebSocket,
                                 format: "failed sending message (connection disconnected)")
            return ConnectionError.connectionDisconnected
            
        case .signalingConnecting, .disconnecting:
            eventLog?.markFormat(type: .WebSocket,
                                 format: "failed sending message (connection busy)")
            return ConnectionError.connectionBusy
            
        default:
            let message = message.message()
            eventLog?.markFormat(type: .WebSocket,
                                 format: "send message (state %@): %@",
                                 arguments: state.rawValue, message.description)
            let s = message.JSONRepresentation()
            eventLog?.markFormat(type: .WebSocket,
                                 format: "send message as JSON: %@",
                                 arguments: s)
            webSocket!.send(message.JSONRepresentation())
            return nil
        }
    }
    
    // MARK: SRWebSocketDelegate
    
    var webSocketEventHandlers: WebSocketEventHandlers? {
        get { return mediaConnection?.webSocketEventHandlers }
    }
    
    var signalingEventHandlers: SignalingEventHandlers? {
        get { return mediaConnection?.signalingEventHandlers }
    }
    
    var peerConnectionEventHandlers: PeerConnectionEventHandlers? {
        get { return mediaConnection?.peerConnectionEventHandlers }
    }
    
    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        eventLog?.markFormat(type: .WebSocket, format: "opened")
        eventLog?.markFormat(type: .Signaling, format: "connected")
        webSocketEventHandlers?.onOpenHandler?(webSocket)

        webSocketReadyState = SRReadyState.OPEN
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break

        case .signalingConnecting:
            state = .signalingConnected
            signalingEventHandlers?.onConnectHandler?()
            
            // ピア接続オブジェクトを生成する
            eventLog?.markFormat(type: .PeerConnection,
                                 format: "create peer connection")
            nativePeerConnection = PeerConnection.nativeFactory
                .peerConnection(
                    with: peerConnection!.mediaOption.configuration,
                    constraints: peerConnection!.mediaOption
                        .peerConnectionMediaConstraints,
                    delegate: self)
            
            // デバイスの初期化 (Upstream)
            if role == Role.publisher {
                if let error = createMediaCapturer() {
                    terminate(error: error)
                    return
                }
            }
            
            // シグナリング connect を送信する
            let connect = SignalingConnect(role: role,
                                           channel_id: connection.mediaChannelId,
                                           multistream: mediaConnection.multistreamEnabled,
                                           mediaOption: peerConnection!.mediaOption)
            eventLog?.markFormat(type: .Signaling,
                                 format: "send connect message: %@",
                                 arguments: connect.message().JSON().description)
            if let error = send(connect) {
                eventLog?.markFormat(type: .Signaling,
                                     format: "send connect message failed: %@",
                                     arguments: error.description)
                signalingEventHandlers?.onFailureHandler?(error)
                terminate(error: ConnectionError.connectionTerminated)
                return
            }
            state = .peerConnectionReady
            
        default:
            eventLog?.markFormat(type: .Signaling,
                                 format: "WebSocket opened in invalid state")
            terminate(error: ConnectionError.connectionTerminated)
        }
    }
    
    // 同一の RTCPeerConnectionFactory に対して MediaCapturer を再利用する
    // MediaCapturer を複数回生成すると落ちる可能性がある
    static var sharedMediaCapturers: [RTCPeerConnectionFactory: MediaCapturer] = [:]
    
    func createMediaCapturer() -> ConnectionError? {
        eventLog?.markFormat(type: .PeerConnection, format: "create media capturer")
        if let shared = PeerConnectionContext
            .sharedMediaCapturers[PeerConnection.nativeFactory] {
            eventLog?.markFormat(type: .PeerConnection,
                                 format: "use shared media capturer")
            mediaCapturer = shared
        } else {
            mediaCapturer = MediaCapturer(
                factory: PeerConnection.nativeFactory,
                mediaOption: peerConnection!.mediaOption)
            if mediaCapturer == nil {
                eventLog?.markFormat(type: .PeerConnection,
                                     format: "create media capturer failed")
                return ConnectionError.mediaCapturerFailed
            }
            PeerConnectionContext
                .sharedMediaCapturers[PeerConnection.nativeFactory] = mediaCapturer
        }
        
        eventLog?.markFormat(type: .PeerConnection,
                             format: "video capturer track ID: %@",
                             arguments: mediaCapturer!.videoCaptureTrack.trackId)
        eventLog?.markFormat(type: .PeerConnection,
                             format: "audio capturer track ID: %@",
                             arguments: mediaCapturer!.audioCaptureTrack.trackId)
        
        let upstream = PeerConnection.nativeFactory.mediaStream(withStreamId:
            peerConnection!.mediaStreamId ?? MediaStream.defaultStreamId)
        if peerConnection!.mediaOption.videoEnabled {
            upstream.addVideoTrack(mediaCapturer!.videoCaptureTrack)
        }
        if peerConnection!.mediaOption.audioEnabled {
            upstream.addAudioTrack(mediaCapturer!.audioCaptureTrack)
        }
        
        nativePeerConnection!.add(upstream)
        let wrap = MediaStream(peerConnection: peerConnection!,
                               nativeMediaStream: upstream)
        mediaConnection?.addMediaStream(wrap)
        return nil
    }
    
    public func webSocket(_ webSocket: SRWebSocket!,
                          didCloseWithCode code: Int,
                          reason: String?,
                          wasClean: Bool) {
        webSocketReadyState = SRReadyState.CLOSED
        webSocketEventHandlers?.onCloseHandler?(webSocket, code, reason, wasClean)

        if let reason = reason {
            eventLog?.markFormat(type: .WebSocket,
                                 format: "close: code \(code), reason %@, clean \(wasClean)",
                arguments: reason)
        } else {
            eventLog?.markFormat(type: .WebSocket,
                                 format: "close: code \(code), clean \(wasClean)")
        }
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            var error: ConnectionError? = nil
            if code != SRStatusCodeNormal.rawValue {
                if code == StatusCode.signalingFailure.rawValue {
                    let reason = reason ?? "Unknown reason"
                    error = ConnectionError.signalingFailure(reason: reason)
                } else {
                    error = ConnectionError.webSocketClose(code, reason)
                }
            }
            
            terminate(error: error)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "fail: %@",
                             arguments: error.localizedDescription)
        let error = ConnectionError.webSocketError(error)
        webSocketEventHandlers?.onFailureHandler?(webSocket, error)
        
        webSocketReadyState = SRReadyState.CLOSED
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            terminate(error: error)
        }
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceivePong pongPayload: Data!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "received pong: %@",
                             arguments: pongPayload.description)
        webSocketEventHandlers?.onPongHandler?(webSocket, pongPayload)
    }
    
    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        eventLog?.markFormat(type: .WebSocket,
                             format: "received message: %@",
                             arguments: (message as AnyObject).description)
        webSocketEventHandlers?.onMessageHandler?(webSocket, message as AnyObject)

        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            if let message = Message.fromJSONData(message) {
                signalingEventHandlers?.onReceiveHandler?(message)
                eventLog?.markFormat(type: .Signaling,
                                     format: "signaling message type: %@",
                                     arguments: message.type?.rawValue ??  "<unknown>")
                
                let json = message.JSON()
                switch message.type {
                case .ping?:
                    receiveSignalingPing()
                    
                case .notify?:
                    receiveSignalingNotify(json: json)
                    
                case .offer?:
                    receiveSignalingOffer(json: json)
                    
                case .update?:
                    receiveSignalingUpdate(json)
                    
                case .snapshot?:
                    receiveSignalingSnapshot(json: json)
                    
                default:
                    return
                }
            }
        }
    }
    
    func receiveSignalingPing() {
        eventLog?.markFormat(type: .Signaling, format: "received ping")
        
        switch state {
        case .connected:
            signalingEventHandlers?.onPingHandler?()
            if let error = self.send(SignalingPong()) {
                mediaConnection?.callOnFailureHandler(error)
            }
            
        default:
            break
        }
    }
    
    func receiveSignalingNotify(json: [String: Any]) {
        switch state {
        case .connected:
            eventLog?.markFormat(type: .Signaling, format: "received notify")
            
            var notify: SignalingNotify!
            do {
                notify = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Signaling,
                                     format: "failed parsing notify: %@",
                                     arguments: json.description)
            }
            eventLog?.markFormat(type: .Signaling,
                                 format: "notify: %@",
                                 arguments: json.description)

            signalingEventHandlers?.onNotifyHandler?(notify)
            let nums = (notify.numberOfPublishers,
                        notify.numberOfSubscribers)
            mediaConnection!.numberOfConnections = nums
            let attendee = Attendee(role: notify.role,
                                    numberOfPublishers: notify.numberOfPublishers,
                                    numberOfSubscribers: notify.numberOfSubscribers)
            
            switch notify.eventType {
            case .connectionCreated:
                mediaConnection!.onAttendeeAddedHandler?(attendee)
            case .connectionDestroyed:
                mediaConnection!.onAttendeeRemovedHandler?(attendee)
            default:
                break
            }
            
        default:
            break
        }
    }
    
    func receiveSignalingOffer(json: [String: Any]) {
        switch state {
        case .peerConnectionReady:
            eventLog?.markFormat(type: .Signaling, format: "received offer")
            let offer: SignalingOffer!
            do {
                offer = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Signaling,
                                     format: "parsing offer failed")
                return
            }
            
            peerConnection!.clientId = offer.client_id
            
            if let config = offer.config {
                eventLog?.markFormat(type: .Signaling,
                                     format: "configure ICE transport policy")
                let peerConfig = RTCConfiguration()
                switch config.iceTransportPolicy {
                case "relay":
                    peerConfig.iceTransportPolicy = .relay
                default:
                    eventLog?.markFormat(type: .Signaling,
                                         format: "unsupported iceTransportPolicy %@",
                                         arguments: config.iceTransportPolicy)
                    return
                }
                
                eventLog?.markFormat(type: .Signaling, format: "configure ICE servers")
                for serverConfig in config.iceServers {
                    let server = RTCIceServer(urlStrings: serverConfig.urls,
                                              username: serverConfig.username,
                                              credential: serverConfig.credential)
                    peerConfig.iceServers = [server]
                }
                
                if !nativePeerConnection!.setConfiguration(peerConfig) {
                    eventLog?.markFormat(type: .Signaling,
                                         format: "cannot configure peer connection")
                    terminate(error: ConnectionError
                        .failureSetConfiguration(peerConfig))
                    return
                }
            }
            
            createAndSendAnswer(sdp: offer.sessionDescription())
            
        default:
            eventLog?.markFormat(type: .Signaling,
                                 format: "offer: invalid state %@",
                                 arguments: state.rawValue)
            terminate(error: ConnectionError.connectionTerminated)
        }
    }
    
    func createAndSendAnswer(sdp: RTCSessionDescription) {
        state = .peerConnectionOffered
        eventLog?.markFormat(type: .Signaling,
                             format: "set remote description")
        nativePeerConnection!.setRemoteDescription(sdp) {
            error in
            if let error = error {
                self.eventLog?.markFormat(type: .Signaling,
                                          format: "set remote description failed")
                self.terminateByPeerConnection(error: error)
                return
            }
            
            self.eventLog?.markFormat(type: .Signaling,
                                      format: "create answer")
            self.nativePeerConnection!.answer(for: self
                .peerConnection!.mediaOption.signalingAnswerMediaConstraints)
            {
                (sdp, error) in
                if let error = error {
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "creating answer failed")
                    self.terminateByPeerConnection(error: error)
                    return
                }
                self.eventLog?.markFormat(type: .Signaling,
                                          format: "generated answer: %@",
                                          arguments: sdp!)
                self.nativePeerConnection!.setLocalDescription(sdp!) {
                    error in
                    if let error = error {
                        self.eventLog?.markFormat(type: .Signaling,
                                                  format: "set local description failed")
                        self.peerConnectionEventHandlers?
                            .onFailureHandler?(self.nativePeerConnection!, error)
                        self.terminate(error: ConnectionError.peerConnectionError(error))
                        return
                    }
                    
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "send answer")
                    let answer = SignalingAnswer(sdp: sdp!.sdp).message()
                    if let error = self.send(answer) {
                        self.terminate(error: ConnectionError.peerConnectionError(error))
                        return
                    }
                    
                    self.state = .peerConnectionAnswered
                }
            }
        }
    }
    
    func receiveSignalingUpdate(_ json: [String: Any]) {
        switch state {
        case .connected:
            eventLog?.markFormat(type: .Signaling, format: "received 'update'",
                                 arguments: json.description)
            if !mediaConnection.multistreamEnabled {
                eventLog?.markFormat(type: .Signaling,
                                     format: "ignore 'update' in single stream mode")
                return
            }
            
            let update: SignalingUpdateOffer!
            do {
                update = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Signaling,
                                     format: "parsing 'update' failed")
                return
            }
            
            createAndSendUpdateAnswer(sdp: update.sessionDescription())
            
        default:
            return
        }
    }
    
    
    func createAndSendUpdateAnswer(sdp: RTCSessionDescription) {
        state = .updateOffered
        eventLog?.markFormat(type: .Signaling,
                             format: "set remote description to update-offer")
        nativePeerConnection!.setRemoteDescription(sdp) {
            error in
            if let error = error {
                self.eventLog?.markFormat(type: .Signaling,
                                          format: "set remote description to update-offer failed")
                self.terminateUpdate(error)
                return
            }
            
            self.eventLog?.markFormat(type: .Signaling,
                                      format: "create update-answer")
            self.nativePeerConnection!.answer(for: self
                .peerConnection!.mediaOption.signalingAnswerMediaConstraints)
            {
                (sdp, error) in
                if let error = error {
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "creating update-answer failed")
                    self.terminateUpdate(error)
                    return
                }
                self.eventLog?.markFormat(type: .Signaling,
                                          format: "generated update-answer: %@",
                                          arguments: sdp!)
                self.nativePeerConnection!.setLocalDescription(sdp!) {
                    error in
                    if let error = error {
                        self.eventLog?.markFormat(type: .Signaling,
                                                  format: "set local description to update-answer failed")
                        self.terminateUpdate(error)
                        return
                    }
                    
                    self.eventLog?.markFormat(type: .Signaling,
                                              format: "send update-answer")
                    let answer: Message!
                    answer = SignalingUpdateAnswer(sdp: sdp!.sdp).message()
                    if let error = self.send(answer) {
                        self.terminateUpdate(error)
                        return
                    }
                    
                    // Answer 送信後に RTCPeerConnection の状態に変化はない
                    // (デリゲートのメソッドが呼ばれない) ため、
                    // Answer を送信したら接続完了とみなす
                    self.state = .connected
                }
            }
        }
    }
    
    func receiveSignalingSnapshot(json: [String: Any]) {
        eventLog?.markFormat(type: .Signaling, format: "received 'snapshot'")
        guard peerConnection?.mediaConnection?.mediaOption.snapshotEnabled ?? false else {
            eventLog?.markFormat(type: .Snapshot,
                                 format: "snapshot disabled")
            return
        }
        
        switch state {
        case .connected:
            let sigSnapshot: SignalingSnapshot!
            do {
                sigSnapshot = Optional.some(try unbox(dictionary: json))
            } catch {
                eventLog?.markFormat(type: .Snapshot,
                                     format: "parsing 'snapshot' failed")
                return
            }
            guard connection.mediaChannelId == sigSnapshot.mediaChannelId else {
                eventLog?.markFormat(type: .Snapshot,
                                     format: "unknown media channel ID: %@",
                                     arguments: sigSnapshot.mediaChannelId)
                return
            }
            
            eventLog?.markFormat(type: .Snapshot,
                                 format: "try decode snapshot base64 encoded text")
            signalingEventHandlers?.onSnapshotHandler?(sigSnapshot)
            
            guard let data = Data(base64Encoded: sigSnapshot.base64EncodedString) else {
                eventLog?.markFormat(type: .Snapshot,
                                     format: "invalid snapshot base64 format")
                return
            }
            guard let image = UIImage.sd_image(with: data) else {
                eventLog?.markFormat(type: .Snapshot,
                                     format: "snapshot WebP decode failed")
                return
            }
            let snapshot = Snapshot(image: image.cgImage!, timestamp: Date())
            mediaConnection.render(snapshot: snapshot)
            
        default:
            return
        }
    }
        // マルチストリームのシグナリングのエラー
    func terminateUpdate(_ error: Error) {
        state = .connected
        let connError = ConnectionError.peerConnectionError(error)
        let updateError = ConnectionError.updateError(connError)
        peerConnectionEventHandlers?
            .onFailureHandler?(nativePeerConnection!, updateError)
        mediaConnection?.callOnFailureHandler(updateError)
    }
    
    // MARK: RTCPeerConnectionDelegate
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "signaling state changed: %@",
                             arguments: stateChanged.description)
        
        nativeSignalingState = stateChanged
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?.onChangeSignalingStateHandler?(
                nativePeerConnection, stateChanged)
            switch stateChanged {
            case .closed:
                terminate(error: ConnectionError.connectionTerminated)
            default:
                break
            }
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "added stream '%@'",
                             arguments: stream.streamId)
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            guard peerConnection != nil
                && peerConnection!.mediaConnection != nil else
            {
                return
            }
            
            if peerConnection!.mediaConnection!.hasMediaStream(stream.streamId) {
                eventLog?.markFormat(type: .PeerConnection,
                                     format: "stream '%@' already exists",
                                     arguments: stream.streamId)
                return
            }
            
            peerConnectionEventHandlers?.onAddStreamHandler?(nativePeerConnection, stream)
            nativePeerConnection.add(stream)
            let wrap = MediaStream(peerConnection: peerConnection!,
                                   nativeMediaStream: stream)
            peerConnection!.mediaConnection!.addMediaStream(wrap)
            
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        eventLog?.markFormat(type: .PeerConnection, format: "removed stream")
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?
                .onRemoveStreamHandler?(nativePeerConnection, stream)
            nativePeerConnection.remove(stream)
            peerConnection?.mediaConnection?.removeMediaStream(stream.streamId)
        }
    }
    
    func peerConnectionShouldNegotiate(_ nativePeerConnection: RTCPeerConnection) {
        eventLog?.markFormat(type: .PeerConnection, format: "should negatiate")
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break

        default:
            peerConnectionEventHandlers?.onNegotiateHandler?(nativePeerConnection)
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "ICE connection state changed: %@",
                             arguments: newState.description)
        
        nativeICEConnectionState = newState
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?
                .onChangeIceConnectionState?(nativePeerConnection, newState)
            switch newState {
            case .connected:
                switch state {
                case .peerConnectionAnswered:
                    eventLog?.markFormat(type: .PeerConnection,
                                         format: "remote peer connected",
                                         arguments: newState.description)
                    finishConnection()
                    
                default:
                    eventLog?.markFormat(type: .PeerConnection,
                                         format: "ICE connection completed but invalid state %@",
                                         arguments: newState.description)
                    terminate(error: ConnectionError.iceConnectionFailed)
                }
                
            case .closed, .disconnected:
                terminate(error: ConnectionError.iceConnectionDisconnected)
                
            case .failed:
                let error = ConnectionError.iceConnectionFailed
                mediaConnection?.callOnFailureHandler(error)
                terminate(error: error)
                
            default:
                break
            }
        }
    }
    
    func finishConnection() {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "finish connection")
        
        if mediaConnection!.mediaStreams.isEmpty {
            eventLog?.markFormat(type: .PeerConnection,
                                 format: "media stream is not found")
            terminate(error: .mediaStreamNotFound)
            return
        }
        
        monitor!.completeConnection()
        state = .connected
        if nativePeerConnection != nil {
            peerConnectionEventHandlers?.onConnectHandler?(nativePeerConnection!)
        }
        connectCompletionHandler?(nil)
        connectCompletionHandler = nil
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "ICE gathering state changed: %@",
                             arguments: newState.description)
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?
                .onChangeIceGatheringStateHandler?(nativePeerConnection, newState)
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "candidate generated: %@",
                             arguments: candidate.sdp)
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?
                .onGenerateIceCandidateHandler?(nativePeerConnection, candidate)
            if let error = send(SignalingICECandidate(candidate: candidate.sdp)) {
                eventLog?.markFormat(type: .PeerConnection,
                                     format: "send candidate to server failed")
                terminate(error: error)
            }
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
        eventLog?.markFormat(type: .PeerConnection,
                             format: "candidates %d removed",
                             arguments: candidates.count)
        
        switch state {
        case .disconnecting, .disconnected, .terminated:
            break
            
        default:
            peerConnectionEventHandlers?
                .onRemoveCandidatesHandler?(nativePeerConnection, candidates)
        }
    }
    
    // NOTE: Sora はデータチャネルに非対応
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        eventLog?.markFormat(type: .PeerConnection,
                             format:
            "data channel opened (Sora does not support data channels")
    }
    
}
