import Foundation
import WebRTC

public class VideoViewOutputNode: VideoOutputNode {
    public weak var videoView: VideoView?

    public init(_ videoView: VideoView) {
        self.videoView = videoView
        // TODO: ストリームを経由しないので、明示的に start() しないといけない
        videoView.start()
    }

    override public func renderFrame(_ frame: VideoFrameBuffer?) -> VideoFrameBuffer? {
        print("VideoViewOutputNode: frame \(frame)")
        guard let videoView = videoView else {
            return frame
        }
        guard let frame = frame else {
            return nil
        }
        print("# render \(videoView)")
        let newFrame = VideoFrame.native(capturer: nil, frame: frame.nativeFrame!)
        DispatchQueue.main.async {
            videoView.render(videoFrame: newFrame)
        }
        return frame
    }
}
