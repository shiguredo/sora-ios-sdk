import Foundation

public class VideoStreamOutputNode: VideoOutputNode {
    public private(set) weak var stream: MediaStream?

    public init(_ stream: MediaStream) {
        self.stream = stream
        super.init()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?) async -> VideoFrameBuffer? {
        stream?.send(videoFrame: buffer?.frame)
        return buffer
    }
}
