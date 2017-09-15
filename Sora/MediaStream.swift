import Foundation
import WebRTC

public class MediaStream {
    
    public struct NotificationKey {
        
        public enum UserInfo: String {
            case seconds = "Sora.MediaStream.UserInfo.seconds"
        }
        
        public static var onCountUp =
            Notification.Name("Sora.MediaStream.Notification.onCountUp")
        
    }
    
    static var defaultStreamId: String = "mainStream"
    static var defaultVideoTrackId: String = "mainVideo"
    static var defaultAudioTrackId: String = "mainAudio"
    
    public weak var peerConnection: PeerConnection?
    public var nativeMediaStream: RTCMediaStream
    public var creationTime: Date

    var eventLog: EventLog? {
        get { return peerConnection?.eventLog }
    }
    
    public var isAvailable: Bool {
        get { return peerConnection?.isAvailable ?? false }
    }
    
    public var mediaStreamId: String {
        get { return nativeMediaStream.streamId }
    }
    
    public var nativeVideoTrack: RTCVideoTrack? {
        get { return nativeMediaStream.videoTracks.first }
    }
    
    public var nativeAudioTrack: RTCAudioTrack? {
        get { return nativeMediaStream.audioTracks.first }
    }
    
    public var videoRenderer: VideoRenderer? {
        
        get {
            return videoRendererAdapter?.videoRenderer
        }
        
        set {
            if let value = newValue {
                videoRendererAdapter = VideoRendererAdapter(videoRenderer: value)
            } else {
                videoRendererAdapter = nil
            }
        }
        
    }
    
    var videoRendererAdapter: VideoRendererAdapter? {
        
        willSet {
            guard let videoTrack = nativeVideoTrack else { return }
            guard let adapter = videoRendererAdapter else { return }
            eventLog?.markFormat(type: .VideoRenderer,
                                 format: "remove old video renderer %@",
                                 arguments: adapter.videoRenderer as! CVarArg)
            videoTrack.remove(adapter)
        }
        
        didSet {
            guard let videoTrack = nativeVideoTrack else { return }
            guard let adapter = videoRendererAdapter else { return }
            eventLog?.markFormat(type: .VideoRenderer,
                                 format: "set video renderer %@",
                                 arguments: adapter.videoRenderer as! CVarArg)
            videoTrack.add(adapter)
        }
    
    }

    init(peerConnection: PeerConnection, nativeMediaStream: RTCMediaStream) {
        self.peerConnection = peerConnection
        self.nativeMediaStream = nativeMediaStream
        creationTime = Date()
    }
    
    func terminate() {
        stopConnectionTimer()
    }
    
    // MARK: タイマー
    
    var connectionTimer: Timer?
    var connectionTimerHandler: ((Int?) -> Void)?
    var connectionTimerForNotification: Timer?
    
    public func startConnectionTimer(timeInterval: TimeInterval,
                                     handler: @escaping ((Int?) -> Void)) {
        eventLog?.markFormat(type: .MediaStream,
                             format: "start timer (interval %f)",
                             arguments: timeInterval)
        connectionTimerHandler = handler
        
        connectionTimer?.invalidate()
        connectionTimer = Timer(timeInterval: timeInterval, repeats: true) {
            timer in
            self.updateConnectionTime(timer)
        }
        updateConnectionTime(connectionTimer!)
        RunLoop.main.add(connectionTimer!, forMode: .commonModes)
        
        connectionTimerForNotification?.invalidate()
        connectionTimerForNotification = Timer(timeInterval: 1.0, repeats: true) {
            timer in
            self.updateConnectionTimeForNotification(
                self.connectionTimerForNotification!)
        }
        updateConnectionTime(connectionTimerForNotification!)
        RunLoop.main.add(connectionTimerForNotification!, forMode: .commonModes)
    }
    
    func updateConnectionTime(_ timer: Timer) {
        if isAvailable {
            let diff = Date(timeIntervalSinceNow: 0)
                .timeIntervalSince(self.creationTime)
            connectionTimerHandler?(Int(diff))
        } else {
            connectionTimerHandler?(nil)
        }
    }
    
    func updateConnectionTimeForNotification(_ timer: Timer) {
        var seconds: Int?
        if isAvailable {
            let diff = Date(timeIntervalSinceNow: 0)
                .timeIntervalSince(self.creationTime)
            seconds = Int(diff)
        }
        NotificationCenter
            .default
            .post(name: MediaStream.NotificationKey.onCountUp,
                  object: self,
                  userInfo:
                [MediaStream.NotificationKey.UserInfo.seconds: seconds as Any])
    }
    
    public func stopConnectionTimer() {
        eventLog?.markFormat(type: .MediaStream, format: "stop timer")
        connectionTimer?.invalidate()
        connectionTimer = nil
        connectionTimerHandler = nil
    }
    
}
