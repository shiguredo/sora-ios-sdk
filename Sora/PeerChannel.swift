import Foundation
import WebRTC

/**
 ピアチャネルのイベントハンドラです。
 */
@available(*, unavailable, message: "MediaChannelHandlers を利用してください。")
public class PeerChannelHandlers {}

final class PeerChannelInternalHandlers {

    /// 接続解除時に呼ばれるクロージャー
    var onDisconnect: ((Error?, DisconnectReason) -> Void)?
    
    /// ストリームの追加時に呼ばれるクロージャー
    var onAddStream: ((MediaStream) -> Void)?
    
    /// ストリームの除去時に呼ばれるクロージャー
    var onRemoveStream: ((MediaStream) -> Void)?
    
    /// マルチストリームの状態の更新に呼ばれるクロージャー。
    /// 更新により、ストリームの追加または除去が行われます。
    var onUpdate: ((String) -> Void)?
    
    /// シグナリング受信時に呼ばれるクロージャー
    var onReceiveSignaling: ((Signaling) -> Void)?

    /// DataChannel の open 時に呼ばれるクロージャー
    var onOpenDataChannel: ((String) -> Void)?

    /// DataChannel のメッセージ受信時に呼ばれるクロージャー
    var onDataChannelMessage: ((String, Data) -> Void)?

    /// DataChannel の close 時に呼ばれるクロージャー
    var onCloseDataChannel: ((String) -> Void)?

    /// DataChannel の bufferedAmount 変更時に呼ばれるクロージャー
    var onDataChannelBufferedAmount: ((String, UInt64) -> Void)?

    /// 初期化します。
    public init() {}
    
}

class PeerChannel {

    var internalHandlers: PeerChannelInternalHandlers = PeerChannelInternalHandlers()
    let configuration: Configuration
    let signalingChannel: SignalingChannel
    
    private(set) var streams: [MediaStream] = []
    private(set) var iceCandidates: [ICECandidate] = []
    
    var clientId: String? {
        get { return context.clientId }
    }
    
    var connectionId: String? {
        context.connectionId
    }
    
    var state: PeerChannelConnectionState {
        get {
            return context.state
        }
    }
    
    var dataChannels: [String] = []
    var dataChannelInstances: [String: DataChannel] = [:]
    var switchedToDataChannel: Bool = false
    var signalingOfferMessageDataChannels: [[String: Any]] = []
    
    var context: BasicPeerChannelContext!
    
    weak var mediaChannel: MediaChannel?
    
    required init(configuration: Configuration, signalingChannel: SignalingChannel, mediaChannel: MediaChannel?) {
        self.configuration = configuration
        self.signalingChannel = signalingChannel
        self.mediaChannel = mediaChannel
        context = BasicPeerChannelContext(channel: self)
    }
    
    func add(stream: MediaStream) {
        streams.append(stream)
        Logger.debug(type: .peerChannel, message: "call onAddStream")
        internalHandlers.onAddStream?(stream)
    }
    
    func remove(streamId: String) {
        let stream = streams.first { stream in stream.streamId == streamId }
        if let stream = stream {
            remove(stream: stream)
        }
    }
    
