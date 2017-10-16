import Foundation
import WebRTC

/**
 メディアストリームの機能を定義したプロトコルです。
 デフォルトの実装は非公開 (`internal`) であり、カスタマイズはイベントハンドラでのみ可能です。
 ソースコードは公開していますので、実装の詳細はそちらを参照してください。
 
 メディアストリームは映像と音声の送受信を行います。
 メディアストリーム 1 つにつき、 1 つの映像と 1 つの音声を送受信可能です。
 */
public protocol MediaStream: class {
    
    // MARK: - 接続情報
    
    /// ストリーム ID
    var streamId: String { get }
    
    /// 接続開始時刻
    var creationTime: Date { get }

    // MARK: 映像フレームの送信

    /// 映像キャプチャー
    var videoCapturer: VideoCapturer? { get set }
    
    /// 映像フィルター
    var videoFilter: VideoFilter? { get set }
    
    /// 映像レンダラー。
    var videoRenderer: VideoRenderer? { get set }
    
    /**
     映像フレームをサーバーに送信します。
     送信される映像フレームは映像フィルターを通して加工されます。
     映像レンダラーがセットされていれば、加工後の映像フレームが
     映像レンダラーによって描画されます。
     
     - parameter videoFrame: 描画する映像フレーム。
                             `nil` を指定すると空の映像フレームを送信します。
     */
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
