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

    static func onCapture(_ frame: RTCVideoFrame) {
        NSLog("onCapture, nodes \(VideoCameraInputNode.sharedNodes.count)")
        for node in VideoCameraInputNode.sharedNodes {
            print("\(node) isRunning \(node.isRunning)")
            guard node.isRunning else {
                return
            }
            let buffer = VideoFrameBuffer(nativeFrame: frame, sampleBuffer: nil)
            node.queue.async {
                print("# oncapture: supply frame")
                node.graph?.supplyFrameBuffer(buffer, by: node)
            }
        }
    }

    public private(set) var queue: DispatchQueue

    override init() {
        queue = DispatchQueue(label: "CameraVideoInputNode")
        super.init()
    }
}
