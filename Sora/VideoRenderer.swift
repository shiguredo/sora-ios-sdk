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
        // RTCVideoRenderer.setSize(_:) は WebRTC.framework native 側の実装により、
        // OnFrame (動画フレーム描画直前のタイミング) で呼び出されるようになっています。
        // https://chromium.googlesource.com/external/webrtc/+/master/webrtc/sdk/objc/Framework/Classes/PeerConnection/RTCVideoRendererAdapter.mm#50
        // この時の size は WebRTC 側の回転処理を施した後の正確な size が送られてきます。
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
