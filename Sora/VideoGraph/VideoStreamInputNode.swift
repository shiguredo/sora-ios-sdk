import Foundation
import WebRTC

// 受信ストリームが受信した映像をグラフに渡すノード
public class VideoStreamInputNode: VideoInputNode {
    // 受信ストリーム
    public private(set) weak var stream: MediaStream?

    public override init() {
        super.init()
    }
    
    deinit {
        stream?.removeVideoStreamInputNode(self)
    }

    override public func prepare() async {
        await super.prepare()
        stream?.addVideoStreamInputNode(self)
    }

    override public func reset() async {
        await super.reset()
        stream?.removeVideoStreamInputNode(self)
    }
}

extension VideoStreamInputNode: RTCVideoRenderer {
    public func setSize(_ size: CGSize) {
        // TODO
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {
        let buffer: VideoFrameBuffer
        if let frame = frame {
            buffer = .native(frame)
        } else {
            buffer = .empty
        }
        graph?.supplyFrameBuffer(buffer, from: self)
    }
}
