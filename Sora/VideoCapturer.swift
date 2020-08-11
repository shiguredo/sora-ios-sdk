import Foundation
import WebRTC

/**
 映像キャプチャーのイベントハンドラです。
 */
public final class VideoCapturerHandlers {
    
    /// このプロパティは onCapture に置き換えられました。
    @available(*, deprecated, renamed: "onCapture",
    message: "このプロパティは onCapture に置き換えられました。")
    public var onCaptureHandler: ((VideoFrame) -> Void)? {
        get { onCapture }
        set { onCapture = newValue }
    }
    
    /// 映像フレームの生成時に呼ばれるクロージャー
    public var onCapture: ((VideoFrame) -> Void)?

    /// 初期化します。
    public init() {}
    
}

/**
 映像キャプチャーの機能を定義したプロトコルです。
 生成した映像フレームを引数として `MediaStream.send(videoFrame:)` に与えると、
 映像フレームが (フィルターがセットされていれば加工されて) サーバーに送信されます。
 
 映像キャプチャーとデータの送受信は別であることに注意してください。
 映像キャプチャーが映像フレームを生成しても、
 メディアストリームなしではサーバーに映像が送信されません。
 */
public protocol VideoCapturer: class {
    
    /// 映像フレームを渡すストリーム
    var stream: MediaStream? { get set }
    
    /// イベントハンドラ
    var handlers: VideoCapturerHandlers { get }
    
    /// 映像キャプチャーを起動します。
    func start()
    
    /// 映像キャプチャーを停止します。
    func stop()
    
}

/**
 映像フィルターの機能を定義したプロトコルです。
 `MediaStream.videoFilter` にセットすると、
 生成された映像フレームはこのプロトコルの実装によって加工されます。
 */
public protocol VideoFilter: class {
    
    /**
     映像フレームを加工します。
     
     - parameter videoFrame: 加工前の映像フレーム
     - returns: 加工後の映像フレーム
     */
    func filter(videoFrame: VideoFrame) -> VideoFrame
    
}
