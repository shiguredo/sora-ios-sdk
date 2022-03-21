import Foundation
import WebRTC

// 渡されたバッファを映像ビューで描画するノード
public class VideoViewOutputNode: VideoOutputNode {
    public weak var videoView: VideoView?

    override public init() {
        super.init()
    }

    override public func start() async {
        await super.start()

        if let videoView = videoView {
            if await !videoView.isRendering {
                await videoView.start()
            }
        }
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        print("VideoViewOutputNode: frame \(buffer)")
        guard let videoView = videoView else {
            return buffer
        }
        print("# render \(videoView)")
        DispatchQueue.main.async {
            videoView.render(videoFrame: buffer?.frame)
        }
        return buffer
    }
}
