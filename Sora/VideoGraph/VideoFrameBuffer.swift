import Foundation
import WebRTC

// 映像フレームのデータを保持するバッファ
// データの内容は供給元によって異なるが、いずれのデータでも CVPixelBuffer を取得できる
// 映像の処理は CVPixelBuffer を操作すればよい
public enum VideoFrameBuffer {
    case native(RTCVideoFrame)
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVPixelBuffer)
    case empty

    public var pixelBuffer: CVPixelBuffer? {
        switch self {
        case let .native(frame):
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
        case let .native(frame):
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
