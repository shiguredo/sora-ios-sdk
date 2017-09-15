import Foundation
import WebRTC

public protocol MediaStream: class {
    
    var streamId: String { get }
    var creationTime: Date { get }
    var videoCapturer: VideoCapturer? { get set }
    var videoFilter: VideoFilter? { get set }
    var videoRenderer: VideoRenderer? { get set }
    // var audioCapturer: AudioCapturer? { get set }
 
}

open class BasicMediaStream: MediaStream {
    
    public var streamId: String = ""
    public var videoTrackId: String = ""
    public var audioTrackId: String = ""
    public var creationTime: Date
    
    public var videoCapturer: VideoCapturer? {
        didSet {
            oldValue?.handlers.onCaptureHandler.clear()
            videoCapturer?.handlers.onCapture(handler: handleFrame)
        }
    }
    
    public var videoFilter: VideoFilter?
 
    var videoRendererAdapter: VideoRendererAdapter
    
    public var videoRenderer: VideoRenderer? {
        get { return videoRendererAdapter.videoRenderer }
        set { videoRendererAdapter.videoRenderer = newValue }
    }

    public var nativeStream: RTCMediaStream
    
    public var nativeVideoTrack: RTCVideoTrack? {
        get { return nativeStream.videoTracks.first }
    }
    
    public var nativeVideoSource: RTCVideoSource? {
        get { return nativeVideoTrack?.source }
    }

    public init(nativeStream: RTCMediaStream) {
        self.nativeStream = nativeStream
        streamId = nativeStream.streamId
        creationTime = Date()
        videoRendererAdapter = VideoRendererAdapter()
        nativeVideoTrack?.add(videoRendererAdapter)
    }
    
    public func handleFrame(_ frame: VideoFrame) {
        switch frame {
        case .native(capturer: let capturer, frame: let frame):
            // フィルターを通す
            var frame = frame
            if let filter = videoFilter {
                var newFrame = VideoFrame.native(capturer: capturer, frame: frame)
                newFrame = filter.filterFrame(newFrame)
                switch newFrame {
                case .native(capturer: _, frame: let filtered):
                    frame = filtered
                default:
                    break
                }
            }
            
            // RTCVideoSource.capturer(_:didCapture:) の最初の引数は
            // 現在使われてないのでダミーでも可
            let shared = CameraVideoCapturer.shared.nativeCapturer
            nativeVideoSource?.capturer(capturer ?? shared!, didCapture: frame)
            
        default:
            break
        }
    }
    
}
