import Foundation
import WebRTC

public class VideoCameraInputNode: VideoInputNode {
    private static var sharedNodes: [VideoCameraInputNode] = []

    static func register(_ node: VideoCameraInputNode) {
        sharedNodes.append(node)
    }

    static func unregister(_ node: VideoCameraInputNode) {
        sharedNodes.remove(node)
    }

    static func onCapture(_ buffer: VideoFrameBuffer) {
        NSLog("onCapture, nodes \(VideoCameraInputNode.sharedNodes.count)")
        for node in VideoCameraInputNode.sharedNodes {
            print("\(node) isRunning \(node.state.isRunning)")
            guard node.state.isRunning else {
                return
            }

            print("# oncapture: supply frame")
            node.graph?.supplyFrameBuffer(buffer, from: node)
        }
    }
}
