import Foundation
import WebRTC

public struct Attendee {
    
    public var role: Role
    public var numberOfPublishers: Int
    public var numberOfSubscribers: Int
    
    public var numberOfAllConnections: Int {
        get { return numberOfPublishers + numberOfSubscribers }
    }
    
}

public class MediaConnection {
    
    public struct NotificationKey {
        
        public enum UserInfo: String {
            case connectionError = "Sora.MediaConnection.UserInfo.connectionError"
        }
        
        public static let onConnect =
            Notification.Name("Sora.MediaConnection.Notification.onConnect")
        public static let onDisconnect =
            Notification.Name("Sora.MediaConnection.Notification.onDisconnect")
        public static let onFailure =
            Notification.Name("Sora.MediaConnection.Notification.onFailure")
        
    }

    public weak var connection: Connection!
    public var peerConnection: PeerConnection?
    public var mediaOption: MediaOption = MediaOption()
    public var multistreamEnabled: Bool = false
    public var mediaStreams: [MediaStream] = []
    
    public var mainMediaStream: MediaStream? {
        get { return mediaStreams.first }
    }

    public var webSocketEventHandlers: WebSocketEventHandlers
        = WebSocketEventHandlers()
    public var signalingEventHandlers: SignalingEventHandlers
        = SignalingEventHandlers()
    public var peerConnectionEventHandlers: PeerConnectionEventHandlers
        = PeerConnectionEventHandlers()
    
    public var isAvailable: Bool {
        get { return peerConnection?.isAvailable ?? false }
    }
    
    public var numberOfConnections: (Int, Int) = (0, 0) {
        willSet {
            if numberOfConnections != newValue {
                onChangeNumberOfConnectionsHandler?(newValue.0, newValue.1)
            }
        }
    }
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    var eventType: Event.EventType {
        get {
            assert(false, "must be override")
            return .MediaPublisher
        }
    }
    
    var role: Role {
        get {
            assertionFailure("subclass must implement role()")
            return .publisher
        }
    }
    
    init(connection: Connection) {
        self.connection = connection
    }
    
    // MARK: 接続
    
    public func connect(metadata: String? = nil,
                        timeout: Int = 30,
                        handler: @escaping ((ConnectionError?) -> Void)) {
        eventLog?.markFormat(type: eventType, format: "try connect")
        peerConnection = PeerConnection(connection: connection,
                                        mediaConnection: self,
                                        role: role,
                                        metadata: metadata,
                                        mediaStreamId: nil,
                                        mediaOption: mediaOption)
        peerConnection!.connect(timeout: timeout) {
            error in
            if let error = error {
                self.eventLog?.markFormat(type: self.eventType,
                                          format: "connect error: %@",
                                          arguments: error.description)
                self.peerConnection!.terminate()
                self.peerConnection = nil
                self.onFailureHandler?(error)
                self.callOnConnectHandler(error)
                handler(error)
            } else {
                self.eventLog?.markFormat(type: self.eventType, format: "connect ok")
                self.internalOnConnect()
                self.callOnConnectHandler()
                handler(nil)
            }
        }
    }
    
    // 内部用のコールバック
    func internalOnConnect() {}
    
    public func disconnect(handler: @escaping (ConnectionError?) -> Void) {
        eventLog?.markFormat(type: eventType, format: "try disconnect")
        switch peerConnection?.state {
        case nil, .disconnected?:
            eventLog?.markFormat(type: eventType,
                                 format: "error: already disconnected")
            handler(ConnectionError.connectionDisconnected)
        case .disconnecting?:
            eventLog?.markFormat(type: eventType,
                                 format: "error: connection is busy")
            handler(ConnectionError.connectionBusy)
        case .connected?, .connecting?:
            eventLog?.markFormat(type: eventType, format: "disconnect ok")
            for stream in mediaStreams {
                stream.terminate()
            }
            mediaStreams = []
            peerConnection!.disconnect {
                error in
                handler(error)
            }
        }
    }
    
    public func send(message: Messageable) -> ConnectionError? {
        eventLog?.markFormat(type: eventType, format: "send message")
        if isAvailable {
            return peerConnection!.send(message: message)
        } else {
            return ConnectionError.connectionDisconnected
        }
    }
    
