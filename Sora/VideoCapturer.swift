import Foundation
import WebRTC

/**
 映像キャプチャーのイベントハンドラです。
 */
@available(*, unavailable, message: "VideoCapturerHandlers は廃止されました。今後は CameraVideoCapturerHandlers を使用してください。")
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

public class CameraVideoCapturerHandlers {
    
    // 生成された映像フレームを受け取る
    // 返した映像フレームがストリームに渡される
    public var onCapture: ((VideoFrame) -> VideoFrame)?

    // カメラの起動時に呼ばれる
    public var onStart: (() -> Void)?
    
    // カメラの停止時に呼ばれる
    public var onStop: (() -> Void)?
    
}

/**
 映像キャプチャーの機能を定義したプロトコルです。
 生成した映像フレームを引数として `MediaStream.send(videoFrame:)` に与えると、
 映像フレームが (フィルターがセットされていれば加工されて) サーバーに送信されます。
 
 映像キャプチャーとデータの送受信は別であることに注意してください。
 映像キャプチャーが映像フレームを生成しても、
 メディアストリームなしではサーバーに映像が送信されません。
 */
public protocol VideoCapturer: AnyObject {
    
    /// 映像フレームを渡すストリーム
    var stream: MediaStream? { get set }
    
    /// イベントハンドラ
    var handlers: CameraVideoCapturerHandlers { get }
    
    /// 映像キャプチャーを起動します。
    func start(with device: AVCaptureDevice, settings: CameraVideoCapturer.Settings, completionHandler: @escaping ((Error?) -> Void))
    func start(with device: AVCaptureDevice, format: AVCaptureDevice.Format, frameRate: Int, stopWhenDone: Bool, completionHandler: @escaping ((Error?) -> Void))
    
    /// 映像キャプチャーを停止します。
    func stop(completionHandler: @escaping ((Error?) -> Void))
    
}

/**
 映像フィルターの機能を定義したプロトコルです。
 `MediaStream.videoFilter` にセットすると、
 生成された映像フレームはこのプロトコルの実装によって加工されます。
 */
public protocol VideoFilter: AnyObject {
    
    /**
     映像フレームを加工します。
     
     - parameter videoFrame: 加工前の映像フレーム
     - returns: 加工後の映像フレーム
     */
    func filter(videoFrame: VideoFrame) -> VideoFrame
    
}
