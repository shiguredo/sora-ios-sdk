import Foundation
import WebRTC

public class VideoViewOutputNode: VideoOutputNode {
    public weak var videoView: VideoView?

    public override init() {
        super.init()
    }
    
    public init(_ videoView: VideoView) {
        self.videoView = videoView
        // TODO: ストリームを経由しないので、明示的に start() しないといけない
        videoView.start()
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
