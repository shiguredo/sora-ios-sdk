import Foundation
import WebRTC

public class VideoStreamInputNode: VideoInputNode {
    public private(set) weak var stream: MediaStream?

    public override init() {
        super.init()
    }
    
    public init(_ stream: MediaStream) {
        self.stream = stream
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
