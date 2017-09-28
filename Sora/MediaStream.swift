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
            if var oldValue = videoCapturer {
                // Do not autostop here, let others manage videoCapturer's life cycle
                oldValue.stream = nil
            }
            if var newValue = newValue {
                newValue.stream = self
                // Do not autostart here, let others manage videoCapturer's life cycle
            }
        }
    }
    
    public var videoFilter: VideoFilter?
    
    private let videoRendererAdapter: VideoRendererAdapter
    
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
    
    private static let dummyCapturer: RTCVideoCapturer = RTCVideoCapturer()
    public func render(videoFrame: VideoFrame?) {
        if let frame = videoFrame {
            // フィルターを通す
            let frame = videoFilter?.filter(videoFrame: frame) ?? frame
            switch frame {
            case .native(capturer: let capturer, frame: let nativeFrame):
                // RTCVideoSource.capturer(_:didCapture:) の最初の引数は
                // 現在使われてないのでダミーでも可？ -> ダミーにしました
                nativeVideoSource?.capturer(capturer ?? BasicMediaStream.dummyCapturer,
                                            didCapture: nativeFrame)
                
            default:
                break
            }
        } else {
            
        }
    }
    
}
