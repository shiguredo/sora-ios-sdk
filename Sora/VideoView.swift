import UIKit
import WebRTC

public class VideoView: UIView {
    
    // キーウィンドウ外で RTCEAGLVideoView を生成すると次のエラーが発生するため、
    // contentView を Nib ファイルでセットせずに遅延プロパティで初期化する
    // "Failed to bind EAGLDrawable: <CAEAGLLayer: ***> to GL_RENDERBUFFER 1"
    // ただし、このエラーは無視しても以降の描画に問題はなく、クラッシュもしない
    // また、遅延プロパティでもキーウィンドウ外で初期化すれば
    // エラーが発生するため、根本的な解決策ではないので注意
    fileprivate lazy var contentView: VideoViewContentView = {
        guard let topLevel = Bundle(for: VideoView.self)
            .loadNibNamed("VideoView", owner: self, options: nil) else
        {
            fatalError("cannot load VideoView's nib file")
        }
        
        let view: VideoViewContentView = topLevel[0] as! VideoViewContentView
        view.frame = self.bounds
        self.addSubview(view)
        return view
    }()
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFit
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        contentMode = .scaleAspectFit
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = self.bounds
    }
    
}

extension VideoView: VideoRenderer {

    public func onChangedSize(_ size: CGSize) {
        contentView.onVideoFrameSizeUpdated(size)
    }
    
    public func renderFrame(_ frame: VideoFrame?) {
        contentView.render(videoFrame: frame)
    }
    
}

class VideoViewContentView: UIView {
    
    @IBOutlet private weak var nativeVideoView: RTCEAGLVideoView!
    @IBOutlet private weak var snapshotView: UIImageView!
    
    private var currentVideoFrameSize: CGSize?
    private var videoFrameSizeToChange: CGSize?
    
    // MARK: - Init/deinit
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        clipsToBounds = true
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    
    // MARK: - UIView
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // onChangedSize が呼ばれて RTCEAGLVideoView にサイズの変更がある場合、
        // このビューがウィンドウに表示されたタイミングでサイズの変更を行う
        // これも前述のエラーを回避するため
        if window != nil {
            updateSizeIfNeeded()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // 自分自身のサイズが変化したとき、既に描画された video frame size に合わせて再レイアウトを行う
        if let videoFrameSize = self.currentVideoFrameSize {
            updateNativeVideoViewSize(videoFrameSize)
        }
    }
    
    // MARK: - Methods
    
    fileprivate var allowsRender: Bool {
        get {
            // 前述のエラーはキーウィンドウ外での描画でも発生するので、
            // ビューがキーウィンドウに表示されている場合のみ描画を許可する
            return !(isHidden || window == nil || !window!.isKeyWindow)
        }
    }
    
    fileprivate func onVideoFrameSizeUpdated(_ videoFrameSize: CGSize) {
        // ここも前述のエラーと同様の理由で処理を後回しにする
        if allowsRender {
            updateNativeVideoViewSize(videoFrameSize)
        } else {
            videoFrameSizeToChange = videoFrameSize
        }
    }
    
    fileprivate func render(videoFrame: VideoFrame?) {
        guard allowsRender else { return }
        updateSizeIfNeeded()
        
        if let frame = videoFrame {
            switch frame {
            case .native(capturer: _, frame: let frame):
                snapshotView.isHidden = true
                nativeVideoView.isHidden = false
                nativeVideoView.renderFrame(frame)
            case .snapshot(let snapshot):
                // snapshot は WebRTC.framework の仕組みを使用しないで描画しており、
                // snapshotView のレイアウトも AutoLayoutによって実施されている。
                // ここでは描画モードの指定を忘れず行う。
                snapshotView.isHidden = false
                nativeVideoView.isHidden = true
                snapshotView.contentMode = renderingContentMode
                snapshotView.image = UIImage(cgImage: snapshot.image)
            case .other:
                nativeVideoView.renderFrame(nil)
            }
        } else {
            nativeVideoView.renderFrame(nil)
        }
    }
    
    // MARK: - Private Methods
    
