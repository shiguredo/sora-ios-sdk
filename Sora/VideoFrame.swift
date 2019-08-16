import Foundation
import CoreMedia
import WebRTC

/**
 映像フレームの種別です。
 現在の実装では次の映像フレームに対応しています。
 
 - ネイティブの映像フレーム (`RTCVideoFrame`)
 - `CMSampleBuffer` (映像のみ、音声は非対応。 `RTCVideoFrame` に変換されます)
 
 */
public enum VideoFrame {
    
    // MARK: - 定義
    
    /// ネイティブの映像フレーム。
    /// `CMSampleBuffer` から生成した映像フレームは、ネイティブの映像フレームに変換されます。
    case native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)
    
    // MARK: - プロパティ
    
    /// 映像フレームの幅
    public var width: Int {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return Int(frame.width)
            }
        }
    }
    
    /// 映像フレームの高さ
    public var height: Int {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return Int(frame.height)
            }
        }
    }

    /// 映像フレームの生成時刻
    public var timestamp: CMTime? {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return CMTimeMake(value: frame.timeStampNs, timescale: 1_000_000_000)
            }
        }
    }

    
    // MARK: - 初期化
    
    /**
     初期化します。
     指定されたサンプルバッファーからピクセル画像データを取得できなければ
     `nil` を返します。
     
     音声データを含むサンプルバッファーには対応していません。
     
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
