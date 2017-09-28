import Foundation
import WebRTC

public protocol MediaStream: class {
    
    var streamId: String { get }
    var creationTime: Date { get }
    var videoCapturer: VideoCapturer? { get set }
    var videoFilter: VideoFilter? { get set }
    var videoRenderer: VideoRenderer? { get set }
    // var audioCapturer: AudioCapturer? { get set }
 
    // VideoCapturer から呼ばれる
    func render(videoFrame: VideoFrame?)
    
}

public class BasicMediaStream: MediaStream {
    
    public var streamId: String = ""
    public var videoTrackId: String = ""
    public var audioTrackId: String = ""
    public var creationTime: Date
    
    public var videoCapturer: VideoCapturer? {
        willSet {
            videoCapturer?.stream = nil
            var newValue = newValue
            newValue?.stream = self
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
    
    public func render(videoFrame: VideoFrame?) {
        if let frame = videoFrame {
            // フィルターを通す
            let frame = videoFilter?.filter(videoFrame: frame) ?? frame
            switch frame {
            case .native(capturer: let capturer, frame: let nativeFrame):
                // RTCVideoSource.capturer(_:didCapture:) の最初の引数は
                // 現在使われてないのでダミーでも可？
                nativeVideoSource?.capturer(capturer ??
                    CameraVideoCapturer.shared.nativeCameraVideoCapturer!,
                                            didCapture: nativeFrame)
                
            default:
                break
            }
        } else {
            
        }
    }
    
}
