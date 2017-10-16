import Foundation
import WebRTC

public protocol MediaStream: class {
    
    // MARK: - プロパティ
    var streamId: String { get }
    var creationTime: Date { get }
    var videoCapturer: VideoCapturer? { get set }
    var videoFilter: VideoFilter? { get set }
    var videoRenderer: VideoRenderer? { get set }
    // var audioCapturer: AudioCapturer? { get set }
    
    // MARK: 映像フレームの描画
    
    func send(videoFrame: VideoFrame?)
    
}

class BasicMediaStream: MediaStream {
    
    var streamId: String = ""
    var videoTrackId: String = ""
    var audioTrackId: String = ""
    var creationTime: Date
    
    var videoCapturer: VideoCapturer? {
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
    
    var videoFilter: VideoFilter?
    
    var videoRenderer: VideoRenderer? {
        get {
            return videoRendererAdapter?.videoRenderer
        }
        set {
            if let value = newValue {
                videoRendererAdapter = VideoRendererAdapter(videoRenderer: value)
            } else {
                videoRendererAdapter = nil
            }
        }
    }
    
    private var videoRendererAdapter: VideoRendererAdapter? {
        willSet {
            guard let videoTrack = nativeVideoTrack else { return }
            guard let adapter = videoRendererAdapter else { return }
            Logger.debug(type: .videoRenderer,
                         message: "remove old video renderer \(adapter) from nativeVideoTrack")
            videoTrack.remove(adapter)
        }
        didSet {
            guard let videoTrack = nativeVideoTrack else { return }
            guard let adapter = videoRendererAdapter else { return }
            Logger.debug(type: .videoRenderer,
                         message: "add new video renderer \(adapter) to nativeVideoTrack")
            videoTrack.add(adapter)
        }
    }
    
    var nativeStream: RTCMediaStream
    
    var nativeVideoTrack: RTCVideoTrack? {
        get { return nativeStream.videoTracks.first }
    }
    
    var nativeVideoSource: RTCVideoSource? {
        get { return nativeVideoTrack?.source }
    }
    
    init(nativeStream: RTCMediaStream) {
        self.nativeStream = nativeStream
        streamId = nativeStream.streamId
        creationTime = Date()
    }
    
    private static let dummyCapturer: RTCVideoCapturer = RTCVideoCapturer()
    func send(videoFrame: VideoFrame?) {
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