    private var renderingContentMode: UIViewContentMode {
        // superView に指定されている contentMode を優先的に使用する。
        // 万一指定がない場合はデフォルトの aspect fit を使用する。
        return self.superview?.contentMode ?? .scaleAspectFit
    }
    
    private func updateSizeIfNeeded() {
        if let videoFrameSize = videoFrameSizeToChange {
            if allowsRender {
                updateNativeVideoViewSize(videoFrameSize)
                videoFrameSizeToChange = nil
            }
        }
    }
    
    private func updateNativeVideoViewSize(_ videoFrameSize: CGSize) {
        // 指定された映像のサイズ・現在の自分自身の描画領域のサイズ・描画モードの指定に合わせて、
        // RTCEAGLVideoView のサイズと位置を変更し、うまい具合に動画が描画されるようにする。
        let adjustSize = viewSize(for: videoFrameSize,
                                  containerSize: bounds.size,
                                  mode: renderingContentMode)
        
        // setSize(_:) の呼び出しと nativeVideoView.frame の設定について
        // setSize(_:) は RTCVideoRenderer.h にて定義されているメソッドだが、
        // https://chromium.googlesource.com/external/webrtc/+/master/webrtc/sdk/objc/Framework/Headers/WebRTC/RTCVideoRenderer.h#26
        // その実装は RTCEAGLVideoView.m に存在し、実際には delegate に対して通知を行っているだけである。
        // https://chromium.googlesource.com/external/webrtc/+/master/webrtc/sdk/objc/Framework/Classes/UI/RTCEAGLVideoView.m#263
        // 名前からして setSize(_:) を呼び出すことで nativeVideoView の描画フレームや内部状態が綺麗に設定されるものだと期待してしまうが、
        // そのような挙動は一切なく、 nativeVideoView は自分自身の frame 一杯に合わせて単に動画フレームを描画する処理しか行ってくれない。
        // 正直なところ、この WebRTC.framework 側の実装に大いに疑問があるが・・・
        // したがって setSize(_:) は自分で nativeVideoView.frame を適切にセットした後に、手動で呼び出してやらないとならない。
        // nativeVideoView.frame のセットより先に setSize(_:) を呼び出すと、まだ自分自身のサイズが更新されていないにも関わらず delegate に対する通知が発生して挙動がおかしくなる
        nativeVideoView.frame =
            CGRect(x: (bounds.size.width - adjustSize.width) / 2,
                   y: (bounds.size.height - adjustSize.height) / 2,
                   width: adjustSize.width,
                   height: adjustSize.height)
        nativeVideoView.setSize(adjustSize)
        currentVideoFrameSize = videoFrameSize
        setNeedsDisplay()
    }
    
}

private func viewSize(for videoFrameSize: CGSize, containerSize: CGSize, mode: UIViewContentMode) -> CGSize {
    switch mode {
    case .scaleToFill:
        // scale to fill モードの場合はアスペクト比を尊重する必要が無いので、
        // 何も考えず単純に containerSize を返せば良い。
        return containerSize
    case .scaleAspectFill:
        // scale aspect fill モードの場合は video frame を拡大して container size を埋めつくすように返せばよい。
        let baseW = CGSize(width: containerSize.width,
                           height: containerSize.width * (videoFrameSize.height / videoFrameSize.width))
        let baseH = CGSize(width: containerSize.height * (videoFrameSize.width / videoFrameSize.height),
                           height: containerSize.height)
        return ([baseW, baseH].first { size in
            size.width >= containerSize.width && size.height >= containerSize.height
        }) ?? baseW
    case .scaleAspectFit: fallthrough
    default:
        // デフォルトは aspect fit モード。
        // 特別に対応しているモード以外はすべて aspect fit として扱います。
        // この場合は container size にちょうどフィットする中で最も大きいサイズを返せばよい。
        let baseW = CGSize(width: containerSize.width,
                           height: containerSize.width * (videoFrameSize.height / videoFrameSize.width))
        let baseH = CGSize(width: containerSize.height * (videoFrameSize.width / videoFrameSize.height),
                           height: containerSize.height)
        return ([baseW, baseH].first { size in
            size.width <= containerSize.width && size.height <= containerSize.height
        }) ?? baseW
    }
}
