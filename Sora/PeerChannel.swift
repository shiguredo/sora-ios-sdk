import Foundation
import WebRTC

private let peerChannelSignalingStateTable: PairTable<PeerChannelSignalingState, RTCSignalingState> =
    PairTable(pairs: [(.stable, .stable),
                      (.haveLocalOffer, .haveLocalOffer),
                      (.haveLocalPrAnswer, .haveLocalPrAnswer),
                      (.haveRemoteOffer, .haveRemoteOffer),
                      (.haveRemotePrAnswer, .haveRemotePrAnswer),
                      (.closed, .closed)])

private let iceConnectionStateTable: PairTable<ICEConnectionState, RTCIceConnectionState> =
    PairTable(pairs: [(.new, .new),
                      (.checking, .checking),
                      (.connected, .connected),
                      (.completed, .completed),
                      (.failed, .failed),
                      (.disconnected, .disconnected),
                      (.closed, .closed),
                      (.count, .count)])

private let iceGatheringStateTable: PairTable<ICEGatheringState, RTCIceGatheringState> =
    PairTable(pairs: [(.new, .new),
                      (.gathering, .gathering),
                      (.complete, .complete)])

enum PeerChannelSignalingState {
    
    case stable
    case haveLocalOffer
    case haveLocalPrAnswer
    case haveRemoteOffer
    case haveRemotePrAnswer
    case closed
    
    init(nativeValue: RTCSignalingState) {
        self = peerChannelSignalingStateTable.left(other: nativeValue)!
    }
    
}

enum ICEConnectionState {
    
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed
    case count
    
    init(nativeValue: RTCIceConnectionState) {
        self = iceConnectionStateTable.left(other: nativeValue)!
    }
    
}

enum ICEGatheringState {
    
    case new
    case gathering
    case complete
    
    init(nativeValue: RTCIceGatheringState) {
        self = iceGatheringStateTable.left(other: nativeValue)!
    }
    
}

class PeerChannelInternalState {
    
    var signalingState: PeerChannelSignalingState {
        didSet { validate() }
    }
    
    var iceConnectionState: ICEConnectionState {
        didSet { validate() }
    }
    
    var iceGatheringState: ICEGatheringState {
        didSet { validate() }
    }
    
    private var isConnected: Bool = false
    
    private var isCompleted: Bool {
        get {
            switch (signalingState, iceConnectionState, iceGatheringState) {
            case (.stable, .connected, .complete):
                return true
            default:
                return false
            }
        }
    }
    
    var onCompleteHandler: (() -> Void)?
    var onDisconnectHandler: (() -> Void)?

    init(signalingState: PeerChannelSignalingState,
         iceConnectionState: ICEConnectionState,
         iceGatheringState: ICEGatheringState) {
        self.signalingState = signalingState
        self.iceConnectionState = iceConnectionState
        self.iceGatheringState = iceGatheringState
    }
    
    private func validate() {
        if isCompleted {
            Logger.debug(type: .peerChannel,
                         message: "peer channel state: completed")
            Logger.debug(type: .peerChannel,
                         message: "    signaling state: \(signalingState)")
            Logger.debug(type: .peerChannel,
                         message: "    ICE connection state: \(iceConnectionState)")
            Logger.debug(type: .peerChannel,
                         message: "    ICE gathering state: \(iceGatheringState)")
            
            isConnected = true
            onCompleteHandler?()
            onCompleteHandler = nil
        } else if isConnected {
            if signalingState == .closed
                || iceConnectionState == .failed
                || iceConnectionState == .disconnected
                || iceConnectionState == .closed {
                Logger.debug(type: .peerChannel,
                             message: "peer channel state: disconnected")
                Logger.debug(type: .peerChannel,
                             message: "    signaling state: \(signalingState)")
                Logger.debug(type: .peerChannel,
                             message: "    ICE connection state: \(iceConnectionState)")
                Logger.debug(type: .peerChannel,
                             message: "    ICE gathering state: \(iceGatheringState)")
                isConnected = false
                onDisconnectHandler?()
            }
        } else {
            Logger.debug(type: .peerChannel,
                         message: "peer channel state: not completed")
            Logger.debug(type: .peerChannel,
                         message: "    signaling state: \(signalingState)")
            Logger.debug(type: .peerChannel,
                         message: "    ICE connection state: \(iceConnectionState)")
            Logger.debug(type: .peerChannel,
                         message: "    ICE gathering state: \(iceGatheringState)")
        }
    }
}

