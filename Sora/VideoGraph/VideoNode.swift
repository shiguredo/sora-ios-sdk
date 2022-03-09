import Foundation
import WebRTC

public protocol VideoNodeProtocol {
    func prepare() async
    func start() async
    func stop() async
    func reset() async
    func processFrameBuffer(_ frame: VideoFrameBuffer?) async -> VideoFrameBuffer?
}

open class VideoNode: NSObject, VideoNodeProtocol {
    public private(set) var isRunning = false
    weak var graph: VideoGraph?

    override public init() {}

    open func prepare() async {
        NSLog("\(self) prepare")
    }

    open func start() async {
        NSLog("\(self) start")
        isRunning = true
    }

    open func stop() async {
        isRunning = false
    }

    open func reset() async {}

    open func processFrameBuffer(_ buffer: VideoFrameBuffer?) async -> VideoFrameBuffer? {
        buffer
    }
}
