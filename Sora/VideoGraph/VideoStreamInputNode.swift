import Foundation
import WebRTC

public class VideoStreamInputNode: VideoInputNode {
    public private(set) weak var stream: MediaStream?

    public init(_ stream: MediaStream) {
        self.stream = stream
        super.init()
        stream.addVideoStreamInputNode(self)
    }

    deinit {
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
            buffer = .rtcFrame(frame)
        } else {
            buffer = .empty
        }
        graph?.supplyFrameBuffer(buffer, from: self)
    }
}