/**
 ピアチャネルのイベントハンドラです。
 */
public final class PeerChannelHandlers {
    
    /// 接続解除時に呼ばれるブロック
    public var onDisconnectHandler: ((Error?) -> Void)?
    
    /// ストリームの追加時に呼ばれるブロック
    public var onAddStreamHandler: ((MediaStream) -> Void)?
    
    /// ストリームの除去時に呼ばれるブロック
    public var onRemoveStreamHandler: ((MediaStream) -> Void)?
    
    /// マルチストリームの状態の更新に呼ばれるブロック。
    /// 更新により、ストリームの追加または除去が行われます。
    public var onUpdateHandler: ((String) -> Void)?
    
    /// イベント通知の受信時に呼ばれるブロック
    public var onNotifyHandler: ((SignalingNotifyMessage) -> Void)?
    
    /// ping の受信時に呼ばれるブロック
    public var onPingHandler: (() -> Void)?
    
}

// MARK: -

/**
 ピアチャネルの機能を定義したプロトコルです。
 デフォルトの実装は非公開 (`internal`) であり、カスタマイズはイベントハンドラでのみ可能です。
 ソースコードは公開していますので、実装の詳細はそちらを参照してください。
 
 ピアチャネルは映像と音声を送受信するための接続を行います。
 サーバーへの接続を確立すると、メディアストリーム `MediaStream` を通して
 映像と音声の送受信が可能になります。
 メディアストリームはシングルストリームでは 1 つ、マルチストリームでは複数用意されます。
 */
public protocol PeerChannel: class {
    
    // MARK: - イベントハンドラ
    
    /// イベントハンドラ
    var handlers: PeerChannelHandlers { get }
    
    /**
     内部処理で使われるイベントハンドラ。
     このハンドラをカスタマイズに使うべきではありません。
     */
    var internalHandlers: PeerChannelHandlers { get }
    
    // MARK: - 接続情報
    
    /// クライアントの設定
    var configuration: Configuration { get }
    
    /// クライアント ID 。接続成立後にセットされます。
    var clientId: String? { get }
    
    /// メディアストリームのリスト。シングルストリームでは 1 つです。
    var streams: [MediaStream] { get }
    
    /// 接続状態
    var state: ConnectionState { get }
    
    /// シグナリングチャネル
    var signalingChannel: SignalingChannel { get }
    
    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter configuration: クライアントの設定
     - parameter signalingChannel: 使用するシグナリングチャネル
     */
    init(configuration: Configuration, signalingChannel: SignalingChannel)
    
    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter handler: 接続試行後に呼ばれるブロック
     - parameter error: (接続失敗時のみ) エラー
     */
    func connect(handler: @escaping (_ error: Error?) -> Void)
    
    /**
     接続を解除します。
     
     - parameter error: 接続解除の原因となったエラー
     */
    func disconnect(error: Error?)
    
}

// MARK: -

class BasicPeerChannel: PeerChannel {
    
    let handlers: PeerChannelHandlers = PeerChannelHandlers()
    let internalHandlers: PeerChannelHandlers = PeerChannelHandlers()
    let configuration: Configuration
    let signalingChannel: SignalingChannel
    
    private(set) var streams: [MediaStream] = []
    private(set) var iceCandidates: [ICECandidate] = []
    
    var clientId: String? {
        get { return context.clientId }
    }
    
    var state: ConnectionState {
        get {
            switch context.state {
            case .disconnecting:
                return .disconnecting
            case .disconnected:
                return .disconnected
            case .connected:
                return .connected
            default:
                return .connecting
            }
        }
    }
    
    private var context: BasicPeerChannelContext!
    
