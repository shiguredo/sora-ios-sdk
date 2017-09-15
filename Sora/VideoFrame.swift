import Foundation
import CoreMedia
import WebRTC

public enum VideoFrameHandle {
    case webRTC(RTCVideoFrame)
}

public protocol VideoFrame {

    var videoFrameHandle: VideoFrameHandle? { get }
    var width: Int32 { get }
    var height: Int32 { get }
    var timestamp: CMTime { get }

}

struct RemoteVideoFrame: VideoFrame {
    
    var nativeVideoFrame: RTCVideoFrame
    
    var videoFrameHandle: VideoFrameHandle? {
        get { return VideoFrameHandle.webRTC(nativeVideoFrame) }
    }

    var width: Int32 {
        get { return nativeVideoFrame.width }
    }
    
    var height: Int32 {
        get { return nativeVideoFrame.height }
    }
    
    var timestamp: CMTime {
        get { return CMTimeMake(nativeVideoFrame.timeStampNs, 1000000000) }
    }
    
    init(nativeVideoFrame: RTCVideoFrame) {
        self.nativeVideoFrame = nativeVideoFrame
    }
    
}
