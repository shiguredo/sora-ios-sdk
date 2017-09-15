import UIKit
import WebRTC

public class VideoView: UIView, VideoRenderer {
    
    // キーウィンドウ外で RTCEAGLVideoView を生成すると次のエラーが発生するため、
    // contentView を Nib ファイルでセットせずに遅延プロパティで初期化する
    // "Failed to bind EAGLDrawable: <CAEAGLLayer: ***> to GL_RENDERBUFFER 1"
    // ただし、このエラーは無視しても以降の描画に問題はなく、クラッシュもしない
    // また、遅延プロパティでもキーウィンドウ外で初期化すれば
    // エラーが発生するため、根本的な解決策ではないので注意
    lazy var contentView: VideoViewContentView! = {
        guard let topLevel = Bundle(for: VideoView.self)
            .loadNibNamed("VideoView", owner: self, options: nil) else
        {
            assertionFailure("cannot load VideoView's nib file")
            return nil
        }
        
        let view: VideoViewContentView = topLevel[0] as! VideoViewContentView
        view.frame = self.bounds
        self.addSubview(view)
        if view.allowsRender {
            view.setNeedsDisplay()
        }
        return view
    }()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }
    
    func setUp() {
        addObserver(self, forKeyPath: "frame", options: .new, context: nil)
    }
    
    override public func observeValue(forKeyPath keyPath: String?,
                                      of object: Any?,
                                      change: [NSKeyValueChangeKey : Any]?,
                                      context: UnsafeMutableRawPointer?) {
        switch keyPath {
        case "frame"?:
            guard let change = change else { return }
            if let frame = change[NSKeyValueChangeKey.newKey] as? CGRect {
                contentView.setRemoteVideoViewSize(frame.size)
            }
        default:
            break
        }
    }
    
    public func onChangedSize(_ size: CGSize) {
        contentView.onChangedSize(size)
    }
    
    public func render(videoFrame: VideoFrame?) {
        contentView.render(videoFrame: videoFrame)
    }
    
}

class VideoViewContentView: UIView, VideoRenderer {
    
    @IBOutlet weak var nativeVideoView: RTCEAGLVideoView!
    
    var allowsRender: Bool {
        get {
            // 前述のエラーはキーウィンドウ外での描画でも発生するので、
            // ビューがキーウィンドウに表示されている場合のみ描画を許可する
            return !(isHidden || window == nil || !window!.isKeyWindow)
        }
    }
    
    var sizeToChange: CGSize?
    
    public func onChangedSize(_ size: CGSize) {
        // ここも前述のエラーと同様の理由で処理を後回しにする
        if allowsRender {
            setRemoteVideoViewSize(size)
        } else {
            sizeToChange = size
        }
    }
    
    func setRemoteVideoViewSize(_ size: CGSize) {
        // 映像の解像度のアスペクト比に合わせて
        // RTCEAGLVideoView のサイズと位置を変更する
        let adjustSize = fitSize(from: size, to: frame.size)
        nativeVideoView.setSize(adjustSize)
        sizeToChange = nil
        nativeVideoView.frame =
            CGRect(x: (frame.size.width - adjustSize.width) / 2,
                   y: (frame.size.height - adjustSize.height) / 2,
                   width: adjustSize.width,
                   height: adjustSize.height)
        setNeedsDisplay()
    }
    
    public func render(videoFrame: VideoFrame?) {
        guard allowsRender else { return }
        updateSize()

        if let frame = videoFrame {
            if let handle = frame.videoFrameHandle {
                switch handle {
                case .webRTC(let frame):
                    nativeVideoView.renderFrame(frame)
                }
            }
        } else {
            nativeVideoView.renderFrame(nil)
        }
    }
    
    public override func didMoveToWindow() {
        // onChangedSize が呼ばれて RTCEAGLVideoView にサイズの変更がある場合、
        // このビューがウィンドウに表示されたタイミングでサイズの変更を行う
        // これも前述のエラーを回避するため
        updateSize()
    }
    
    func updateSize() {
        if let size = sizeToChange {
            if allowsRender {
                setRemoteVideoViewSize(size)
            }
        }
    }
    
}

func fitSize(from: CGSize, to: CGSize) -> CGSize {
    let baseW = CGSize(width: to.width,
                       height: to.width * (from.height / from.width))
    let baseH = CGSize(width: to.height * (from.width / from.height),
                       height: to.height)
    return ([baseW, baseH].first {
        size in
        return size.width <= to.width && size.height <= to.height
    })!
}
