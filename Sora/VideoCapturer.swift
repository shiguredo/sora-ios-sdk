import Foundation
import WebRTC

/**
 映像キャプチャーのイベントハンドラです。
 廃止されました。
 */
@available(*, unavailable, message: "VideoCapturerHandlers は廃止されました。 CameraVideoCapturerHandlers を利用してください。")
public final class VideoCapturerHandlers {}

/**
 映像キャプチャーの機能を定義したプロトコルです。
 生成した映像フレームを引数として `MediaStream.send(videoFrame:)` に与えると、
 映像フレームが (フィルターがセットされていれば加工されて) サーバーに送信されます。

 映像キャプチャーとデータの送受信は別であることに注意してください。
 映像キャプチャーが映像フレームを生成しても、
 メディアストリームなしではサーバーに映像が送信されません。

 廃止されました。
 */
@available(*, unavailable, message: "VideoCapturer は廃止されました。")
public protocol VideoCapturer: AnyObject {}

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
