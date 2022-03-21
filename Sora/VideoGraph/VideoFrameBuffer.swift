import Foundation
import WebRTC

// 映像フレームのデータを保持するバッファ
// データの内容は供給元によって異なるが、いずれのデータでも CVPixelBuffer を取得できる
// 映像の処理は CVPixelBuffer を操作すればよい
public class VideoFrameBuffer {

    public enum Buffer {
    case native(RTCVideoFrame)
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVPixelBuffer)
    }

    public var buffer: Buffer?

    private var _pixelBuffer: CVPixelBuffer?

    public var pixelBuffer: CVPixelBuffer? {
        guard let buffer = buffer else {
            return nil
        }

        if _pixelBuffer == nil {
            switch buffer {
            case let .native(frame):
                if let rtcPixelBuffer = frame.buffer as? RTCCVPixelBuffer {
                    _pixelBuffer = rtcPixelBuffer.pixelBuffer
                } else if let i420Buffer = frame.buffer as? RTCI420Buffer {
                    // TODO: CVPixelBuffer に変換する
                    return nil
                } else {
                    return nil
                }
            case let .sampleBuffer(buffer):
                _pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
            case let .pixelBuffer(buffer):
                _pixelBuffer = buffer
            }
        }
        return _pixelBuffer
    }

    public var frame: VideoFrame? {
        switch buffer {
        case let .native(frame):
            return VideoFrame.native(capturer: nil, frame: frame)
        case let .sampleBuffer(buffer):
            return VideoFrame(from: buffer)
        case let .pixelBuffer(buffer):
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: buffer)
            // TODO: timestamp
            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: 0)
            return VideoFrame.native(capturer: nil, frame: rtcFrame)
        case .none:
            return nil
        }
    }

    public init() {}

    public init(_ buffer: RTCVideoFrame) {
        self.buffer = .native(buffer)
    }

    public init(_ buffer: CMSampleBuffer) {
        self.buffer = .sampleBuffer(buffer)
    }

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = .pixelBuffer(buffer)
    }

}

public struct VideoFrameFormat {}
