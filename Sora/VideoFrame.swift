import Foundation
import CoreMedia
import WebRTC

/**
 映像フレームの種別です。
 現在の実装では次の映像フレームに対応しています。
 
 - ネイティブの映像フレーム (`RTCVideoFrame`)
 - スナップショット (`Snapshot`)
 - `CMSampleBuffer` (`RTCVideoFrame` に変換されます)
 
 */
public enum VideoFrame {
    
    // MARK: - 定義
    
    /// ネイティブの映像フレーム。
    /// `CMSampleBuffer` から生成した映像フレームは、ネイティブの映像フレームに変換されます。
    case native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)
    
    /// スナップショット
    case snapshot(Snapshot)
    
    // MARK: - プロパティ
    
    /// 映像フレームの幅
    public var width: Int {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return Int(frame.width)
            case .snapshot(let snapshot):
                return snapshot.image.width
            }
        }
    }
    
    /// 映像フレームの高さ
    public var height: Int {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return Int(frame.height)
            case .snapshot(let snapshot):
                return snapshot.image.height
            }
        }
    }

    /// 映像フレームの生成時刻
    public var timestamp: CMTime? {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return CMTimeMake(frame.timeStampNs, 1_000_000_000)
            case .snapshot(_):
                return nil // TODO
            }
        }
    }

    
    // MARK: - 初期化
    
    /**
     初期化します。
     指定されたサンプルバッファーからピクセル画像データを取得できなければ
     `nil` を返します。
     
     - parameter sampleBuffer: ピクセルバッファーを含むサンプルバッファー
     */
    public init?(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let timeStamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timeStampNs = Int64(timeStamp * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: RTCVideoRotation._0,
                                  timeStampNs: timeStampNs)
        self = .native(capturer: nil, frame: frame)
    }
    
}
