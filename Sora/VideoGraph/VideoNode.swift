import Foundation
import WebRTC

public protocol VideoNodeProtocol {
    var mode: VideoNode.Mode { get }
    var state: VideoNode.State { get }
    func prepare() async
    func start() async
    func pause() async
    func stop() async
    func reset() async
    func processFrameBuffer(_ frame: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer?
}

open class VideoNode: NSObject, VideoNodeProtocol {
    // 映像フレームの処理方法
    public enum Mode {
        // 処理する
        case process

        // 処理せず次のノードにバッファを渡す
        case passthrough

        // 処理せず次のノードにバッファを渡さない
        case block
    }

    public enum State {
        // prepare していない状態
        case notReady

        // prepare 済みの状態、 start 可能
        case ready

        // start 実行後
        case running

        public var isReady: Bool {
            self == .ready
        }

        public var isRunning: Bool {
            self == .running
        }
    }

    public weak var graph: VideoGraph?
    public var mode: Mode = .process
    public internal(set) var state: State = .notReady

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

    open func processFrameBuffer(_ buffer: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer? {
        buffer
    }
}
