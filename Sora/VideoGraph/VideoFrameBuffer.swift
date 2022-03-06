import Foundation
import WebRTC

public struct VideoFrameBuffer {
    public var nativeFrame: RTCVideoFrame?
    public var sampleBuffer: CMSampleBuffer?
}

public struct VideoFrameFormat {}
