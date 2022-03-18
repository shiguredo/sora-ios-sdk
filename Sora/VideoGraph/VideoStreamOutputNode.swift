import Foundation

public class VideoStreamOutputNode: VideoOutputNode {
    public weak var stream: MediaStream?

    public override init() {
        super.init()
    }
    
    public init(_ stream: MediaStream) {
        self.stream = stream
        super.init()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        stream?.send(videoFrame: buffer?.frame)
        return buffer
    }
}
