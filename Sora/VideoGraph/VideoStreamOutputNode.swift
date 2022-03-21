import Foundation

// 渡されたバッファを配信ストリームに出力するノード
// このノードに接続すると映像を配信できる
public class VideoStreamOutputNode: VideoOutputNode {
    public weak var stream: MediaStream?

    override public init() {
        super.init()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        stream?.send(videoFrame: buffer?.frame)
        return buffer
    }
}
