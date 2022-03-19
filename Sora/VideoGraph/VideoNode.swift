import Foundation
import WebRTC

// 映像ノードが実装すべき API
public protocol VideoNodeProtocol {

    // 映像フレームの処理方法
    var mode: VideoNode.Mode { get }

    // ノードの状態
    var state: VideoNode.State { get }

    // リソースを用意する
    // start() で呼ばれるので明示的に呼ばなくてもよい
    func prepare() async

    // 処理を開始する
    func start() async

    // 一時的に処理を停止する
    // prepare で確保したリソースは保持する
    func pause() async

    // 処理を停止する
    // リソースを破棄する
    func stop() async

    // リソースを破棄する
    // stop() からも呼ばれる
    func reset() async

    // 映像バッファを処理する
    // 次のノードに渡すバッファを返す
    func processFrameBuffer(_ frame: VideoFrameBuffer?, in context: VideoGraph.Context) async -> VideoFrameBuffer?
}

// 映像ノードの基礎クラス
// カスタムノードはこのクラスのサブクラスを用意する
open class VideoNode: NSObject, VideoNodeProtocol {
    // 映像フレームの処理方法
    public enum Mode {
        // 処理する
        // processFrameBuffer() が呼ばれる
        case process

        // 処理せず次のノードにバッファを渡す
        // processFrameBuffer() は呼ばれない
        case passthrough

        // 処理せず次のノードにバッファを渡さない
        // processFrameBuffer() は呼ばれない
        case block
    }

    // ノードの状態
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
