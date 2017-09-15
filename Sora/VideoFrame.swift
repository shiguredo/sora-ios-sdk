import Foundation
import CoreMedia
import WebRTC

public protocol VideoFrameType {
    
    var width: Int { get }
    var height: Int { get }
    var timestamp: CMTime? { get }
    
}

public enum VideoFrame {
    
    case native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)
    case snapshot(Snapshot)
    case other(VideoFrameType)
    
    public var width: Int {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return Int(frame.width)
            case .snapshot(let snapshot):
                return snapshot.image.width
            case .other(let frame):
                return frame.width
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
            case .other(let frame):
                return frame.height
            }
        }
    }

    public var timestamp: CMTime? {
        get {
            switch self {
            case .native(capturer: _, frame: let frame):
                return CMTimeMake(frame.timeStampNs, 1000000000)
            case .snapshot(_):
                return nil // TODO
            case .other(let frame):
                return frame.timestamp
            }
        }
    }

}
