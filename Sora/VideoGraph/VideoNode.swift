import Foundation
import WebRTC

public protocol VideoNodeProtocol {
    func prepare()
    func start()
    func renderFrame(_ frame: VideoFrameBuffer?) -> VideoFrameBuffer?
}

open class VideoNode: NSObject, VideoNodeProtocol {
    public private(set) var isRunning = false
    weak var graph: VideoGraph?

    public override init() {}

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

    open func renderFrame(_ frame: VideoFrameBuffer?) -> VideoFrameBuffer? {
        frame
    }
}
