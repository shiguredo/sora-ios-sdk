import Foundation
import SwiftUI
import UIKit

/**
 ストリームの映像を描画する SwiftUI ビューです。
 */
@available(iOS 14, *)
public struct SwiftUIVideoView<Background>: View where Background: View {
    @ObservedObject private var controller: VideoController
    private var background: Background
    /**
     ビューを初期化します。

     - parameter controller: VideoController
     */
    public init(_ controller: VideoController) where Background == EmptyView {
        self.init(controller, background: EmptyView())
    }

    /**
     ビューを初期化します。

     - parameter stream: 描画される映像ストリーム nil の場合は何も描画されません
     - parameter background: 映像のクリア時に表示する背景ビュー
     - parameter isStop: 映像の描画を制御するフラグ (default: false)
     - parameter isClear: 映像をクリアして背景 View を表示するためのフラグ (default: false)
     */
    public init(_ controller: VideoController, background: Background) {
        self.controller = controller
        self.background = background
    }

    /// :nodoc:
    /// TODO(zztkm): SwiftUI での Background と UIKit での Background が同居しているが使い分けについて考える
    /// 今の実装だと isClear で UIKit の方も clear してるけど、これは意味がなくて isClear すると SwiftUI の Backgroud View が表示されるようになる
    /// なので、そもそも VideView の clear() method を呼ぶ意味がなくなってしまってる
    /// この辺の制御はできるだけ SwiftUI 側に寄せたいので、clear() metthod を呼ばないようにするなど検討したい
    public var body: some View {
        ZStack {
            // isClear が true のときは背景を表示し、false のときは Video を表示する
            background
                .opacity(isClear ? 1 : 0)
            RepresentedVideoView(controller, isStop: $isStop, isClear: $isClear)
                .opacity(isClear ? 0 : 1)
        }
    }

    /**
     デバッグモードを有効にします。
     有効にすると、映像の上部に解像度とフレームレートを表示します。
     */
    public func debugMode(_ flag: Bool) -> SwiftUIVideoView<Background> {
        controller.videoView.debugMode = flag
        return self
    }

    /// 映像ソース停止時の処理を指定します。
    public func connectionMode(_ mode: VideoViewConnectionMode) -> SwiftUIVideoView<Background> {
        controller.videoView.connectionMode = mode
        return self
    }

    /// 映像のアスペクト比を指定します。
    public func videoAspect(_ contentMode: ContentMode) -> SwiftUIVideoView<Background> {
        var uiContentMode: UIView.ContentMode
        switch contentMode {
        case .fill:
            uiContentMode = .scaleAspectFill
        case .fit:
            uiContentMode = .scaleAspectFit
        }
        controller.videoView.contentMode = uiContentMode
        return self
    }

    /// 映像のクリア時に表示する背景ビューを指定します。
    public func videoBackground<Background>(_ background: Background) -> SwiftUIVideoView<Background> where Background: View {
        SwiftUIVideoView<Background>(controller, background: background)
    }

    /// 映像のサイズの変更時に実行されるブロックを指定します。
    public func videoOnChange(perform: @escaping (CGSize) -> Void) -> SwiftUIVideoView<Background> {
        controller.videoView.handlers.onChange = perform
        return self
    }

    /// 映像フレームの描画時に実行されるブロックを指定します。
    public func videoOnRender(perform: @escaping (VideoFrame?) -> Void) -> SwiftUIVideoView<Background> {
        controller.videoView.handlers.onRender = perform
        return self
    }
}

/*
 VideoView を SwiftUIVideoView に統合するためのラッパーです。
 */
private struct RepresentedVideoView: UIViewRepresentable {
    typealias UIViewType = VideoView

    @ObservedObject private var controller: VideoController

    // 以下は SDK ユーザー側で制御される変数
    /// 映像を停止するかを制御するフラグ
    @Binding private var isStop: Bool
    /// backgroundView を表示するか制御するフラグ
    @Binding private var isClear: Bool

    public init(_ controller: VideoController, isStop: Binding<Bool>, isClear: Binding<Bool>) {
        self.controller = controller
        _isStop = isStop
        _isClear = isClear
    }

    public func makeUIView(context: Context) -> VideoView {
        controller.videoView
    }

    /// VideoView を更新する処理です
    ///
    /// 引数の uiView を更新し、更新したあとに controller.stream?.videoRenderer に
    /// uiView をセットすることで、VideoView の挙動を制御することができます。
    public func updateUIView(_ uiView: VideoView, context: Context) {
        var uiView = uiView
        // VideoView.clear() はVideoView.stop() が実行されたあとにのみ実行可能になる
        uiView = clear(stop(uiView))
        controller.stream?.videoRenderer = uiView
    }

    // 現在 VideoView が表示している映像の元々のフレームサイズを返します。
    public var currentVideoFrameSize: CGSize? {
        controller.videoView.currentVideoFrameSize
    }

    /**
     映像の描画を停止します。TODO(zztkm): method 名の検討 (stop start の toggle なので、stop はおかしいかも？
     */
    private func stop(_ uiView: VideoView) -> VideoView {
        if isStop {
            uiView.stop()
        } else {
            uiView.start()
        }
        return uiView
    }

    /**
     画面を背景ビューに切り替えます。
     このメソッドは描画停止時のみ有効です。
     */
    private func clear(_ uiView: VideoView) -> VideoView {
        if isClear {
            uiView.clear()
        }
        return uiView
    }
}

public class VideoController: ObservableObject {
    var stream: MediaStream?

    // init() で VideoView を生成すると次のエラーが出るので、生成のタイミングを遅らせておく
    // Failed to bind EAGLDrawable: <CAEAGLLayer: 0x********> to GL_RENDERBUFFER 1
    lazy var videoView = VideoView()

    init(stream: MediaStream?) {
        self.stream = stream
    }
}
