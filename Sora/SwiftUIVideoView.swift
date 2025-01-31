import Foundation
import SwiftUI
import UIKit

/**
 ストリームの映像を描画する SwiftUI ビューです。
 */
@available(iOS 14, *)
public struct SwiftUIVideoView<Background>: View where Background: View {
    private var stream: MediaStream?
    private var background: Background

    // TODO(zztkm): わかりやすいコメントを書く
    // 親 View で定義された stopVideo 変数と接続するための変数
    @Binding private var isStop: Bool
    @Binding private var isClear: Bool

    @ObservedObject private var controller: VideoController

    /**
     ビューを初期化します。

     - parameter stream: 描画される映像ストリーム。 nil の場合は何も描画されません
     - parameter isStop: 映像の描画を制御するフラグ (default: false)
     - parameter isClear: 映像をクリアして背景 View を表示するためのフラグ (default: false)
     */
    public init(_ stream: MediaStream?, isStop: Binding<Bool>? = nil, isClear: Binding<Bool>? = nil) where Background == EmptyView {
        self.init(stream, background: EmptyView(), isStop: isStop, isClear: isClear)
    }

    /**
     ビューを初期化します。

     - parameter stream: 描画される映像ストリーム nil の場合は何も描画されません
     - parameter background: 映像のクリア時に表示する背景ビュー
     - parameter isStop: 映像の描画を制御するフラグ (default: false)
     - parameter isClear: 映像をクリアして背景 View を表示するためのフラグ (default: false)
     */
    public init(_ stream: MediaStream?, background: Background, isStop: Binding<Bool>? = nil, isClear: Binding<Bool>? = nil) {
        self.stream = stream
        self.background = background
        // 指定がない場合は固定値 false を与える
        _isStop = isStop ?? .constant(false)
        _isClear = isClear ?? .constant(false)
        controller = VideoController(stream: stream)
    }

    /// :nodoc:
    public var body: some View {
        ZStack {
            background
                .opacity(controller.isCleared ? 1 : 0)
            RepresentedVideoView(controller, isStop: $isStop, isClear: $isClear)
                .opacity(controller.isCleared ? 0 : 1)
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
        var new = SwiftUIVideoView<Background>(stream, background: background)
        new.controller = controller
        return new
    }

    /**
     映像の描画を停止します。
     */
    private func videoStop(_ flag: Bool) -> SwiftUIVideoView<Background> {
        if flag {
            controller.videoView.stop()
        } else if !controller.videoView.isRendering {
            controller.videoView.start()
        }
        return self
    }

    /**
     画面を背景ビューに切り替えます。
     このメソッドは描画停止時のみ有効です。
     */
    public func videoClear(_ flag: Bool) -> SwiftUIVideoView<Background> {
        if flag {
            controller.videoView.clear()
            controller.isCleared = true
        }
        return self
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
    @Binding private var isStop: Bool
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

class VideoController: ObservableObject {
    var stream: MediaStream?

    // init() で VideoView を生成すると次のエラーが出るので、生成のタイミングを遅らせておく
    // Failed to bind EAGLDrawable: <CAEAGLLayer: 0x********> to GL_RENDERBUFFER 1
    lazy var videoView = VideoView()

    @Published var isCleared: Bool = false

    init(stream: MediaStream?) {
        self.stream = stream
    }
}
