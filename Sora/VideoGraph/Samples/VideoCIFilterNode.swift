import Foundation
import WebRTC

// Core Image Filter を使うノードのサンプル
public class VideoCIFilterNode: VideoNode {
    // バッファに適用するフィルター
    public var filter: CIFilter?

    override public init() {
        super.init()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        guard let buffer = buffer else {
            return nil
        }
        guard let filter = filter else {
            return buffer
        }

        // ここでは一番簡単なCore Imageを使ったフィルタリングを実装しています。
        // 大本のビデオフレームバッファ (CMSampleBuffer) から画像フレームバッファ (CVPixelBuffer) を取りだし、
        // Core ImageのCIImageに変換して、フィルタをかけます。
        // 最後にフィルタリングされたCIImageをCIContext経由で元々の画像フレームバッファ領域に上書きレンダリングしています。
        // 元々の画像フレームバッファ領域に直接上書きしているので、大本のビデオフレームバッファをそのまま引き続き使用することができ、
        // 最終的にはこのビデオフレームバッファをSora SDKの提供するVideoFrameに変換して配信することができます。

        guard let pixelBuffer = buffer.pixelBuffer else {
            return buffer
        }
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        filter.setValue(cameraImage, forKey: kCIInputImageKey)
        guard let filteredImage = filter.outputImage else {
            return buffer
        }
        let context = CIContext(options: nil)
        context.render(filteredImage, to: pixelBuffer)
        return buffer
    }
}
