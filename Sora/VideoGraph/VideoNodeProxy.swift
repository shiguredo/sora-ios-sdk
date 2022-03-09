import Foundation
import WebRTC

public class VideoNodeProxy: VideoNode {
    public weak var node: VideoNode?

    override public init() {}

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?) async -> VideoFrameBuffer? {
        if let node = node {
            return await node.processFrameBuffer(buffer)
        } else {
            return buffer
        }
    }
}
