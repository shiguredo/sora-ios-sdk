import Foundation
import WebRTC
import Accelerate

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

private extension RTCI420Buffer {

    var pixelBuffer: CVPixelBuffer? { nil }

    // https://gist.github.com/JoshuaSullivan/765ba8cfb03ca7bbf14ef68731872750#file-capturedimagesampler-swift-L25-L30
    private static var conversionMatrix: vImage_YpCbCrToARGB = {
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
        var matrix = vImage_YpCbCrToARGB()
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &matrix, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, UInt32(kvImageNoFlags))
        return matrix
    }()

    /*
     // I420 -> ARGB に変換してから CVPixelBuffer を生成する
     // クラッシュする
    var pixelBuffer: CVPixelBuffer? {
        let dataYPointer = UnsafeMutableRawPointer(mutating: dataY)
        let dataUPointer = UnsafeMutableRawPointer(mutating: dataU)
        let dataVPointer = UnsafeMutableRawPointer(mutating: dataV)
        let vImageHeight = vImagePixelCount(height)
        let vImageWidth = vImagePixelCount(width)
        var bufferY = vImage_Buffer(data: dataYPointer, height: vImageHeight, width: vImageWidth, rowBytes: Int(strideY * height))
        var bufferU = vImage_Buffer(data: dataUPointer, height: vImageHeight, width: vImageWidth, rowBytes: Int(strideU * height))
        var bufferV = vImage_Buffer(data: dataVPointer, height: vImageHeight, width: vImageWidth, rowBytes: Int(strideV * height))
        defer {
            bufferY.free()
            bufferU.free()
            bufferV.free()
        }

        let rgbSize = Int(height * width * 4)
        let rgbDataPointer = UnsafeMutableRawPointer.allocate(byteCount: rgbSize, alignment: 8)
        defer {
            rgbDataPointer.deallocate()
        }
        var rgbBuffer = vImage_Buffer(data: rgbDataPointer, height: vImageHeight, width: vImageWidth, rowBytes: rgbSize)
     // ここでクラッシュする
        vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&bufferY, &bufferU, &bufferV, &rgbBuffer, &RTCI420Buffer.conversionMatrix, nil, 255, UInt32(kvImageNoFlags))
        defer {
            rgbBuffer.free()
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, Int(width), Int(height), kCVPixelFormatType_32ARGB, rgbDataPointer, Int(width * 4), nil, nil, nil, &pixelBuffer)
        print("# status = \(status)")
        return pixelBuffer
    }
*/

    /*
     // 以下のエラーが出る。 CVPixelBuffer は I420 データからの生成に非対応？
     // -[CIImage initWithCVPixelBuffer:options:] failed because its pixel format y420 is not supported.
    var pixelBuffer: CVPixelBuffer? {
        typealias DescriptorType = MemoryLayout<CVPlanarPixelBufferInfo_YCbCrPlanar>
        let descriptor = UnsafeMutableRawPointer.allocate(byteCount: DescriptorType.size, alignment: DescriptorType.alignment)
        defer {
            descriptor.deallocate()
        }

        let numberOfPlanes = 3
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
        baseAddrY.assign(from: dataY, count: Int(strideY))
        baseAddrU.assign(from: dataU, count: Int(strideU))
        baseAddrV.assign(from: dataV, count: Int(strideV))

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
                                                        kCVPixelFormatType_420YpCbCr8Planar,
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
     */
}
