import Foundation
import WebRTC

// カメラから映像を取得し、グラフに渡すノード
public class VideoCameraInputNode: VideoInputNode {
    private static var sharedNodes: [VideoCameraInputNode] = []

    static func register(_ node: VideoCameraInputNode) {
        Logger.debug(type: .videoGraph, message: "activate VideoCameraInputNode")
        sharedNodes.append(node)
    }

    static func unregister(_ node: VideoCameraInputNode) {
        Logger.debug(type: .videoGraph, message: "deactivate VideoCameraInputNode")
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

    override public func start() async {
        await super.start()
        Logger.debug(type: .videoGraph, message: "start VideoCameraInputNode")
        CameraVideoCapturer.destination = .videoGraph
    }

    override public func stop() async {
        await super.stop()
        Logger.debug(type: .videoGraph, message: "stop VideoCameraInputNode")
        CameraVideoCapturer.destination = .stream
    }
}
