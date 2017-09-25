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
            onCompleteHandler?()
            onCompleteHandler = nil
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
    var streams: [MediaStream] { get }
    var iceCandidates: [ICECandidate] { get }
    var state: PeerChannelState { get }
    
    init(configuration: Configuration)
    
    func connect(handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
    func addStream(_ stream: MediaStream)
    func removeStream(_ stream: MediaStream)
    func addICECandidate(_ candidate: ICECandidate)
    func removeICECandidate(_ candidate: ICECandidate)
    
}

// MARK: -

open class BasicPeerChannel: PeerChannel {

    public var handlers: PeerChannelHandlers = PeerChannelHandlers()
    public var configuration: Configuration
    public var streams: [MediaStream] = []
    public var iceCandidates: [ICECandidate] = [] // TODO: remove?
    
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
    
    var context: BasicPeerChannelContext!

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

    public func connect(handler: @escaping (Error?) -> Void) {
        context.connect(handler: handler)
    }
    
    public func disconnect(error: Error?) {
        context.disconnect(error: error)
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
    
    var configuration: Configuration {
        get { return channel.configuration }
        set { channel.configuration = newValue }
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
        
        nativeChannel = NativePeerChannelFactory.default
            .createNativePeerChannel(configuration: configuration,
                                     delegate: self)
        internalState = PeerChannelInternalState(
            signalingState: PeerChannelSignalingState(
                nativeValue: nativeChannel.signalingState),
            iceConnectionState: ICEConnectionState(
                nativeValue: nativeChannel.iceConnectionState),
            iceGatheringState: ICEGatheringState(
                nativeValue: nativeChannel.iceGatheringState))
        internalState.onCompleteHandler = finishConnecting
        signalingChannel.handlers.onMessageHandler = handleMessage
    }

    func connect(handler: @escaping (Error?) -> Void) {
        Log.debug(type: .peerChannel, message: "try connecting")
        Log.debug(type: .peerChannel, message: "try connecting to signaling channel")
        state = .connecting
        onConnectHandler = handler
        signalingChannel.connect(handler: sendConnectRequest)
    }
    
    func sendConnectRequest(error: Error?) {
        if error != nil {
            Log.debug(type: .peerChannel,
                      message: "failed connecting to signaling channel")
            disconnect(error: error)
            return
        }
        
        Log.debug(type: .peerChannel,
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
        let request =
            SignalingConnectRequest(role: role,
                                    channelId: configuration.channelId,
                                    metadata: configuration.metadata,
                                    multistreamEnabled: multistream,
                                    videoEnabled: configuration.videoEnabled,
                                    videoCodec: configuration.videoCodec,
                                    videoBitRate: configuration.videoBitRate,
                                    audioEnabled: configuration.audioEnabled,
                                    audioCodec: configuration.audioCodec)
        let message = SignalingMessage.connect(request: request)
        Log.debug(type: .peerChannel, message: "send connect")
        signalingChannel.send(message: message)
    }
    
    func initializePublisherStream() {
        let nativeStream = NativePeerChannelFactory.default
            .createNativePublisherStream(configuration: configuration)
        let stream = BasicMediaStream(nativeStream: nativeStream)
        if configuration.videoEnabled {
            CameraVideoCapturer.shared.start()
            stream.videoCapturer = CameraVideoCapturer.shared
        }
        channel.addStream(stream)
    }
    
    func sendAnswerResponse(offer: SignalingOfferRequest) {
        Log.debug(type: .peerChannel, message: "try sending answer")
        state = .waitingComplete
        
        if let config = offer.configuration {
            Log.debug(type: .peerChannel, message: "update configuration")
            configuration.iceServerInfos = config.iceServerInfos
            configuration.iceTransportPolicy = config.iceTransportPolicy
            nativeChannel.setConfiguration(
                configuration.nativeConfiguration)
        }
        
        Log.debug(type: .peerChannel, message: "try setting remote description")
        let nativeOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        nativeChannel.setRemoteDescription(nativeOffer) { error in
            guard error == nil else {
                Log.debug(type: .peerChannel,
                          message: "failed setting remote description")
                self.disconnect(error: error)
                return
            }
            
            Log.debug(type: .peerChannel, message: "did set remote description")
            Log.debug(type: .peerChannel, message: "\(nativeOffer.sdpDescription)")
            Log.debug(type: .peerChannel, message: "try creating native answer")
            self.nativeChannel.answer(for: self.channel.configuration.nativeConstraints,
                                      completionHandler: self.setLocalDescription)
        }
    }
    
    func setLocalDescription(sdp: RTCSessionDescription?,
                             error: Error?) {
        guard error == nil else {
            Log.debug(type: .peerChannel,
                      message: "failed creating native answer")
            self.disconnect(error: error)
            return
        }
        Log.debug(type: .peerChannel, message: "did create native answer")
        
        Log.debug(type: .peerChannel, message: "try setting local description")
        nativeChannel.setLocalDescription(sdp!) { error in
            guard error == nil else {
                Log.debug(type: .peerChannel,
                          message: "failed setting local description")
                self.disconnect(error: error)
                return
            }
            Log.debug(type: .peerChannel, message: "did set local description")
            Log.debug(type: .peerChannel, message: "\(sdp!.sdpDescription)")
            Log.debug(type: .peerChannel, message: "did send answer")
            let answer = SignalingMessage.answer(sdp: sdp!.sdp)
            self.signalingChannel.send(message: answer)
        }
    }

    func handleMessage(_ message: SignalingMessage) {
        Log.debug(type: .mediaStream, message: "handle message")
        switch state {
        case .waitingOffer:
            switch message {
            case .offer(let offer):
                Log.debug(type: .peerChannel, message: "receive offer")
                sendAnswerResponse(offer: offer)
                
            default:
                // discard
                break
            }
            
        case .connected:
            switch message {
            case .update(sdp: let sdp):
                guard configuration.role == .group else { return }
                Log.debug(type: .peerChannel, message: "receive update")
                createAndSendUpdateAnswer(forOffer: sdp)
                
            case .notify(message: let message):
                Log.debug(type: .peerChannel, message: "receive notify")
                channel.handlers.onNotifyHandler?(message)
                
            case .ping:
                Log.debug(type: .peerChannel, message: "receive ping")
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
    
    func createAndSendUpdateAnswer(forOffer offer: String) {
        state = .waitingUpdateComplete
        nativeChannel.createAnswer(forOffer: offer,
                                   constraints: configuration.nativeConstraints)
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
    
    func finishConnecting() {
        Log.debug(type: .peerChannel, message: "did connect")
        Log.debug(type: .peerChannel,
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
            Log.debug(type: .peerChannel, message: "try disconnecting")
            state = .disconnecting
            nativeChannel.close()
            signalingChannel.disconnect(error: error)
            state = .disconnected
            onConnectHandler?(error)
            onConnectHandler = nil
            Log.debug(type: .peerChannel, message: "did disconnect")
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        let newState = PeerChannelSignalingState(nativeValue: stateChanged)
        Log.debug(type: .peerChannel,
                  message: "changed signaling state to \(newState)")
        internalState.signalingState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {
        Log.debug(type: .peerChannel,
                  message: "added a media stream (\(stream.streamId))")
        let stream = BasicMediaStream(nativeStream: stream)
        channel.addStream(stream)
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        Log.debug(type: .peerChannel,
                  message: "removed a media stream (\(stream.streamId))")
        channel.removeStream(id: stream.streamId)
    }
    
    func peerConnectionShouldNegotiate(_ nativePeerConnection: RTCPeerConnection) {
        Log.debug(type: .peerChannel, message: "required negatiation")
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        let newState = ICEConnectionState(nativeValue: newState)
        Log.debug(type: .peerChannel,
                  message: "changed ICE connection state to \(newState)")
        internalState.iceConnectionState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        let newState = ICEGatheringState(nativeValue: newState)
        Log.debug(type: .peerChannel,
                  message: "changed ICE gathering state to \(newState)")
        internalState.iceGatheringState = newState
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        Log.debug(type: .peerChannel,
                  message: "generated ICE candidate \(candidate)")
        let candidate = ICECandidate(nativeICECandidate: candidate)
        channel.addICECandidate(candidate)
        let message = SignalingMessage.candidate(candidate)
        signalingChannel.send(message: message)
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
        Log.debug(type: .peerChannel,
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
        Log.debug(type: .peerChannel, message: "opened data channel (ignored)")
        // 何もしない
    }
    
}
