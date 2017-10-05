import Foundation
import WebRTC

public protocol VideoRenderer: class {
    
    func onChangedSize(_ size: CGSize)
    func render(videoFrame: VideoFrame?)
    
}

class VideoRendererAdapter: NSObject, RTCVideoRenderer {
    
    private(set) weak var videoRenderer: VideoRenderer?
    
    init(videoRenderer: VideoRenderer) {
        self.videoRenderer = videoRenderer
    }
    
    func setSize(_ size: CGSize) {
        if let renderer = videoRenderer {
            Logger.debug(type: .videoRenderer,
                         message: "set size \(size) for \(renderer)")
            DispatchQueue.main.async {
                renderer.onChangedSize(size)
            }
        } else {
            Logger.debug(type: .videoRenderer,
                         message: "set size \(size) IGNORED, no renderer set")
        }
    }
    
    func renderFrame(_ frame: RTCVideoFrame?) {
        DispatchQueue.main.async {
            if let renderer = self.videoRenderer {
                if let frame = frame {
                    let frame = VideoFrame.native(capturer: nil, frame: frame)
                    renderer.render(videoFrame: frame)
                } else {
                    renderer.render(videoFrame: nil)
                }
            }
        }
    }
    
}
