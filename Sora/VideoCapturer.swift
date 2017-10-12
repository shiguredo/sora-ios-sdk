import Foundation
import WebRTC

/**
 映像キャプチャーのイベントハンドラです。
 */
public final class VideoCapturerHandlers {
    
    /// 映像フレームの生成時に呼ばれるブロック
    public var onCaptureHandler: ((VideoFrame) -> Void)?
    
}

// - MediaStream.videoCapturer に VideoCapturer をセットする
//   - VideoCapturer.stream に MediaStream がセットされる
// - MediaStream.render(videoFrame:) にフレームを渡すと描画される
//   - フレームは描画前に VideoFilter によって変換される
public protocol VideoCapturer: class {
    
    /// ストリーム
    weak var stream: MediaStream? { get set }
    
    /// イベントハンドラ
    var handlers: VideoCapturerHandlers { get }
    
    /// 映像キャプチャーを起動します。
    func start()
    
    /// 映像キャプチャーを停止します。
    func stop()
    
}

public protocol VideoFilter: class {
    
    /**
     映像フレームを加工します。
     
     - parameter videoFrame: 加工前の映像フレーム
     - returns: 加工後の映像フレーム
     */
    func filter(videoFrame: VideoFrame) -> VideoFrame
    
}
