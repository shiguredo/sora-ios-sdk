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
    public var onSnapshotHandler: ((Snapshot) -> Void)?
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

public protocol PeerChannel {
    
    // MARK: - プロパティ
    
    var configuration: Configuration { get }
    var handlers: PeerChannelHandlers { get }
    var clientId: String? { get }
    var streams: [MediaStream] { get }
    var state: PeerChannelState { get }
    
    // MARK: - 初期化
    
    init(configuration: Configuration)
    
    // MARK: - 接続
    
    func connect(webRTCConfiguration: WebRTCConfiguration,
                 handler: @escaping (Error?) -> Void)
    func disconnect(error: Error?)
    
}

// MARK: -

class BasicPeerChannel: PeerChannel {
    
    let handlers: PeerChannelHandlers = PeerChannelHandlers()
    let configuration: Configuration
    
    private(set) var streams: [MediaStream] = []
    private(set) var iceCandidates: [ICECandidate] = []
    
    var clientId: String? {
        get { return context.clientId }
    }

    var state: PeerChannelState {
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
    
    required init(configuration: Configuration) {
        self.configuration = configuration
        context = BasicPeerChannelContext(channel: self)
    }
    
    func add(stream: MediaStream) {
        streams.append(stream)
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
        handlers.onRemoveStreamHandler?(stream)
    }
    
    func add(iceCandidate: ICECandidate) {
        iceCandidates.append(iceCandidate)
    }
    
    func remove(iceCandidate: ICECandidate) {
        iceCandidates = iceCandidates.filter { each in each == iceCandidate }
    }
    
    func connect(webRTCConfiguration: WebRTCConfiguration,
                        handler: @escaping (Error?) -> Void) {
        context.connect(webRTCConfiguration: webRTCConfiguration,
                        handler: handler)
    }
    
    func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    fileprivate func terminateAllStreams() {
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
    var signalingChannel: SignalingChannel
    var webRTCConfiguration: WebRTCConfiguration!
    var clientId: String?
    
    var configuration: Configuration {
        get { return channel.configuration }
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
        
        // スナップショットの制限
        var config = configuration
        if config.snapshotEnabled {
            Logger.debug(type: .peerChannel,
                         message: "limits configuration to snapshot")
            config.videoEnabled = true
            config.videoCodec = .vp8
            config.audioEnabled = true
        }
        
        let connect =
            SignalingConnectMessage(role: role,
                                    channelId: config.channelId,
                                    metadata: config.metadata,
                                    multistreamEnabled: multistream,
                                    videoEnabled: config.videoEnabled,
                                    videoCodec: config.videoCodec,
                                    videoBitRate: config.videoBitRate,
                                    snapshotEnabled: config.snapshotEnabled,
                                    audioEnabled: config.audioEnabled,
                                    audioCodec: config.audioCodec)
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
        
        nativeChannel.add(nativeStream)
        channel.add(stream: stream)
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
                
            case .snapshot(let snapshot):
                guard configuration.snapshotEnabled &&
                    configuration.channelId == snapshot.channelId else {
                        return
                }
                Logger.debug(type: .peerChannel, message: "receive snapshot")
                
                if let handler = channel.handlers.onSnapshotHandler {
                    guard let data = Data(base64Encoded: snapshot.webP) else {
                        Logger.debug(type: .peerChannel,
                                     message: "snapshot: invalid Base64 format")
                        return
                    }
                    guard let image = UIImage.sd_image(with: data) else {
                        Logger.debug(type: .peerChannel,
                                     message: "snapshot: invalid WebP format")
                        return
                    }
                    guard let cgImage = image.cgImage else {
                        Logger.debug(type: .peerChannel,
                                     message: "snapshot: failed to convert UIImage to CGImage")
                        return
                    }
                    let snapshot = Snapshot(image: cgImage, timestamp: Date())
                    handler(snapshot)
                }
                
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
        Logger.debug(type: .peerChannel,
                     message: "native media streams = \(nativeChannel.localStreams.count)")
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
