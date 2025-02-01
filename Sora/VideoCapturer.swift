import Foundation
import WebRTC

/// 映像フィルターの機能を定義したプロトコルです。
/// `MediaStream.videoFilter` にセットすると、
/// 生成された映像フレームはこのプロトコルの実装によって加工されます。
public protocol VideoFilter: AnyObject {
    /**
     映像フレームを加工します。

     - parameter videoFrame: 加工前の映像フレーム
     - returns: 加工後の映像フレーム
     */
    func filter(videoFrame: VideoFrame) -> VideoFrame
}
