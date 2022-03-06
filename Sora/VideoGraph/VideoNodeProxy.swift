import Foundation
import WebRTC

public class VideoNodeProxy: VideoNode {
    public weak var node: VideoNode?

    override public init() {}

    override public func renderFrame(_ frame: VideoFrameBuffer?) -> VideoFrameBuffer? {
        if let node = node {
            return node.renderFrame(frame)
        } else {
            return frame
        }
    }
}
