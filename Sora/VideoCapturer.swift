import Foundation
import WebRTC

public class VideoCapturerHandlers {
    
    public var onCaptureHandler: ((VideoFrame) -> Void)?
    
}

// - MediaStream.videoCapturer に VideoCapturer をセットする
//   - VideoCapturer.stream に MediaStream がセットされる
// - MediaStream.render(videoFrame:) にフレームを渡すと描画される
//   - フレームは描画前に VideoFilter によって変換される
public protocol VideoCapturer {
    
    weak var stream: MediaStream? { get set }
    var handlers: VideoCapturerHandlers { get }
    
    func start()
    func stop()
    
}

public protocol VideoFilter {
    
    func filter(videoFrame: VideoFrame) -> VideoFrame
    
}
