import Foundation
import WebRTC

/// 映像フィルターの機能を定義したプロトコルです。
/// `MediaStream.videoFilter` にセットすると、
/// 生成された映像フレームはこのプロトコルの実装によって加工されます。
///
/// `filter(videoFrame:)` はストリームごとの直列 executor 上で呼ばれます。同じストリームで
/// 同時に 2 つの frame がこのメソッドへ入ることはありません。同じ instance を複数の
/// ストリームへセットした場合はストリームごとに直列化されるため、排他は利用者の責任です。
/// 交換と frame 入力の関係は `MediaStream.videoFilter` の doc を参照してください。
public protocol VideoFilter: AnyObject {
  /// 映像フレームを加工します。
  /// - parameter videoFrame: 加工前の映像フレーム
  /// - returns: 加工後の映像フレーム
  func filter(videoFrame: VideoFrame) -> VideoFrame
}
