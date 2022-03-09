import Foundation
import WebRTC

public class VideoViewOutputNode: VideoOutputNode {
    public weak var videoView: VideoView?

    public init(_ videoView: VideoView) {
        self.videoView = videoView
        // TODO: ストリームを経由しないので、明示的に start() しないといけない
        videoView.start()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?) async -> VideoFrameBuffer? {
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
