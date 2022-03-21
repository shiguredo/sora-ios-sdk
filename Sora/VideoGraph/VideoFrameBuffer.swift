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
                    _pixelBuffer = i420Buffer.pixelBuffer
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

private extension RTCI420Buffer {
    var pixelBuffer: CVPixelBuffer? {
        typealias DescriptorType = MemoryLayout<CVPlanarPixelBufferInfo_YCbCrPlanar>
        let descriptor = UnsafeMutableRawPointer.allocate(byteCount: DescriptorType.size, alignment: DescriptorType.alignment)
        defer {
            descriptor.deallocate()
        }

        // I420 = 4
        // YUV なら 3
        let numberOfPlanes = 4

        let baseAddrs = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 3)
        // TODO: サイズは？
        let baseAddrY = UnsafeMutablePointer<UInt8>.allocate(capacity: 1000)
        let baseAddrU = UnsafeMutablePointer<UInt8>.allocate(capacity: 1000)
        let baseAddrV = UnsafeMutablePointer<UInt8>.allocate(capacity: 1000)
        defer {
            baseAddrs.deallocate()
            baseAddrY.deallocate()
            baseAddrU.deallocate()
            baseAddrV.deallocate()
        }
        baseAddrs[0] = UnsafeMutableRawPointer(baseAddrY)
        baseAddrs[1] = UnsafeMutableRawPointer(baseAddrU)
        baseAddrs[2] = UnsafeMutableRawPointer(baseAddrV)

        let planeWidths = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        let planeHeights = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        let planeBytesPerRow = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        defer {
            planeWidths.deallocate()
            planeHeights.deallocate()
            planeBytesPerRow.deallocate()
        }

        planeWidths[0] = Int(width)
        planeWidths[1] = Int(chromaWidth)
        planeWidths[2] = Int(chromaWidth)
        planeHeights[0] = Int(height)
        planeHeights[1] = Int(chromaHeight)
        planeHeights[2] = Int(chromaHeight)
        planeBytesPerRow[0] = Int(strideY)
        planeBytesPerRow[1] = Int(strideU)
        planeBytesPerRow[2] = Int(strideV)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithPlanarBytes(nil,
                                                        Int(width),
                                                        Int(height),
                                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                        descriptor,
                                                        0,
                                                        numberOfPlanes,
                                                        baseAddrs,
                                                        planeWidths,
                                                        planeHeights,
                                                        planeBytesPerRow,
                                                        nil,
                                                        nil,
                                                        nil,
                                                        &pixelBuffer)
        print("# status = \(status)")
        return pixelBuffer!
    }
}
