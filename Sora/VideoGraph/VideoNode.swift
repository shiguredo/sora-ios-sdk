import Foundation
import WebRTC

public protocol VideoNodeProtocol {
    var state: VideoGraph.State { get }
    func prepare() async
    func start() async
    func pause() async
    func stop() async
    func reset() async
    func processFrameBuffer(_ frame: VideoFrameBuffer?) async -> VideoFrameBuffer?
}

open class VideoNode: NSObject, VideoNodeProtocol {

    public weak var graph: VideoGraph?
    public internal(set) var state: VideoGraph.State = .notReady

    override public init() {
        super.init()
    }

    open func prepare() async {
        NSLog("\(self) prepare")
    }

    open func start() async {
        NSLog("\(self) start")
    }

    open func pause() async {}

    open func stop() async {}

    open func reset() async {}

    open func processFrameBuffer(_ buffer: VideoFrameBuffer?) async -> VideoFrameBuffer? {
        buffer
    }
}