    required init(configuration: Configuration, signalingChannel: SignalingChannel) {
        self.configuration = configuration
        self.signalingChannel = signalingChannel
        context = BasicPeerChannelContext(channel: self)
    }
    
    func add(stream: MediaStream) {
        streams.append(stream)
        Logger.debug(type: .peerChannel, message: "call onAddStreamHandler")
        internalHandlers.onAddStreamHandler?(stream)
        handlers.onAddStreamHandler?(stream)
    }
    
    func remove(streamId: String) {
        let stream = streams.first { stream in stream.streamId == streamId }
        if let stream = stream {
            remove(stream: stream)
        }
    }
    
    func remove(stream: MediaStream) {
        streams = streams.filter { each in each.streamId != stream.streamId }
        Logger.debug(type: .peerChannel, message: "call onRemoveStreamHandler")
        internalHandlers.onRemoveStreamHandler?(stream)
        handlers.onRemoveStreamHandler?(stream)
    }
    
    func add(iceCandidate: ICECandidate) {
        iceCandidates.append(iceCandidate)
    }
    
    func remove(iceCandidate: ICECandidate) {
        iceCandidates = iceCandidates.filter { each in each == iceCandidate }
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        context.connect(handler: handler)
    }
    
    func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    fileprivate func terminateAllStreams() {
        for stream in streams {
            stream.terminate()
        }
        streams.removeAll()
        // Do not call `handlers.onRemoveStreamHandler` here
        // This method is meant to be called only when disconnection cleanup
    }
    
}

// MARK: -

class BasicPeerChannelContext: NSObject, RTCPeerConnectionDelegate {
    
    enum State {
        case connecting
        case waitingOffer
        case waitingComplete
        case waitingUpdateComplete
        case connected
        case disconnecting
        case disconnected
    }
    
    weak var channel: BasicPeerChannel!
    var state: State = .disconnected
    var nativeChannel: RTCPeerConnection!
    var internalState: PeerChannelInternalState!
    
    var signalingChannel: SignalingChannel {
        get { return channel.signalingChannel }
    }
    
    var webRTCConfiguration: WebRTCConfiguration!
    var clientId: String?
    
    var configuration: Configuration {
        get { return channel.configuration }
    }
    
    var onConnectHandler: ((Error?) -> Void)?
    
