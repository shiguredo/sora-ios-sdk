import Foundation
import WebRTC

// 映像ノードのグラフを管理するオブジェクト
// グラフを使うと、映像の受信元・配信先の選択や映像の加工の流れを制御できる
// 映像の加工処理はノードとして実装する
//
// ## 基本的な使い方
// 入力ノード -> 任意のノード -> 出力ノードの順で接続する
// 入力ノードは、カメラや受信ストリームから映像フレームのデータ (バッファ) を取得する
// バッファは接続先のノードに渡される
// 出力ノードは、前のノードで処理されたバッファを受け取って配信ストリームや映像ビューに出力する
//
// ## API の基本的な使い方
// - VideoGraph オブジェクトを生成する
// - attach() でグラフにノードを追加する
// - connect() でノード同士を接続する
// - start() で実行を開始する
//
// ## パフォーマンスについて
// - フィルタを複数接続するとパフォーマンスが大きく低下する可能性がある。その場合は映像処理を GPU で行うようにするか、複数のノードに分散せずに一つのノードで処理するように実装を変更するとよい
// - ノードは個別に無効にできる。一時的にのみ使うノードは、使うタイミングが来るまで処理をスルーする設定にしておくとよい
public final class VideoGraph {
    public var attachedNodes: [VideoNode] {
        Array(attachedNodeDescriptions.keys)
    }

    private var attachedNodeDescriptions: [VideoNode: NodeDescription] = [:]

    private var nodeConnections: [NodeConnection] = []

    private var rootNodeDescriptions: Set<NodeDescription> {
        Set(attachedNodeDescriptions.values.filter(\.isRoot))
    }

    public private(set) var isRunning = false

    private var rootContexts: [Context] = []

    // カメラ入力ノード
    // グラフを開始すると、カメラから配信ストリームへの映像の送信が停止する (二重に配信されてしまうため)
    public private(set) var cameraInputNode: VideoCameraInputNode

    public init() {
        cameraInputNode = VideoCameraInputNode()
        VideoCameraInputNode.register(cameraInputNode)
    }

    deinit {
        VideoCameraInputNode.unregister(cameraInputNode)
        Task {
            await reset()
        }
    }

    // ノードを追加する
    public func attach(_ node: VideoNode) {
        if attachedNodeDescriptions[node] == nil {
            attachedNodeDescriptions[node] = NodeDescription(node)
            node.graph = self
        }
    }

    // ノードを削除する
    public func detach(_ node: VideoNode) {
        guard let desc = attachedNodeDescriptions[node] else {
            return
        }

        attachedNodeDescriptions[node] = nil
        node.graph = nil

        // 関連するすべての接続を削除する
        nodeConnections = nodeConnections.filter {
            $0.source == desc || $0.destination == desc
        }
        for conn in desc.connections {
            conn.destination.inverseConnections = conn.destination.inverseConnections.filter {
                $0.source == desc
            }
        }
        for conn in desc.inverseConnections {
            conn.source.connections = conn.source.connections.filter {
                $0.destination == desc
            }
        }
    }

    // ノード同士を接続する
    public func connect(_ source: VideoNode, to destination: VideoNode) {
        guard let sourceDesc = attachedNodeDescriptions[source] else {
            // TODO: warning
            return
        }
        guard let destDesc = attachedNodeDescriptions[destination] else {
            // TODO: warning
            return
        }

        let connection = NodeConnection(source: sourceDesc, destination: destDesc)
        sourceDesc.add(connection)
        nodeConnections.append(connection)
    }

    private func iterate(block: @escaping (VideoNode) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for node in attachedNodes {
                group.addTask {
                    await block(node)
                }
            }
            await group.waitForAll()
        }
    }

    public func prepare() async {
        await iterate {
            if $0.state == .notReady {
                await $0.prepare()
                $0.state = .ready
            }
        }
    }

    public func start() async {
        Logger.debug(type: .videoGraph, message: "try start")
        guard !isRunning else {
            Logger.debug(type: .videoGraph, message: "already running")
            return
        }

        await iterate {
            if $0.state == .notReady {
                await $0.prepare()
                $0.state = .ready
            }
            if $0.state == .ready {
                await $0.start()
                $0.state = .running
            }
        }
        isRunning = true
        Logger.debug(type: .videoGraph, message: "did start")
    }

    public func pause() async {
        Logger.debug(type: .videoGraph, message: "try pause")
        guard isRunning else {
            Logger.debug(type: .videoGraph, message: "not running")
            return
        }
        await iterate {
            if $0.state == .running {
                await $0.pause()
                $0.state = .ready
            }
        }
        Logger.debug(type: .videoGraph, message: "did pause")
    }

    public func stop() async {
        Logger.debug(type: .videoGraph, message: "try stop")
        await iterate {
            if $0.state == .running {
                await $0.stop()
                $0.state = .notReady
            }
        }
        Logger.debug(type: .videoGraph, message: "did stop")
    }

    public func reset() async {
        Logger.debug(type: .videoGraph, message: "reset")
        await iterate {
            if $0.state == .ready {
                await $0.reset()
                $0.state = .notReady
            }
        }
    }

    // ノードにバッファを供給する
    public func supplyFrameBuffer(_ buffer: VideoFrameBuffer, from node: VideoInputNode) {
        print("VideoGraph: supply frame, is running \(isRunning)")
        guard isRunning else {
            return
        }
        guard let desc = attachedNodeDescriptions[node] else {
            return
        }

        Task {
            for conn in desc.connections {
                let context = Context(parent: nil, graph: self, sourceDescription: desc)
                self.processFrameBuffer(buffer, with: conn.destination.node, in: context)
            }
        }
    }

    func processFrameBuffer(_ buffer: VideoFrameBuffer?, with node: VideoNode, in context: Context) {
        guard isRunning else {
            return
        }
        guard let desc = attachedNodeDescriptions[node] else {
            return
        }

        Task {
            var nextBuffer = buffer
            switch node.mode {
            case .process:
                nextBuffer = await node.processFrameBuffer(buffer, in: context)
            case .passthrough:
                break
            case .block:
                return
            }
            for conn in desc.connections {
                // TODO: ここでフォーマット
                let nextContext = Context(parent: context, graph: self, sourceDescription: desc)
                self.processFrameBuffer(nextBuffer, with: conn.destination.node, in: nextContext)
            }
        }
    }

    class NodeDescription: NSObject {
        var node: VideoNode

        // source -> destination
        var connections: [NodeConnection] = []

        // destination -> source
        var inverseConnections: [NodeConnection] = []

        var isRoot: Bool {
            inverseConnections.isEmpty
        }

        init(_ node: VideoNode) {
            self.node = node
        }

        func add(_ connection: NodeConnection) {
            if connection.source == self {
                connections.append(connection)
            } else {
                connection.destination.inverseConnections.append(connection)
            }
        }
    }

    class NodeConnection: NSObject {
        var source: NodeDescription
        var destination: NodeDescription

        init(source: NodeDescription, destination: NodeDescription) {
            self.source = source
            self.destination = destination
        }
    }

    // グラフの実行中の情報
    public class Context {
        public var parent: Context?
        public var isRoot: Bool {
            parent == nil
        }

        public var graph: VideoGraph

        // 直前の接続元のノード
        public var source: VideoNode {
            sourceDescription.node
        }

        var sourceDescription: NodeDescription

        init(parent: Context?, graph: VideoGraph, sourceDescription: NodeDescription) {
            self.parent = parent
            self.graph = graph
            self.sourceDescription = sourceDescription
        }
    }
}