    func remove(stream: MediaStream) {
        streams = streams.filter { each in each.streamId != stream.streamId }
        Logger.debug(type: .peerChannel, message: "call onRemoveStream")
        internalHandlers.onRemoveStream?(stream)
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
    
    func disconnect(error: Error?, reason: DisconnectReason) {
        context.disconnect(error: error, reason: reason)
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

/// type: disconnect の reason を判断するのに必要な情報を保持します。
enum DisconnectReason : String {
    case user
    case signalingFailure
    case internalError
    case peerConnectionStateFailed
    case webSocket
    case dataChannelClosed
    case noError
    case unknown
    
    var description: String {
        return self.rawValue
    }
}

class BasicPeerChannelContext: NSObject, RTCPeerConnectionDelegate {
    
    final class Lock {
        
        weak var context: BasicPeerChannelContext?
        var count: Int = 0
        var shouldDisconnect: (Bool, Error?, DisconnectReason) = (false, nil, .unknown)
        
        func waitDisconnect(error: Error?, reason: DisconnectReason) {
            if count == 0 {
                context?.basicDisconnect(error: error, reason: reason)
            } else {
                shouldDisconnect = (true, error, reason)
            }
        }
        
        func lock() {
            count += 1
        }
        
        func unlock() {
            if count <= 0 {
                fatalError("count is already 0")
            }
            count -= 1
            if count == 0 {
                disconnect()
            }
        }
        
        func disconnect() {
            switch shouldDisconnect {
            case (true, let error, let reason):
                shouldDisconnect = (false, nil, .unknown)
                if let context = context {
                    if context.state != .closed {
                        context.basicDisconnect(error: error, reason: reason)
                    }
                }
            default:
                break
            }
        }
    }
    
    weak var channel: PeerChannel!
    var state: PeerChannelConnectionState {
        get {
            let state = nativeChannel == nil ? RTCPeerConnectionState.new : nativeChannel.connectionState
            return PeerChannelConnectionState(state)
        }
    }
    
    // connect() の成功後は必ずセットされるので nil チェックを省略する
    // connect() 実行前は nil なのでアクセスしないこと
    var nativeChannel: RTCPeerConnection!
    
    var signalingChannel: SignalingChannel {
        get { return channel.signalingChannel }
    }
    
    var webRTCConfiguration: WebRTCConfiguration!
    var clientId: String?
    var connectionId: String?

    var configuration: Configuration {
        get { return channel.configuration }
    }
    
    var onConnectHandler: ((Error?) -> Void)?
    
    var isAudioInputInitialized: Bool = false
    
    private var lock: Lock
    
    private var offerEncodings: [SignalingOffer.Encoding]?

    private var connectedAtLeastOnce: Bool = false

    init(channel: PeerChannel) {
        self.channel = channel

        lock = Lock()
        super.init()
        lock.context = self
        
        signalingChannel.internalHandlers.onDisconnect = { [weak self] (error, reason) in
            self?.disconnect(error: error, reason: reason)
        }
        
        signalingChannel.internalHandlers.onReceive = { [weak self] signaling in
            self?.handle(signaling: signaling)
        }
        
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        if channel.state == .connecting || channel.state == .connected {
            handler(SoraError.connectionBusy(reason:
                "PeerChannel is already connected"))
            return
        }
        
        Logger.debug(type: .peerChannel, message: "try connecting")
        Logger.debug(type: .peerChannel, message: "try connecting to signaling channel")
        
        self.webRTCConfiguration = channel.configuration.webRTCConfiguration
        nativeChannel = NativePeerChannelFactory.default
            .createNativePeerChannel(configuration: webRTCConfiguration,
                                     constraints: webRTCConfiguration.constraints,
                                     delegate: self)
        guard nativeChannel != nil else {
            let message = "createNativePeerChannel failed"
            Logger.debug(type: .peerChannel, message: message)
            handler(SoraError.peerChannelError(reason: message))
            return
        }
        
        // このロックは finishConnecting() で解除される
        lock.lock()
        onConnectHandler = handler

        // サイマルキャストを利用する場合は、 RTCPeerConnection の生成前に WrapperVideoEncoderFactory を設定する必要がある
        // また、 (非レガシーな) スポットライトはサイマルキャストを利用しているため、同様に設定が必要になる
        WrapperVideoEncoderFactory.shared.simulcastEnabled = configuration.simulcastEnabled || (!Sora.isSpotlightLegacyEnabled && configuration.spotlightEnabled == .enabled)
        
        signalingChannel.connect { [weak self] error in
            self?.sendConnectMessage(error: error)
        }
    }
    
    func sendConnectMessage(error: Error?) {
        if let error = error {
            Logger.error(type: .peerChannel,
                         message: "failed connecting to signaling channel (\(error.localizedDescription))")
            onConnectHandler?(error)
            onConnectHandler = nil
            return
        }
        
        if configuration.isSender {
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
        } else {
            self.sendConnectMessage(with: nil, error: nil)
        }
    }
    
    func sendConnectMessage(with sdp: String?, error: Error?) {
        if error != nil {
            Logger.error(type: .peerChannel,
                         message: "failed connecting to signaling channel (\(error!.localizedDescription))")
            disconnect(error: SoraError.peerChannelError(reason: "failed connecting to signaling channel"),
                       reason: .signalingFailure)
            return
        }
        
        Logger.debug(type: .peerChannel,
                     message: "did connect to signaling channel")
        
        var role: SignalingRole!
        var multistream = configuration.multistreamEnabled || configuration.spotlightEnabled == .enabled
        switch configuration.role {
        case .publisher, .sendonly:
            role = .sendonly
        case .subscriber, .recvonly:
            role = .recvonly
        case .group, .sendrecv:
            role = .sendrecv
            multistream = true
        case .groupSub:
            role = .recvonly
            multistream = true
        }
        
        let soraClient = "Sora iOS SDK \(SDKInfo.version)"
        
        let webRTCVersion = "Shiguredo-build \(WebRTCInfo.version) (\(WebRTCInfo.version).\(WebRTCInfo.commitPosition).\(WebRTCInfo.maintenanceVersion) \(WebRTCInfo.shortRevision))"
        
        let simulcast = configuration.simulcastEnabled || (!Sora.isSpotlightLegacyEnabled && configuration.spotlightEnabled == .enabled)
        let connect = SignalingConnect(
            role: role,
            channelId: configuration.channelId,
            clientId: configuration.clientId,
            metadata: configuration.signalingConnectMetadata,
            notifyMetadata: configuration.signalingConnectNotifyMetadata,
            sdp: sdp,
            multistreamEnabled: multistream,
            videoEnabled: configuration.videoEnabled,
            videoCodec: configuration.videoCodec,
            videoBitRate: configuration.videoBitRate,
            audioEnabled: configuration.audioEnabled,
            audioCodec: configuration.audioCodec,
            audioBitRate: configuration.audioBitRate,
            spotlightEnabled: configuration.spotlightEnabled,
            spotlightNumber: configuration.spotlightNumber,
            spotlightFocusRid: configuration.spotlightFocusRid,
            spotlightUnfocusRid: configuration.spotlightUnfocusRid,
            simulcastEnabled: simulcast,
            simulcastRid: configuration.simulcastRid,
            soraClient: soraClient,
            webRTCVersion: webRTCVersion,
            environment: DeviceInfo.current.description,
            dataChannelSignaling: configuration.dataChannelSignaling,
            ignoreDisconectWebSocket: configuration.ignoreDisconnectWebSocket)
        
        Logger.debug(type: .peerChannel, message: "send connect")
        signalingChannel.send(message: Signaling.connect(connect))
    }
    
    func initializeSenderStream() {
        Logger.debug(type: .peerChannel,
                     message: "initialize sender stream")
        
        let nativeStream = NativePeerChannelFactory.default
            .createNativeSenderStream(streamId: configuration.publisherStreamId,
                                         videoTrackId:
                configuration.videoEnabled ? configuration.publisherVideoTrackId: nil,
                                         audioTrackId:
                configuration.audioEnabled ? configuration.publisherAudioTrackId : nil,
                                         constraints: webRTCConfiguration.constraints)
        let stream = BasicMediaStream(peerChannel: channel,
                                      nativeStream: nativeStream)
        
        if configuration.videoEnabled && configuration.cameraSettings.isEnabled {
            let position = configuration.cameraSettings.position
            
            // position に対応した CameraVideoCapturer を取得する
            let capturer: CameraVideoCapturer
            switch position {
            case .front:
                guard let front = CameraVideoCapturer.front else {
                    Logger.error(type: .peerChannel, message: "front camera is not found")
                    return
                }
                capturer = front
            case .back:
                guard let back = CameraVideoCapturer.back else {
                    Logger.error(type: .peerChannel, message: "back camera is not found")
                    return
                }
                capturer = back
            case .unspecified:
                Logger.error(type: .peerChannel, message: "CameraSettings.position should not be .unspecified")
                return
            @unknown default:
                guard let device = CameraVideoCapturer.device(for: position) else {
                    Logger.error(type: .peerChannel, message: "device is not found for position")
                    return
                }
                capturer = CameraVideoCapturer(device: device)
            }

            // デバイスに対応したフォーマットとフレームレートを取得する
            guard let format = CameraVideoCapturer.format(width: configuration.cameraSettings.resolution.width,
                                                          height: configuration.cameraSettings.resolution.height,
                                                          for: capturer.device) else {
                Logger.error(type: .peerChannel, message: "CameraVideoCapturer.suitableFormat failed: suitable format rate is not found")
                return
            }

            guard let frameRate = CameraVideoCapturer.maxFrameRate(configuration.cameraSettings.frameRate, for: format) else {
                Logger.error(type: .peerChannel, message: "CameraVideoCapturer.suitableFormat failed: suitable frame rate is not found")
                return
            }

            if CameraVideoCapturer.current != nil && CameraVideoCapturer.current!.isRunning {
                // CameraVideoCapturer.current を停止してから capturer を start する
                CameraVideoCapturer.current!.stop() { (error: Error?) in
                    guard error == nil else {
                        Logger.debug(type: .peerChannel,
                                     message: "CameraVideoCapturer.stop failed =>  \(error!)")
                        return
                    }

                    capturer.start(format: format, frameRate: frameRate) { error in
                        guard error == nil else {
                            Logger.debug(type: .peerChannel,
                                         message: "CameraVideoCapturer.start failed =>  \(error!)")
                            return
                        }
                        Logger.debug(type: .peerChannel,
                                     message: "set CameraVideoCapturer to sender stream")
                        capturer.stream = stream
                    }
                }
            } else {
                capturer.start(format: format, frameRate: frameRate) { error in
                    guard error == nil else {
                        Logger.debug(type: .peerChannel,
                                     message: "CameraVideoCapturer.start failed =>  \(error!)")
                        return
                    }
                    Logger.debug(type: .peerChannel,
                                 message: "set CameraVideoCapturer to sender stream")
                    capturer.stream = stream
                }
            }
        }
        
        if configuration.audioEnabled {
            if isAudioInputInitialized {
                Logger.debug(type: .peerChannel,
                             message: "audio input is already initialized")
            } else {
                Logger.debug(type: .peerChannel,
                             message: "initialize audio input")
                
                // カテゴリをマイク用途のものに変更する
                // libwebrtc の内部で参照される RTCAudioSessionConfiguration を使う必要がある
                Logger.debug(type: .peerChannel,
                             message: "change audio session category (playAndRecord)")
                RTCAudioSessionConfiguration.webRTC().category =
                    AVAudioSession.Category.playAndRecord.rawValue
                
                RTCAudioSession.sharedInstance().initializeInput { error in
                    if let error = error {
                        Logger.debug(type: .peerChannel,
                                     message: "failed to initialize audio input => \(error.localizedDescription)")
                        return
                    }
                    self.isAudioInputInitialized = true
                    Logger.debug(type: .peerChannel,
                                 message: "audio input is initialized => category \(RTCAudioSession.sharedInstance().category)")
                }
            }
        }
        
        if let track = stream.nativeVideoTrack {
            nativeChannel.add(track,
                              streamIds: [stream.nativeStream.streamId])
        }
        if let track = stream.nativeAudioTrack {
            nativeChannel.add(track,
                              streamIds: [stream.nativeStream.streamId])
        }
        channel.add(stream: stream)
        Logger.debug(type: .peerChannel,
                     message: "create publisher stream (id: \(configuration.publisherStreamId))")
    }
    
    /** `initializeSenderStream()` にて生成されたリソースを開放するための、対になるメソッドです。 */
    func terminateSenderStream() {
        if configuration.videoEnabled || configuration.cameraSettings.isEnabled {
            // CameraVideoCapturer が起動中の場合は停止する
            if let current = CameraVideoCapturer.current {
                current.stop { error in
                    if error != nil {
                        Logger.debug(type: .peerChannel,
                                     message: "failed to stop CameraVideoCapturer =>  \(error!)")
                    }
                }
            }
        }
    }
    
    func createAnswer(isSender: Bool,
                      offer: String,
                      constraints: RTCMediaConstraints,
                      handler: @escaping (String?, Error?) -> Void) {
        Logger.debug(type: .peerChannel, message: "try create answer")
        Logger.debug(type: .peerChannel, message: offer)
        
        Logger.debug(type: .peerChannel, message: "try setting remote description")
        let offer = RTCSessionDescription(type: .offer, sdp: offer)
        nativeChannel.setRemoteDescription(offer) { error in
            guard error == nil else {
                Logger.debug(type: .peerChannel,
                             message: "failed setting remote description: (\(error!.localizedDescription)")
                handler(nil, error)
                return
            }
            Logger.debug(type: .peerChannel, message: "did set remote description")
            Logger.debug(type: .peerChannel, message: "\(offer.sdpDescription)")
            
            if isSender {
                self.initializeSenderStream()
                self.updateSenderOfferEncodings()
            }
            
            Logger.debug(type: .peerChannel, message: "try creating native answer")
            self.nativeChannel.answer(for: constraints) { answer, error in
                guard error == nil else {
                    Logger.debug(type: .peerChannel,
                                 message: "failed creating native answer (\(error!.localizedDescription)")
                    handler(nil, error)
                    return
                }
                Logger.debug(type: .peerChannel, message: "did create answer")
                
                Logger.debug(type: .peerChannel, message: "try setting local description")
                self.nativeChannel.setLocalDescription(answer!) { error in
                    guard error == nil else {
                        Logger.debug(type: .peerChannel,
                                     message: "failed setting local description")
                        handler(nil, error)
                        return
                    }
                    Logger.debug(type: .peerChannel,
                                 message: "did set local description")
                    Logger.debug(type: .peerChannel,
                                 message: "\(answer!.sdpDescription)")
                    Logger.debug(type: .peerChannel,
                                 message: "did create answer")
                    handler(answer!.sdp, nil)
                }
            }
        }
    }
        
    private func updateSenderOfferEncodings() {
        guard let oldEncodings = offerEncodings else {
            return
        }
        Logger.debug(type: .peerChannel, message: "update sender offer encodings")
        for sender in nativeChannel.senders {
            sender.updateOfferEncodings(oldEncodings)
        }
    }
    
    func createAndSendAnswer(offer: SignalingOffer) {
        Logger.debug(type: .peerChannel, message: "try sending answer")
        offerEncodings = offer.encodings
        
        if let config = offer.configuration {
            Logger.debug(type: .peerChannel, message: "update configuration")
            Logger.debug(type: .peerChannel, message: "ICE server infos => \(config.iceServerInfos)")
            Logger.debug(type: .peerChannel, message: "ICE transport policy => \(config.iceTransportPolicy)")
            webRTCConfiguration.iceServerInfos = config.iceServerInfos
            webRTCConfiguration.iceTransportPolicy = config.iceTransportPolicy
            nativeChannel.setConfiguration(webRTCConfiguration.nativeValue)
        }
        
        lock.lock()
        createAnswer(isSender: configuration.isSender,
                     offer: offer.sdp,
                     constraints: webRTCConfiguration.nativeConstraints)
        { sdp, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create answer (\(error!.localizedDescription))")
                self.lock.unlock()
                self.disconnect(error: SoraError.peerChannelError(reason: "failed to create answer"),
                                reason: .signalingFailure)
                return
            }
            
            let answer = SignalingAnswer(sdp: sdp!)
            self.signalingChannel.send(message: Signaling.answer(answer))
            self.lock.unlock()
            Logger.debug(type: .peerChannel, message: "did send answer")
        }
    }
    
    
    func createAndSendUpdateAnswer(forOffer offer: String) {
        Logger.debug(type: .peerChannel, message: "create and send update-answer")
        lock.lock()
        createAnswer(isSender: false,
                     offer: offer,
                     constraints: webRTCConfiguration.nativeConstraints)
        { answer, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create update-answer (\(error!.localizedDescription)")
                self.lock.unlock()
                self.disconnect(error: SoraError.peerChannelError(reason: "failed to create update-answer"),
                                reason: .signalingFailure)
                return
            }
            
            let message = Signaling.update(SignalingUpdate(sdp: answer!))
            self.signalingChannel.send(message: message)
            
            if (self.configuration.isSender) {
                self.updateSenderOfferEncodings()
            }
            
            Logger.debug(type: .peerChannel, message: "call onUpdate")
            self.channel.internalHandlers.onUpdate?(answer!)
            
            self.lock.unlock()
        }
    }
    
    func createAndSendReAnswer(forReOffer reOffer: String) {
        Logger.debug(type: .peerChannel, message: "create and send re-answer")
        lock.lock()
        createAnswer(isSender: false,
                     offer: reOffer,
                     constraints: webRTCConfiguration.nativeConstraints)
        { answer, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create re-answer (\(error!.localizedDescription)")
                self.lock.unlock()
                self.disconnect(error: SoraError.peerChannelError(reason: "failed to create re-answer"),
                                reason: .signalingFailure)
                return
            }
            
            let message = Signaling.reAnswer(SignalingReAnswer(sdp: answer!))
            self.signalingChannel.send(message: message)
            
            if (self.configuration.isSender) {
                self.updateSenderOfferEncodings()
            }
            
            Logger.debug(type: .peerChannel, message: "call onUpdate")
            self.channel.internalHandlers.onUpdate?(answer!)
            
            self.lock.unlock()
        }
    }
    
    func createAndSendReAnswerOnDataChannel(forReOffer reOffer: String) {
        Logger.debug(type: .peerChannel, message: "create and send re-answer on DataChannel")
        
        guard let dataChannel = channel.dataChannelInstances["signaling"] else {
            Logger.debug(type: .peerChannel, message: "DataChannel for label: signaling is unavailable")
            return
        }
        lock.lock()
        createAnswer(isSender: false,
                     offer: reOffer,
                     constraints: webRTCConfiguration.nativeConstraints)
        { answer, error in
            guard error == nil else {
                Logger.error(type: .peerChannel,
                             message: "failed to create re-answer: error => (\(error!.localizedDescription)")
                self.lock.unlock()
                self.disconnect(error: SoraError.peerChannelError(reason: "failed to create re-answer"),
                                reason: .signalingFailure)
                return
            }
            
            let reAnswer = Signaling.reAnswer(SignalingReAnswer(sdp: answer!))
            
            var data: Data?
            do {
                data = try JSONEncoder().encode(reAnswer)
            } catch {
                Logger.error(type: .peerChannel,
                             message: "failed to encode re-answer: error => (\(error.localizedDescription)")
                self.lock.unlock()
                self.disconnect(error: SoraError.peerChannelError(reason: "failed to encode re-answer message to json"),
                                reason:. signalingFailure)
                return
            }

            if let data = data {
                let ok = dataChannel.send(data)
                if !ok {
                    Logger.error(type: .peerChannel,
                                 message: "failed to send re-answer message over DataChannel")
                    self.lock.unlock()
                    self.disconnect(error: SoraError.peerChannelError(reason: "failed to send re-answer message over DataChannel"),
                                    reason:. signalingFailure)
                    return
                }
            }
            

            if (self.configuration.isSender) {
                self.updateSenderOfferEncodings()
            }
            
            Logger.debug(type: .peerChannel, message: "call onUpdate")
            self.channel.internalHandlers.onUpdate?(answer!)
            
            self.lock.unlock()
        }
    }
    
    
    func handle(signaling: Signaling) {
        Logger.debug(type: .mediaStream, message: "handle signaling => \(signaling.typeName())")
        switch signaling {
        case .offer(let offer):
            clientId = offer.clientId
            connectionId = offer.connectionId
            if let dataChannels = offer.dataChannels {
                signalingChannel.dataChannelSignaling = true
                channel.signalingOfferMessageDataChannels = dataChannels
            }

            createAndSendAnswer(offer: offer)
        case .update(let update):
            if configuration.isMultistream {
                createAndSendUpdateAnswer(forOffer: update.sdp)
            }
        case .reOffer(let reOffer):
            createAndSendReAnswer(forReOffer: reOffer.sdp)

        case .ping(let ping):
            let pong = SignalingPong()
            if ping.statisticsEnabled == true {
                nativeChannel.statistics { report in
                    var json: [String: Any] = ["type": "pong"]
                    let stats = Statistics(contentsOf: report)
                    json["stats"] = stats.jsonObject
                    do {
                        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                        if let message = String(data: data, encoding: .utf8) {
                            self.signalingChannel.send(text: message)
                        } else {
                            self.signalingChannel.send(message: .pong(pong))
                        }
                    } catch {
                        self.signalingChannel.send(message: .pong(pong))
                    }
                }
            } else {
                signalingChannel.send(message: .pong(pong))
            }
        case .switched(let switched):
            channel.switchedToDataChannel = true
            signalingChannel.ignoreDisconnectWebSocket = switched.ignoreDisconnectWebSocket ?? false
            if (signalingChannel.ignoreDisconnectWebSocket) {
                signalingChannel.webSocketChannel.disconnect(error: nil)
            }

            if let mediaChannel = channel.mediaChannel, let onDataChannel = mediaChannel.handlers.onDataChannel {
                onDataChannel(mediaChannel)
            }
        default:
            break
        }
        
        Logger.debug(type: .peerChannel, message: "call onReceiveSignaling")
        channel.internalHandlers.onReceiveSignaling?(signaling)
    }
    
    func finishConnecting() {
        Logger.debug(type: .peerChannel, message: "did connect")
        Logger.debug(type: .peerChannel,
                     message: "media streams = \(channel.streams.count)")
        Logger.debug(type: .peerChannel,
                     message: "native senders = \(nativeChannel.senders.count)")
        Logger.debug(type: .peerChannel,
                     message: "native receivers = \(nativeChannel.receivers.count)")
        
        if onConnectHandler != nil {
            Logger.debug(type: .peerChannel, message: "call connect(handler:)")
            onConnectHandler!(nil)
            onConnectHandler = nil
        }
        lock.unlock()
    }
    
    func disconnect(error: Error?, reason: DisconnectReason) {
        switch state {
        case .closed:
            break
        default:
            Logger.debug(type: .peerChannel, message: "wait to disconnect")
            lock.waitDisconnect(error: error, reason: reason)
        }
    }
    
    func basicDisconnect(error: Error?, reason: DisconnectReason) {
        Logger.debug(type: .peerChannel, message: "\(#function): try disconencting: error => \(String(describing: error != nil ? error?.localizedDescription : "nil")), reason => \(reason)")
        if let error = error {
            Logger.error(type: .peerChannel,
                         message: "error: \(error.localizedDescription)")
        }

        sendDisconnectMessageIfNeeded(reason: reason, error: error)
        
        if configuration.isSender {
            terminateSenderStream()
        }
        channel.terminateAllStreams()
        nativeChannel.close()
        
        signalingChannel.disconnect(error: error, reason: reason)
                
        Logger.debug(type: .peerChannel, message: "call onDisconnect")
        channel.internalHandlers.onDisconnect?(error, reason)
        
        if onConnectHandler != nil {
            Logger.debug(type: .peerChannel, message: "call connect(handler:)")
            onConnectHandler!(error)
            onConnectHandler = nil
        }
        
        Logger.debug(type: .peerChannel, message: "did disconnect")
    }

    // https://sora-doc.shiguredo.jp/SORA_CLIENT
    func sendDisconnectMessageIfNeeded(reason: DisconnectReason, error: Error?) {
        if channel.state == .failed {
            // この関数に到達した時点で .failed なので、メッセージの送信は不要
            return
        }

        // 毎回タイプすると長いので変数を定義
        let dataChannelSignaling = signalingChannel.dataChannelSignaling
        let ignoreDisconnectWebSocket = signalingChannel.ignoreDisconnectWebSocket
        
        switch reason {
        case .signalingFailure, .peerConnectionStateFailed:
            break
        case .user, .noError:
            // reason: .user の場合、 error はユーザーから渡されているので考慮しない
            let noError = Signaling.disconnect(SignalingDisconnect(reason: "NO-ERROR"))
            if !dataChannelSignaling {
                // WebSocket
                signalingChannel.send(message: noError)
            } else if dataChannelSignaling && !ignoreDisconnectWebSocket {
                // WebSocket + DataChannel
                if channel.switchedToDataChannel {
                    sendMessageOverDataChannel(message: noError)
                } else {
                    signalingChannel.send(message: noError)
                }
            } else if dataChannelSignaling && ignoreDisconnectWebSocket {
                // DataChannel
                if channel.switchedToDataChannel {
                    sendMessageOverDataChannel(message: noError)
                } else {
                    signalingChannel.send(message: noError)
                }
            }
        case .webSocket:
            if ignoreDisconnectWebSocket {
                break
            }

            if let soraError = error as? SoraError {
                Logger.debug(type: .peerChannel, message: "succeeded to down cast error to SoraError: \(soraError.localizedDescription)")
                switch soraError {
                case .webSocketClosed:
                    let wsOnClose = Signaling.disconnect(SignalingDisconnect(reason: "WEBSOCKET-ONCLOSE"))
                    sendMessageOverDataChannel(message: wsOnClose)
                case .webSocketError:
                    let wsOnError = Signaling.disconnect(SignalingDisconnect(reason: "WEBSOCKET-ONERROR"))
                    sendMessageOverDataChannel(message: wsOnError)
                default:
                    break
                }
            }
        case .dataChannelClosed:
            Logger.warn(type: .peerChannel, message: "DataChannel was closed")
        default:
            break
        }

    }
    
    private func sendMessageOverDataChannel(message: Signaling) {
        guard let dataChannel = channel.dataChannelInstances["signaling"] else {
            Logger.debug(type: .peerChannel, message: "DataChannel for label: signaling is unavailable")
            return
        }

        var data: Data?
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            Logger.error(type: .peerChannel,
                         message: "failed to encode \(message.typeName()) message to json: error => (\(error.localizedDescription)")
        }

        if let data = data {
            let ok = dataChannel.send(data)
            if !ok {
                Logger.error(type: .peerChannel, message: "failed to send \(message.typeName()) message over DataChannel")
            }
        }
    }
    
    // MARK: - RTCPeerConnectionDelegate
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        Logger.debug(type: .peerChannel,
                     message: "signaling state: \(stateChanged)")
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
        
        if channel.configuration.isMultistream &&
            stream.streamId == clientId {
            Logger.debug(type: .peerChannel,
                         message: "stream already exists in multistream")
            return
        }
        
        Logger.debug(type: .peerChannel, message: "add a stream")
        stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max
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
        Logger.debug(type: .peerChannel,
                     message: "ICE connection state: \(newState)")
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        Logger.debug(type: .peerChannel,
                     message: "ICE gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        Logger.debug(type: .peerChannel,
                     message: "peer connection state: \(String(describing: newState))")
        switch newState {
        case .failed:
            disconnect(error: SoraError.peerChannelError(reason: "peer connection state: failed"),
                       reason: .peerConnectionStateFailed)
        case .connected:
            // NOTE: RTCPeerConnectionState は connected -> disconencted -> connected などと遷移する可能性があるが、
            // finishDoing は複数回実行するとエラーになるので注意
            //
            // 遷移のパターンは以下のページの Figure 2 Non-normative ICE transport state transition diagram という図を参照
            // https://www.w3.org/TR/webrtc/#dom-rtcicetransportstate
            // 図は (RTCPeerConnectionState ではなく) RTCIceTransportState のものなので注意
            if !connectedAtLeastOnce {
                finishConnecting()
                connectedAtLeastOnce = true
            }
        default:
            break
        }
    }
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        Logger.debug(type: .peerChannel,
                     message: "generated ICE candidate \(candidate)")
        let candidate = ICECandidate(nativeICECandidate: candidate)
        channel.add(iceCandidate: candidate)
        let message = Signaling.candidate(SignalingCandidate(candidate: candidate))
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
    
