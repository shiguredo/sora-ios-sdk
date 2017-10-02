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

public enum PeerChannelSignalingState {
    
    case stable
    case haveLocalOffer
    case haveLocalPrAnswer
    case haveRemoteOffer
    case haveRemotePrAnswer
    case closed
    
    public init(nativeValue: RTCSignalingState) {
        self = peerChannelSignalingStateTable.left(other: nativeValue)!
    }
    
}

public enum ICEConnectionState {
    
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed
    case count
    
    public init(nativeValue: RTCIceConnectionState) {
        self = iceConnectionStateTable.left(other: nativeValue)!
    }
    
}

public enum ICEGatheringState {
    
    case new
    case gathering
    case complete
    
    public init(nativeValue: RTCIceGatheringState) {
        self = iceGatheringStateTable.left(other: nativeValue)!
    }
    
}

public class PeerChannelInternalState {
    
    public var signalingState: PeerChannelSignalingState {
        didSet { validate() }
    }
    
    public var iceConnectionState: ICEConnectionState {
        didSet { validate() }
    }
    
    public var iceGatheringState: ICEGatheringState {
        didSet { validate() }
    }
    
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
    
    public init(signalingState: PeerChannelSignalingState,
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
            
            onCompleteHandler?()
            onCompleteHandler = nil
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

public class PeerChannelHandlers {
    
    public var onFailureHandler: ((Error) -> Void)?
    public var onAddStreamHandler: ((MediaStream) -> Void)?
    public var onRemoveStreamHandler: ((MediaStream) -> Void)?
    public var onUpdateHandler: ((String) -> Void)?
    public var onNotifyHandler: ((SignalingNotifyMessage) -> Void)?
    public var onPingHandler: (() -> Void)?
    
}

public enum PeerChannelState {
    case connecting
    case connected
    case disconnecting
    case disconnected
}

// MARK: -

public protocol PeerChannel: AliveMonitorable {
    
    var configuration: Configuration { get }
    var handlers: PeerChannelHandlers { get }
    var clientId: String? { get }
    var streams: [MediaStream] { get }
    var iceCandidates: [ICECandidate] { get }
    var state: PeerChannelState { get }
    
    init(configuration: Configuration)
    
    func connect(webRTCConfiguration: WebRTCConfiguration,
                 handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    func addStream(_ stream: MediaStream)
    func removeStream(_ stream: MediaStream)
    func addICECandidate(_ candidate: ICECandidate)
    func removeICECandidate(_ candidate: ICECandidate)
    
}

// MARK: -

public class BasicPeerChannel: PeerChannel {
    
    public let handlers: PeerChannelHandlers = PeerChannelHandlers()
    public let configuration: Configuration
    
    public private(set) var streams: [MediaStream] = []
    public private(set) var iceCandidates: [ICECandidate] = [] // TODO: remove?
    
    public var clientId: String? {
        get { return context.clientId }
    }

    public var state: PeerChannelState {
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
    
    public var aliveState: AliveState {
        get { return context.aliveState }
    }
    
    private var context: BasicPeerChannelContext!
    
    public required init(configuration: Configuration) {
        self.configuration = configuration
        context = BasicPeerChannelContext(channel: self)
    }
    
    public func addStream(_ stream: MediaStream) {
        streams.append(stream)
        handlers.onAddStreamHandler?(stream)
    }
    
    public func removeStream(id: String) {
        let stream = streams.first { stream in stream.streamId == id }
        if let stream = stream {
            removeStream(stream)
        }
    }
    
    public func removeStream(_ stream: MediaStream) {
        streams = streams.filter { each in each.streamId != stream.streamId }
        handlers.onRemoveStreamHandler?(stream)
    }
    
    public func addICECandidate(_ candidate: ICECandidate) {
        iceCandidates.append(candidate)
    }
    
    public func removeICECandidate(_ candidate: ICECandidate) {
        iceCandidates = iceCandidates.filter { each in each == candidate }
    }
    
    public func connect(webRTCConfiguration: WebRTCConfiguration,
                        handler: @escaping (Error?) -> Void) {
        context.connect(webRTCConfiguration: webRTCConfiguration,
                        handler: handler)
    }
    
    public func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    fileprivate func terminateAllStreams() {
        streams.removeAll()
        // Do not call `handlers.onRemoveStreamHandler` here
        // This method is meant to be called only when disconnection cleanup
    }
    
}

// MARK: -

class BasicPeerChannelContext: NSObject, RTCPeerConnectionDelegate, AliveMonitorable {
    
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
    var signalingChannel: SignalingChannel
    var webRTCConfiguration: WebRTCConfiguration!
    var clientId: String?
    
    var configuration: Configuration {
        get { return channel.configuration }
    }
    
    var aliveState: AliveState {
        get {
            switch state {
            case .connected:
                return .available
            case .connecting:
                return .connecting
            default:
                return .unavailable
            }
        }
    }
    
    var onConnectHandler: ((Error?) -> Void)?
    
    init(channel: BasicPeerChannel) {
        self.channel = channel
        signalingChannel = channel.configuration.signalingChannelType
            .init(configuration: channel.configuration)
        super.init()
        
        signalingChannel.handlers.onMessageHandler = handleMessage
    }
    
    func connect(webRTCConfiguration: WebRTCConfiguration,
                 handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .peerChannel, message: "try connecting")
        Logger.debug(type: .peerChannel, message: "try connecting to signaling channel")
        
        state = .connecting
        onConnectHandler = handler
        self.webRTCConfiguration = webRTCConfiguration
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
        
        signalingChannel.connect(handler: sendConnectMessage)
    }
    
    func sendConnectMessage(error: Error?) {
        if error != nil {
            Logger.debug(type: .peerChannel,
                         message: "failed connecting to signaling channel")
            disconnect(error: error)
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
        }
        let connect =
            SignalingConnectMessage(role: role,
                                    channelId: configuration.channelId,
                                    metadata: configuration.metadata,
                                    multistreamEnabled: multistream,
                                    videoEnabled: configuration.videoEnabled,
                                    videoCodec: configuration.videoCodec,
                                    videoBitRate: configuration.videoBitRate,
                                    audioEnabled: configuration.audioEnabled,
                                    audioCodec: configuration.audioCodec)
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
        let stream = BasicMediaStream(nativeStream: nativeStream)
        if configuration.videoEnabled {
            switch configuration.videoCapturerOption {
            case .camera:
                // カメラが指定されている場合は、接続処理と同時にデフォルトのCameraVideoCapturerを使用してキャプチャを開始する
                CameraVideoCapturer.shared.start()
                stream.videoCapturer = CameraVideoCapturer.shared
            case .custom:
                // カスタムが指定されている場合は、接続処理時には何もしない
                // 完全にユーザーサイドにVideoCapturerの設定とマネジメントを任せる
                break
            }
        }
        channel.addStream(stream)
        Logger.debug(type: .peerChannel,
                     message: "create publisher stream (id: \(configuration.publisherStreamId))")
    }
    
    /** `initializePublisherStream()` にて生成されたリソースを開放するための、対になるメソッドです。 */
    func terminatePublisherStream() {
        if configuration.videoEnabled {
            switch configuration.videoCapturerOption {
            case .camera:
                // カメラが指定されている場合は
                // 接続時に自動的に開始したキャプチャを、切断時に自動的に停止する必要がある
                CameraVideoCapturer.shared.stop()
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
            webRTCConfiguration.iceServerInfos = config.iceServerInfos
            webRTCConfiguration.iceTransportPolicy = config.iceTransportPolicy
            nativeChannel.setConfiguration(webRTCConfiguration.nativeValue)
        }
        
        nativeChannel.createAnswer(forOffer: offer.sdp,
                                   constraints: webRTCConfiguration.nativeConstraints)
        { sdp, error in
            guard error == nil else {
                Logger.debug(type: .peerChannel,
                             message: "failed create answer")
                self.disconnect(error: error)
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
                self.disconnect(error: error)
                return
            }
            
            let message = SignalingMessage.update(sdp: answer!)
            self.signalingChannel.send(message: message)
            
            // Answer 送信後に RTCPeerConnection の状態に変化はないため、
            // Answer を送信したら更新完了とする
            self.state = .connected
            
            self.channel.handlers.onUpdateHandler?(answer!)
        }
    }
    
    func handleMessage(_ message: SignalingMessage) {
        Logger.debug(type: .mediaStream, message: "handle message")
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
                guard configuration.role == .group else { return }
                Logger.debug(type: .peerChannel, message: "receive update")
                createAndSendUpdateAnswerMessage(forOffer: sdp)
                
            case .notify(message: let message):
                Logger.debug(type: .peerChannel, message: "receive notify")
                channel.handlers.onNotifyHandler?(message)
                
            case .ping:
                Logger.debug(type: .peerChannel, message: "receive ping")
                signalingChannel.send(message: .pong)
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
        state = .connected
        onConnectHandler?(nil)
        onConnectHandler = nil
    }
    
    func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .peerChannel, message: "try disconnecting")
            state = .disconnecting
            
            switch configuration.role {
            case .publisher: terminatePublisherStream()
            case .subscriber: break
            case .group: terminatePublisherStream()
            }
            channel.terminateAllStreams()
            nativeChannel.close()
            signalingChannel.disconnect(error: error)
            state = .disconnected
            
            onConnectHandler?(error)
            onConnectHandler = nil
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
        guard stream.streamId != clientId else { return }
        
        Logger.debug(type: .peerChannel,
                     message: "added a media stream (id: \(stream.streamId))")
        let stream = BasicMediaStream(nativeStream: stream)
        channel.addStream(stream)
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        Logger.debug(type: .peerChannel,
                     message: "removed a media stream (id: \(stream.streamId))")
        channel.removeStream(id: stream.streamId)
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
        channel.addICECandidate(candidate)
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
            channel.removeICECandidate(candidate)
        }
    }
    
    // NOTE: Sora はデータチャネルに非対応
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        Logger.debug(type: .peerChannel, message: "opened data channel (ignored)")
        // 何もしない
    }
    
}
