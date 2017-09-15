import Foundation
import WebRTC

class MediaCapturer {
    
    public var mediaOption: MediaOption?
    public var videoCaptureTrack: RTCVideoTrack
    public var videoCaptureSource: RTCAVFoundationVideoSource
    public var audioCaptureTrack: RTCAudioTrack
    public var cameraVideoCapturer: RTCCameraVideoCapturer?
    
    init(factory: RTCPeerConnectionFactory, mediaOption: MediaOption?) {
        self.mediaOption = mediaOption
        videoCaptureSource = factory
            .avFoundationVideoSource(with:
                mediaOption?.videoCaptureSourceMediaConstraints ??
                    MediaOption.defaultMediaConstraints)
        videoCaptureTrack = factory
            .videoTrack(with: videoCaptureSource,
                        trackId: self.mediaOption?.videoCaptureTrackId ??
                            MediaOption.createCaptureTrackId())
        audioCaptureTrack = factory
            .audioTrack(withTrackId: self.mediaOption?.audioCaptureTrackId ??
                MediaOption.createCaptureTrackId())
    }
    
}

public enum CameraPosition: String {
    case front
    case back
    
    public func flip() -> CameraPosition {
        switch self {
        case .front: return .back
        case .back: return .front
        }
    }
    
}
