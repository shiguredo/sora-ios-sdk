import Foundation
import WebRTC

public protocol VideoRenderer: class {
    
    func onChangedSize(_ size: CGSize)
    func render(videoFrame: VideoFrame?)
    
}

class VideoRendererAdapter: NSObject, RTCVideoRenderer {
    
    weak var connection: Connection?
    weak var videoRenderer: VideoRenderer?
    
    var eventLog: EventLog? {
        get { return connection?.eventLog }
    }
    
    init(videoRenderer: VideoRenderer) {
        self.videoRenderer = videoRenderer
    }
    
    func setSize(_ size: CGSize) {
        eventLog?.markFormat(type: .VideoRenderer,
                             format: "set size %@ for %@",
                             arguments: size.debugDescription, self)
        DispatchQueue.main.async {
            self.videoRenderer?.onChangedSize(size)
        }
    }
    
    func renderFrame(_ frame: RTCVideoFrame?) {
        DispatchQueue.main.async {
            guard let renderer = self.videoRenderer else { return }
            if let frame = frame {
                let frame = RemoteVideoFrame(nativeVideoFrame: frame)
                renderer.render(videoFrame: frame)
            } else {
                renderer.render(videoFrame: nil)
            }
        }
    }
    
}