    init(channel: BasicPeerChannel) {
        self.channel = channel
        super.init()
        
        signalingChannel.internalHandlers.onDisconnectHandler = { error in
            self.disconnect(error: error)
        }
        
        signalingChannel.internalHandlers.onMessageHandler = handleMessage
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        if channel.state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "PeerChannel is already connected"))
            return
        }
        
        Logger.debug(type: .peerChannel, message: "try connecting")
        Logger.debug(type: .peerChannel, message: "try connecting to signaling channel")
        
        onConnectHandler = handler
        self.webRTCConfiguration = channel.configuration.webRTCConfiguration
        nativeChannel = NativePeerChannelFactory.default
            .createNativePeerChannel(configuration: webRTCConfiguration,
                                     constraints: webRTCConfiguration.constraints,
                                     delegate: self)
        internalState = PeerChannelInternalState(
            signalingState: PeerChannelSignalingState(
                nativeValue: nativeChannel.signalingState),
            iceConnectionState: ICEConnectionState(
                nativeValue: nativeChannel.iceConnectionState),
            iceGatheringState: ICEGatheringState(
                nativeValue: nativeChannel.iceGatheringState))
        internalState.onCompleteHandler = finishConnecting
        
        internalState.onDisconnectHandler = {
            self.disconnect(error: nil)
        }
        
        signalingChannel.connect(handler: sendConnectMessage)
        state = .connecting
    }
    
    func sendConnectMessage(error: Error?) {
        Logger.debug(type: .peerChannel, message: "try creating offer SDP")
        NativePeerChannelFactory.default
            .createClientOfferSDP(configuration: webRTCConfiguration,
                                  constraints: webRTCConfiguration.constraints)
            { sdp, sdpError in
                if let error = sdpError {
                    Logger.debug(type: .peerChannel,
                                 message: "failed to create offer SDP (\(error.localizedDescription))")
                } else {
                    Logger.debug(type: .peerChannel,
                                 message: "did create offer SDP")
                }
                self.sendConnectMessage(with: sdp, error: error)
        }
    }
    
    func sendConnectMessage(with sdp: String?, error: Error?) {
        if error != nil {
            Logger.error(type: .peerChannel,
                         message: "failed connecting to signaling channel (\(error!.localizedDescription))")
            disconnect(error: SoraError.peerChannelError(
                reason: "failed connecting to signaling channel"))
            return
        }
        
        Logger.debug(type: .peerChannel,
                     message: "did connect to signaling channel")
        
        state = .waitingOffer
        var role: SignalingRole!
        var multistream = false
        switch configuration.role {
        case .publisher:
            role = .upstream
            initializePublisherStream()
        case .subscriber:
            role = .downstream
        case .group:
            role = .upstream
            multistream = true
            initializePublisherStream()
        case .groupSub:
            role = .downstream
            multistream = true
        }
        
        let connect =
            SignalingConnectMessage(role: role,
                                    channelId: configuration.channelId,
                                    metadata: configuration.metadata,
                                    sdp: sdp,
                                    multistreamEnabled: multistream,
                                    videoEnabled: configuration.videoEnabled,
                                    videoCodec: configuration.videoCodec,
                                    videoBitRate: configuration.videoBitRate,
                                    // WARN: video only では answer 生成に失敗するため、
                                    // 音声トラックを使用しない方法で回避する
                                    // audioEnabled: config.audioEnabled,
                                    audioEnabled: true,
                                    audioCodec: configuration.audioCodec,
                                    maxNumberOfSpeakers: configuration.maxNumberOfSpeakers)
        let message = SignalingMessage.connect(message: connect)
        Logger.debug(type: .peerChannel, message: "send connect")
        signalingChannel.send(message: message)
    }
    
    func initializePublisherStream() {
        let nativeStream = NativePeerChannelFactory.default
            .createNativePublisherStream(streamId: configuration.publisherStreamId,
                                         videoTrackId:
                configuration.videoEnabled ? configuration.publisherVideoTrackId: nil,
                                         audioTrackId:
                configuration.audioEnabled ? configuration.publisherAudioTrackId : nil,
                                         constraints: webRTCConfiguration.constraints)
        let stream = BasicMediaStream(peerChannel: channel,
                                      nativeStream: nativeStream)
        if configuration.videoEnabled {
            switch configuration.videoCapturerDevice {
            case .camera(let settings):
                // カメラが指定されている場合は、接続処理と同時にデフォルトのCameraVideoCapturerを使用してキャプチャを開始する
                if CameraVideoCapturer.shared.isRunning {
                    CameraVideoCapturer.shared.stop()
                }
                CameraVideoCapturer.shared.settings = settings
                CameraVideoCapturer.shared.start()
                stream.videoCapturer = CameraVideoCapturer.shared
            case .custom:
                // カスタムが指定されている場合は、接続処理時には何もしない
                // 完全にユーザーサイドにVideoCapturerの設定とマネジメントを任せる
                break
            }
        }
        
        nativeChannel.add(stream.nativeVideoTrack!,
                          streamLabels: [stream.nativeStream.streamId])
        nativeChannel.add(stream.nativeAudioTrack!,
                          streamLabels: [stream.nativeStream.streamId])
        channel.add(stream: stream)
        Logger.debug(type: .peerChannel,
                     message: "create publisher stream (id: \(configuration.publisherStreamId))")
    }
    
    /** `initializePublisherStream()` にて生成されたリソースを開放するための、対になるメソッドです。 */
    func terminatePublisherStream() {
        if configuration.videoEnabled {
            switch configuration.videoCapturerDevice {
            case .camera(settings: let settings):
                // カメラが指定されている場合は
                // 接続時に自動的に開始したキャプチャを、切断時に自動的に停止する必要がある
                if settings.canStop {
                    CameraVideoCapturer.shared.stop()
                }
            case .custom:
                // カスタムが指定されている場合は、切断処理時には何もしない
                // 完全にユーザーサイドにVideoCapturerの設定とマネジメントを任せる
                break
            }
        }
    }
    
    func createAndSendAnswerMessage(offer: SignalingOfferMessage) {
        Logger.debug(type: .peerChannel, message: "try sending answer")
        state = .waitingComplete
        
        if let config = offer.configuration {
            Logger.debug(type: .peerChannel, message: "update configuration")
            Logger.debug(type: .peerChannel, message: config.description)
            webRTCConfiguration.iceServerInfos = config.iceServerInfos
            webRTCConfiguration.iceTransportPolicy = config.iceTransportPolicy
            nativeChannel.setConfiguration(webRTCConfiguration.nativeValue)
        }
        
        nativeChannel.createAnswer(forOffer: offer.sdp,
                                   constraints: webRTCConfiguration.nativeConstraints)
        { sdp, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create answer (\(error!.localizedDescription))")
                self.disconnect(error: SoraError
                    .peerChannelError(reason: "failed to create answer"))
                return
            }
            
            let answer = SignalingMessage.answer(sdp: sdp!)
            self.signalingChannel.send(message: answer)
            Logger.debug(type: .peerChannel, message: "did send answer")
        }
    }
    
    
    func createAndSendUpdateAnswerMessage(forOffer offer: String) {
        state = .waitingUpdateComplete
        nativeChannel.createAnswer(forOffer: offer,
                                   constraints: webRTCConfiguration.nativeConstraints)
        { answer, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create update-answer (\(error!.localizedDescription)")
                self.disconnect(error: SoraError
                    .peerChannelError(reason: "failed to create update-answer"))
                return
            }
            
            let message = SignalingMessage.update(sdp: answer!)
            self.signalingChannel.send(message: message)
            
            // Answer 送信後に RTCPeerConnection の状態に変化はないため、
            // Answer を送信したら更新完了とする
            self.state = .connected
            
            Logger.debug(type: .peerChannel, message: "call onUpdateHandler")
            self.channel.internalHandlers.onUpdateHandler?(answer!)
            self.channel.handlers.onUpdateHandler?(answer!)
        }
    }
    
    func handleMessage(_ message: SignalingMessage?, _ text: String) {
        Logger.debug(type: .mediaStream, message: "handle message")
        guard let message = message else {
            return
        }
        switch state {
        case .waitingOffer:
            switch message {
            case .offer(let offer):
                Logger.debug(type: .peerChannel, message: "receive offer")
                clientId = offer.clientId
                createAndSendAnswerMessage(offer: offer)
                
            default:
                // discard
                break
            }
            
        case .connected:
            switch message {
            case .update(sdp: let sdp):
                guard configuration.role == .group ||
                    configuration.role == .groupSub else { return }
                Logger.debug(type: .peerChannel, message: "receive update")
                createAndSendUpdateAnswerMessage(forOffer: sdp)

            case .notify(message: let message):
                Logger.debug(type: .peerChannel, message: "receive notify")
                Logger.debug(type: .peerChannel, message: "call onNotifyHandler")
                channel.internalHandlers.onNotifyHandler?(message)
                channel.handlers.onNotifyHandler?(message)
                
            case .ping:
                Logger.debug(type: .peerChannel, message: "receive ping")
                signalingChannel.send(message: .pong)
                Logger.debug(type: .peerChannel, message: "call onPingHandler")
                channel.internalHandlers.onPingHandler?()
                channel.handlers.onPingHandler?()
                
            default:
                // discard
                break
            }
            
        default:
            // discard
            break
        }
    }
    
    func finishConnecting() {
        Logger.debug(type: .peerChannel, message: "did connect")
        Logger.debug(type: .peerChannel,
                     message: "media streams = \(channel.streams.count)")
        Logger.debug(type: .peerChannel,
                     message: "native media streams = \(nativeChannel.localStreams.count)")
        state = .connected
        
        if onConnectHandler != nil {
            Logger.debug(type: .peerChannel, message: "call connect(handler:) handler")
            onConnectHandler!(nil)
            onConnectHandler = nil
        }
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .peerChannel, message: "try disconnecting")
            if let error = error {
                Logger.error(type: .peerChannel,
                             message: "error: \(error.localizedDescription)")
            }
            
            state = .disconnecting
            
            switch configuration.role {
            case .publisher: terminatePublisherStream()
            case .subscriber, .groupSub: break
            case .group: terminatePublisherStream()
            }
            channel.terminateAllStreams()
            nativeChannel.close()
            signalingChannel.disconnect(error: error)
            state = .disconnected
            
            Logger.debug(type: .peerChannel, message: "call onDisconnectHandler")
            channel.internalHandlers.onDisconnectHandler?(error)
            channel.handlers.onDisconnectHandler?(error)

            if onConnectHandler != nil {
                Logger.debug(type: .peerChannel, message: "call connect(handler:) handler")
                onConnectHandler!(error)
                onConnectHandler = nil
            }

            Logger.debug(type: .peerChannel, message: "did disconnect")
        }
    }
    
    // MARK: - RTCPeerConnectionDelegate
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        let newState = PeerChannelSignalingState(nativeValue: stateChanged)
        Logger.debug(type: .peerChannel,
                     message: "changed signaling state to \(newState)")
        internalState.signalingState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {
        Logger.debug(type: .peerChannel,
                     message: "try add a stream (id: \(stream.streamId))")
        for cur in channel.streams {
            if cur.streamId == stream.streamId {
                Logger.debug(type: .peerChannel,
                             message: "stream already exists")
                return
            }
        }
        
        if (channel.configuration.role == .group ||
            channel.configuration.role == .groupSub) && stream.streamId == clientId {
            Logger.debug(type: .peerChannel,
                         message: "stream already exists in multistream")
            return
        }
        
        Logger.debug(type: .peerChannel, message: "add a stream")
        stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max
        
        // WARN: connect シグナリングで audio=false とすると answer の生成に失敗するため、
        // 音声トラックを使用しない方法で回避する
        if !configuration.audioEnabled {
            Logger.debug(type: .peerChannel, message: "disable audio tracks")
            let tracks = stream.audioTracks
            for track in tracks {
                track.source.volume = 0
                stream.removeAudioTrack(track)
            }
        }
        
        let stream = BasicMediaStream(peerChannel: self.channel,
                                      nativeStream: stream)
        channel.add(stream: stream)
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        Logger.debug(type: .peerChannel,
                     message: "removed a media stream (id: \(stream.streamId))")
        channel.remove(streamId: stream.streamId)
    }
    
    func peerConnectionShouldNegotiate(_ nativePeerConnection: RTCPeerConnection) {
        Logger.debug(type: .peerChannel, message: "required negatiation")
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        let newState = ICEConnectionState(nativeValue: newState)
        Logger.debug(type: .peerChannel,
                     message: "changed ICE connection state to \(newState)")
        internalState.iceConnectionState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        let newState = ICEGatheringState(nativeValue: newState)
        Logger.debug(type: .peerChannel,
                     message: "changed ICE gathering state to \(newState)")
        internalState.iceGatheringState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        Logger.debug(type: .peerChannel,
                     message: "generated ICE candidate \(candidate)")
        let candidate = ICECandidate(nativeICECandidate: candidate)
        channel.add(iceCandidate: candidate)
        let message = SignalingMessage.candidate(candidate)
        signalingChannel.send(message: message)
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
        Logger.debug(type: .peerChannel,
                     message: "removed ICE candidate \(candidates)")
        let candidates = channel.iceCandidates.filter {
            old in
            for candidate in candidates {
                let remove = ICECandidate(nativeICECandidate: candidate)
                if old == remove {
                    return true
                }
            }
            return false
        }
        for candidate in candidates {
            channel.remove(iceCandidate: candidate)
        }
    }
    
    // NOTE: Sora はデータチャネルに非対応
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        Logger.debug(type: .peerChannel, message: "opened data channel (ignored)")
        // 何もしない
    }
    
}
