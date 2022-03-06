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

    private var isReady = false

    private var runningContexts: [Context] = []

    public private(set) var cameraInputNode: VideoCameraInputNode

    public init() {
        cameraInputNode = VideoCameraInputNode()
        VideoCameraInputNode.register(cameraInputNode)
    }

    deinit {
        VideoCameraInputNode.unregister(cameraInputNode)
    }

    public func attach(_ node: VideoNode) {
        if attachedNodeDescriptions[node] == nil {
            attachedNodeDescriptions[node] = NodeDescription(node)
            node.graph = self
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

    public func prepare() {
        for root in rootNodeDescriptions {
            let context = Context(graph: self, root: root)
            runningContexts.append(context)
            context.queue.async {
                root.node.prepare()
            }
        }
        isReady = true
    }

    public func start() {
        if !isReady {
            prepare()
        }

        isRunning = true
        for context in runningContexts {
            context.queue.async {
                context.root.node.start()
            }
        }
    }

    func supplyFrame(_ frame: VideoFrameBuffer, by node: VideoInputNode) {
        print("VideoGraph: supply frame, is running \(isRunning)")
        guard isRunning else {
            return
        }
        renderFrame(frame, with: node)
    }

    func renderFrame(_ frame: VideoFrameBuffer?, with node: VideoNode) {
        guard isRunning else {
            return
        }
        guard let desc = attachedNodeDescriptions[node] else {
            return
        }
        guard let context = runningContexts.first(where: { $0.root.node == node }) else {
            return
        }

        if desc.connections.isEmpty {
            print("# renderFrame, last node, \(node)")
            _ = node.renderFrame(frame)
        } else {
            for conn in desc.connections {
                context.queue.async {
                    print("# render frame, next node")
                    self.renderFrame(frame, connection: conn, in: context)
                }
            }
        }
    }

    func renderFrame(_ frame: VideoFrameBuffer?, connection: NodeConnection, in context: Context) {
        // TODO: format
        print("VideoGraph: renderFrame, source \(connection.source.node), \(connection.destination.node)")
        let newFrame = connection.source.node.renderFrame(frame)
        // TODO: ここでフォーマット
        renderFrame(newFrame, with: connection.destination.node)
    }

    class NodeDescription: NSObject {
        var node: VideoNode

        // source, destination 両方
        var connections: [NodeConnection] = []
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
                inverseConnections.append(connection)
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
        public var graph: VideoGraph
        public var queue: DispatchQueue
        var root: NodeDescription

        init(graph: VideoGraph, root: NodeDescription) {
            self.graph = graph
            self.root = root
            queue = DispatchQueue(label: "VideoGraph.Context")
        }
    }
}
