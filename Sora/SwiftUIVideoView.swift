import Foundation
import SwiftUI
import UIKit

/**
 ストリームの映像を描画する SwiftUI ビューです。
 */
public struct SwiftUIVideoView<Background>: View where Background: View {
    private var stream: MediaStream?
    private var background: Background

    @ObservedObject private var controller: VideoController

    /**
     ビューを初期化します。

     - parameter stream: 描画される映像ストリーム。 nil の場合は何も描画されません
     */
    public init(_ stream: MediaStream?) where Background == EmptyView {
        self.init(stream, background: EmptyView())
    }

    /**
     ビューを初期化します。

     - parameter stream: 描画される映像ストリーム nil の場合は何も描画されません
     - paramater background: 映像のクリア時に表示する背景ビュー
     */
    public init(_ stream: MediaStream?, background: Background) {
        self.stream = stream
        self.background = background
        controller = VideoController(stream: stream)
    }

    /// :nodoc:
    public var body: some View {
        ZStack {
            background
                .opacity(controller.isCleared ? 1 : 0)
            RepresentedVideoView(controller)
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
    public func videoStop(_ flag: Bool) -> SwiftUIVideoView<Background> {
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
 UIKitVideoView を SwiftUIVideoView に統合するためのラッパーです。
 */
private struct RepresentedVideoView: UIViewRepresentable {
    typealias UIViewType = UIKitVideoView

    @ObservedObject private var controller: VideoController

    public init(_ controller: VideoController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> UIKitVideoView {
        controller.videoView
    }

    public func updateUIView(_ uiView: UIKitVideoView, context: Context) {
        controller.stream?.videoRenderer = uiView
    }
}

class VideoController: ObservableObject {
    var stream: MediaStream?

    // init() で UIKitVideoView を生成すると次のエラーが出るので、生成のタイミングを遅らせておく
    // Failed to bind EAGLDrawable: <CAEAGLLayer: 0x********> to GL_RENDERBUFFER 1
    lazy var videoView = UIKitVideoView()

    @Published var isCleared: Bool = false

    init(stream: MediaStream?) {
        self.stream = stream
    }
}
