import Foundation
import WebRTC

public protocol VideoRenderer: class {
    
    func onChangedSize(_ size: CGSize)
    func renderFrame(_ frame: VideoFrame?)
    
}

public class VideoRendererAdapter: NSObject, RTCVideoRenderer {
    
    public weak var videoRenderer: VideoRenderer?
    
    public func setSize(_ size: CGSize) {
        if let renderer = videoRenderer {
            Logger.debug(type: .videoRenderer,
                      message: "set size \(size) for \(renderer)")
            DispatchQueue.main.async {
                renderer.onChangedSize(size)
            }
        }
    }
    
    public func renderFrame(_ frame: RTCVideoFrame?) {
        DispatchQueue.main.async {
            if let renderer = self.videoRenderer {
                if let frame = frame {
                    let frame = VideoFrame.native(capturer: nil, frame: frame)
                    renderer.renderFrame(frame)
                } else {
                    renderer.renderFrame(nil)
                }
            }
        }
    }
    
}
