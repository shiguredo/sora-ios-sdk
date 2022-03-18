import Foundation
import WebRTC

public class VideoNodeProxy: VideoNode {
    public weak var node: VideoNode?

    override public init() {
        super.init()
    }

    override public func prepare() async {
        await node?.prepare()
    }

    override public func start() async {
        await node?.start()
    }

    override public func pause() async {
        await node?.pause()
    }

    override public func stop() async {
        await node?.stop()
    }

    override public func reset() async {
        await node?.reset()
    }

    override public func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        if let node = node {
            return await node.processFrameBuffer(buffer, in: context)
        } else {
            return buffer
        }
    }
}