    // MARK: マルチストリーム
    
    func hasMediaStream(_ mediaStreamId: String) -> Bool {
        guard let peerConn = peerConnection else {
            assertionFailure("peer connection must not be nil")
            return false
        }
        
        if multistreamEnabled && !mediaStreams.isEmpty &&
            peerConn.clientId == mediaStreamId {
            return true
        } else {
            return mediaStreams.contains {
                stream in
                return stream.mediaStreamId == mediaStreamId
            }
        }
    }
    
    func addMediaStream(_ mediaStream: MediaStream) {
        eventLog?.markFormat(type: eventType,
                             format: "add media stream '%@'",
                             arguments: mediaStream.mediaStreamId)
        if hasMediaStream(mediaStream.mediaStreamId) {
            assertionFailure("media stream already exists")
        }
        
        mediaStreams.append(mediaStream)
        onAddStreamHandler?(mediaStream)
    }
    
    func removeMediaStream(_ mediaStreamId: String) {
        eventLog?.markFormat(type: eventType, format: "remove media stream")
        var removed: MediaStream?
        mediaStreams = mediaStreams.filter {
            e in
            if e.mediaStreamId == mediaStreamId {
                removed = e
                return false
            } else {
                return true
            }
        }
        if let stream = removed {
            onRemoveStreamHandler?(stream)
        }
    }
    
    // MARK: スナップショット
    
    func render(snapshot: Snapshot) {
        eventLog?.markFormat(type: .Snapshot, format: "render snapshot")
        onSnapshotHandler?(snapshot)
        mainMediaStream?.videoRenderer?.render(videoFrame:
            SnapshotVideoFrame(snapshot: snapshot))
    }
    
    // MARK: イベントハンドラ
    
    private var onConnectHandler: ((ConnectionError?) -> Void)?
    private var onDisconnectHandler: ((ConnectionError?) -> Void)?
    private var onFailureHandler: ((ConnectionError) -> Void)?
    private var onAddStreamHandler: ((MediaStream) -> Void)?
    private var onRemoveStreamHandler: ((MediaStream) -> Void)?
    var onAttendeeAddedHandler: ((Attendee) -> Void)?
    var onAttendeeRemovedHandler: ((Attendee) -> Void)?
    private var onChangeNumberOfConnectionsHandler: ((Int, Int) -> Void)?
    private var onSnapshotHandler: ((Snapshot) -> Void)?

    public func onConnect(handler: @escaping (ConnectionError?) -> Void) {
        onConnectHandler = handler
    }
    
    func callOnConnectHandler(_ error: ConnectionError? = nil) {
        onConnectHandler?(error)
        NotificationCenter
            .default
            .post(name: Connection.NotificationKey.onConnect,
                  object: connection,
                  userInfo:
                [Connection.NotificationKey.UserInfo.connectionError: error as Any,
                 Connection.NotificationKey.UserInfo.mediaConnection: self])
    }
    
    public func onDisconnect(handler: @escaping (ConnectionError?) -> Void) {
        onDisconnectHandler = handler
    }
    
    func callOnDisconnectHandler(_ error: ConnectionError?) {
        onDisconnectHandler?(error)
        NotificationCenter
            .default
            .post(name: Connection.NotificationKey.onDisconnect,
                  object: connection,
                  userInfo:
                [Connection.NotificationKey.UserInfo.connectionError: error as Any,
                 Connection.NotificationKey.UserInfo.mediaConnection: self])
        NotificationCenter
            .default
            .post(name: MediaConnection.NotificationKey.onDisconnect,
                  object: self,
                  userInfo:
                [MediaConnection.NotificationKey.UserInfo
                    .connectionError: error as Any])
    }
    
    public func onFailure(handler: @escaping (ConnectionError) -> Void) {
        onFailureHandler = handler
    }
    
