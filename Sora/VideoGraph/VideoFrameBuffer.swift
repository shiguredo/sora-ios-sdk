import Foundation
import WebRTC

public enum VideoFrameBuffer {
    case rtcFrame(RTCVideoFrame)
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVPixelBuffer)
    case empty

    public var pixelBuffer: CVPixelBuffer? {
        switch self {
        case let .rtcFrame(frame):
            return (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer
        case let .sampleBuffer(buffer):
            return CMSampleBufferGetImageBuffer(buffer)
        case let .pixelBuffer(buffer):
            return buffer
        case .empty:
            return nil
        }
    }

    public var frame: VideoFrame? {
        switch self {
        case let .rtcFrame(frame):
            return VideoFrame.native(capturer: nil, frame: frame)
        case let .sampleBuffer(buffer):
            return VideoFrame(from: buffer)
        case let .pixelBuffer(buffer):
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: buffer)
            // TODO: timestamp
            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: 0)
            return VideoFrame.native(capturer: nil, frame: rtcFrame)
        case .empty:
            return nil
        }
    }
}

public struct VideoFrameFormat {}