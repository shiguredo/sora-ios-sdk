import Foundation
import CoreMedia
import WebRTC

public enum VideoFrame {
    
    public init?(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let timeStamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timeStampNs = Int64(timeStamp * 1_000_000_000)
        let frame = RTCVideoFrame(pixelBuffer: pixelBuffer, rotation: RTCVideoRotation._0, timeStampNs: timeStampNs)
        self = .native(capturer: nil, frame: frame)
    }
    
    case native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)
    case snapshot(Snapshot)
    
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

}
