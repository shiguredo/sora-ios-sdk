import Foundation
import WebRTC

/**
 映像の描画に必要な機能を定義したプロトコルです。
 */
public protocol VideoRenderer: class {
    
    /**
     映像のサイズが変更されたときに呼ばれます。
     
     - parameter size: 変更後のサイズ
     */
    func onChangedSize(_ size: CGSize)
    
    /**
     映像フレームを描画します。
     
     - parameter videoFrame: 描画する映像フレーム
     */
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
