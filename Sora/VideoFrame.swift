import Foundation
import CoreMedia
import WebRTC

public enum VideoFrameHandle {
    case WebRTC(RTCVideoFrame)
    case snapshot(Snapshot)
}

public protocol VideoFrame {

    var videoFrameHandle: VideoFrameHandle? { get }
    var width: Int { get }
    var height: Int { get }
    var timestamp: CMTime? { get }

}

class RemoteVideoFrame: VideoFrame {
    
    var nativeVideoFrame: RTCVideoFrame
    
    var videoFrameHandle: VideoFrameHandle? {
        get { return VideoFrameHandle.WebRTC(nativeVideoFrame) }
    }

    var width: Int {
        get { return Int(nativeVideoFrame.width) }
    }
    
    var height: Int {
        get { return Int(nativeVideoFrame.height) }
    }
    
    var timestamp: CMTime? {
        get { return CMTimeMake(nativeVideoFrame.timeStampNs, 1000000000) }
    }
    
    init(nativeVideoFrame: RTCVideoFrame) {
        self.nativeVideoFrame = nativeVideoFrame
    }
    
}

class SnapshotVideoFrame: VideoFrame {
    
    var snapshot: Snapshot
    
    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }
    
    public var videoFrameHandle: VideoFrameHandle? {
        get { return VideoFrameHandle.snapshot(snapshot) }
    }
    
    public var width: Int {
        get { return snapshot.image.width }
    }
    
    public var height: Int {
        get { return snapshot.image.height }
    }
    
    public var timestamp: CMTime? {
        get { return nil }
    }

}
