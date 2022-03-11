import Foundation
import WebRTC

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

    public func attach(_ node: VideoNode) {
        if attachedNodeDescriptions[node] == nil {
            attachedNodeDescriptions[node] = NodeDescription(node)
            node.graph = self
        }
    }

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

    public func connect(_ source: VideoNode, to destination: VideoNode, format: VideoFrameFormat? = nil) {
        guard let sourceDesc = attachedNodeDescriptions[source] else {
            // TODO: warning
            return
        }
        guard let destDesc = attachedNodeDescriptions[destination] else {
            // TODO: warning
            return
        }

        let connection = NodeConnection(source: sourceDesc, destination: destDesc, format: format)
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
        guard !isRunning else {
            return
        }

        await iterate {
            if $0.state == .ready {
                await $0.start()
                $0.state = .running
            }
        }
        isRunning = true
    }

    public func pause() async {
        await iterate {
            if $0.state == .running {
                await $0.pause()
                $0.state = .ready
            }
        }
    }

    public func stop() async {
        await iterate {
            if $0.state == .running {
                await $0.stop()
                $0.state = .notReady
            }
        }
    }

    public func reset() async {
        await iterate {
            if $0.state == .running {
                await $0.stop()
                $0.state = .notReady
            }
        }
    }

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
                let context = Context(parent: nil, graph: self, nodeDescription: desc)
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
                nextBuffer = await node.processFrameBuffer(buffer)
            case .passthrough:
                break
            case .block:
                return
            }
            for conn in desc.connections {
                // TODO: ここでフォーマット
                let nextContext = Context(parent: context, graph: self, nodeDescription: desc)
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
        var format: VideoFrameFormat?

        init(source: NodeDescription, destination: NodeDescription, format: VideoFrameFormat?) {
            self.source = source
            self.destination = destination
            self.format = format
        }
    }

    public class Context {
        public var parent: Context?
        public var isRoot: Bool {
            parent == nil
        }

        public var graph: VideoGraph

        public var node: VideoNode {
            nodeDescription.node
        }

        var nodeDescription: NodeDescription

        init(parent: Context?, graph: VideoGraph, nodeDescription: NodeDescription) {
            self.parent = parent
            self.graph = graph
            self.nodeDescription = nodeDescription
        }
    }
}