    func peerConnection(_ nativePeerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        let label = dataChannel.label
        Logger.debug(type: .peerChannel, message: "didOpen: label => \(label)")

        let dataChannelSetting: [String: Any]? = channel.signalingOfferMessageDataChannels.filter {
            ($0["label"] as? String) == label
        }.first ?? nil
        let compress = dataChannelSetting?["compress"] as? Bool ?? false
        
        
        guard let mediaChannel = channel.mediaChannel else {
            Logger.warn(type: .peerChannel, message: "mediaChannel is unavailable")
            return
        }
        
        let dc = DataChannel(dataChannel: dataChannel, compress: compress, mediaChannel: mediaChannel, peerChannel: self.channel)
        channel.dataChannels += [dataChannel.label]
        channel.dataChannelInstances[dataChannel.label] = dc
    }
}

extension RTCRtpSender {
    
    func updateOfferEncodings(_ encodings: [SignalingOffer.Encoding]) {
        Logger.debug(type: .peerChannel, message: "update offer encodings for sender => \(senderId)")
        
        // paramaters はアクセスのたびにコピーされてしまうので、すべての parameters をセットし直す
        let newParameters = parameters // コピーされる
        for oldEncoding in newParameters.encodings {
            Logger.debug(type: .peerChannel, message: "update encoding => \(ObjectIdentifier(oldEncoding))")
            for encoding in encodings {
                guard oldEncoding.rid == encoding.rid else {
                    continue
                }
                
                if let rid = encoding.rid {
                    Logger.debug(type: .peerChannel, message: "rid => \(rid)")
                    oldEncoding.rid = rid
                }
                
                Logger.debug(type: .peerChannel, message: "active => \(encoding.active)")
                oldEncoding.isActive = encoding.active
                Logger.debug(type: .peerChannel, message: "old active => \(oldEncoding.isActive)")

                if let value = encoding.maxFramerate {
                    Logger.debug(type: .peerChannel, message: "maxFramerate:  \(value)")
                    oldEncoding.maxFramerate = NSNumber(floatLiteral: value)
                }
                
                if let value = encoding.maxBitrate {
                    Logger.debug(type: .peerChannel, message: "maxBitrate: \(value))")
                    oldEncoding.maxBitrateBps = NSNumber(integerLiteral: value)
                }
                
                if let value = encoding.scaleResolutionDownBy {
                    Logger.debug(type: .peerChannel, message: "scaleResolutionDownBy: \(value))")
                    oldEncoding.scaleResolutionDownBy = NSNumber(value: value)
                }
                
                break
            }
        }
        
        self.parameters = newParameters
    }
}
