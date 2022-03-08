import Foundation
import WebRTC

public protocol VideoNodeProtocol {
    func prepare()
    func start()
    func processFrameBuffer(_ frame: VideoFrameBuffer?) -> VideoFrameBuffer?
}

open class VideoNode: NSObject, VideoNodeProtocol {
    public private(set) var isRunning = false
    weak var graph: VideoGraph?

    override public init() {}

    open func prepare() {
        NSLog("\(self) prepare")
    }

    open func start() {
        NSLog("\(self) start")
        isRunning = true
    }

    open func stop() {
        isRunning = false
    }

    open func processFrameBuffer(_ buffer: VideoFrameBuffer?) -> VideoFrameBuffer? {
        buffer
    }
}