    func callOnFailureHandler(_ error: ConnectionError) {
        onFailureHandler?(error)
        NotificationCenter
            .default
            .post(name: Connection.NotificationKey.onFailure,
                  object: connection,
                  userInfo:
                [Connection.NotificationKey.UserInfo.connectionError: error as Any,
                 Connection.NotificationKey.UserInfo.mediaConnection: self])
        NotificationCenter
            .default
            .post(name: MediaConnection.NotificationKey.onFailure,
                  object: self,
                  userInfo:
                [MediaConnection.NotificationKey.UserInfo
                    .connectionError: error as Any])
    }
    
    public func onAddStream(handler: @escaping (MediaStream) -> Void) {
        onAddStreamHandler = handler
    }
    
    public func onRemoveStream(handler: @escaping (MediaStream) -> Void) {
        onRemoveStreamHandler = handler
    }
    
    public func onAttendeeAdded(handler: @escaping (Attendee) -> Void) {
        onAttendeeAddedHandler = handler
    }
    
    public func onAttendeeRemoved(handler: @escaping (Attendee) -> Void) {
        onAttendeeRemovedHandler = handler
    }
    
    public func onChangeNumberOfConnections(handler: @escaping (Int, Int) -> Void) {
        onChangeNumberOfConnectionsHandler = handler
    }

    public func onSnapshot(handler: @escaping (Snapshot) -> Void) {
        onSnapshotHandler = handler
    }
    
}

public class MediaPublisher: MediaConnection {
    
    public var canUseBackCamera: Bool? {
        get { return mediaCapturer?.videoCaptureSource.canUseBackCamera }
    }
    
    public var captureSession: AVCaptureSession? {
        get { return mediaCapturer?.videoCaptureSource.captureSession }
    }

    var _cameraPosition: CameraPosition?
    
    public var cameraPosition: CameraPosition? {
        
        get {
            if mediaCapturer != nil {
                if _cameraPosition == nil {
                    _cameraPosition = .front
                }
            } else {
                _cameraPosition = nil
            }
            return _cameraPosition
        }
        
        set {
            if let capturer = mediaCapturer {
                if let value = newValue {
                    eventLog?.markFormat(type: eventType,
                                         format: "switch camera to %@",
                                         arguments: value.rawValue)
                    switch value {
                    case .front:
                        capturer.videoCaptureSource.useBackCamera = false
                    case .back:
                        capturer.videoCaptureSource.useBackCamera = true
                    }
                    _cameraPosition = newValue
                }
            }
        }
        
    }
    
    public var autofocusEnabled = false {
        didSet {
            if let session = captureSession {
                for input in session.inputs {
                    if let device = input as? AVCaptureDevice {
                        if autofocusEnabled {
                            device.focusMode = .autoFocus
                        } else {
                            device.focusMode = .locked
                        }
                    }
                }
            }
        }
    }
    
    public var microphoneEnabled: Bool? {
        
        get {
            guard let capturer = mediaCapturer else { return nil }
            guard let stream = mainMediaStream else { return nil }
            return stream.nativeMediaStream.audioTracks
                .contains(capturer.audioCaptureTrack)
        }
        
        set {
            guard let capturer = mediaCapturer else { return }
            guard let stream = mainMediaStream else { return }
            
            let hasTrack = stream.nativeMediaStream.audioTracks
                .contains(capturer.audioCaptureTrack)
            switch newValue {
            case nil:
                break
                
            case true?:
                if !hasTrack {
                    stream.nativeMediaStream.addAudioTrack(capturer.audioCaptureTrack)
                }
                
            case false?:
                if hasTrack {
                    stream.nativeMediaStream.removeAudioTrack(capturer.audioCaptureTrack)
                }
            }
        }
        
    }
    
    override var eventType: Event.EventType {
        get { return .MediaPublisher }
    }
    
    override var role: Role {
        get { return .publisher }
    }
    
    var mediaCapturer: MediaCapturer? {
        get { return peerConnection?.mediaCapturer }
    }

    override func internalOnConnect() {
        autofocusEnabled = false
    }
    
    public func flipCameraPosition() {
        cameraPosition = cameraPosition?.flip()
    }
    
}

public class MediaSubscriber: MediaConnection {
    
    override var role: Role {
        get { return .subscriber }
    }
    
}
