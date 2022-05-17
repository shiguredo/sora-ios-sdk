import Foundation
import SwiftUI
import UIKit

public struct Video<Background>: View where Background: View {

    var stream: MediaStream?
    var videoView: Binding<VideoView>?
    var background: Background

    @ObservedObject var controller: VideoController

    public init(_ stream: MediaStream?,
                videoView: Binding<VideoView>? = nil) where Background == EmptyView {
        self.init(stream, background: EmptyView())
    }

    init(_ stream: MediaStream?,
         videoView: Binding<VideoView>? = nil,
         background: Background) {
        self.stream = stream
        self.videoView = videoView
        self.background = background
        controller = VideoController(stream: stream)
        videoView?.wrappedValue = controller.videoView
    }

    public var body: some View {
        ZStack {
            background
                .opacity(controller.isCleared ? 1 : 0)
            RepresentedVideoView(controller)
                .opacity(controller.isCleared ? 0 : 1)
        }
    }

    public func debugMode(_ flag: Bool) -> Video<Background> {
        controller.videoView.debugMode = flag
        return self
    }

    public func connectionMode(_ mode: VideoViewConnectionMode) -> Video<Background> {
        controller.videoView.connectionMode = mode
        return self
    }

    public func videoAspectRatio(_ contentMode: ContentMode) -> Video<Background> {
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

    public func videoBackground<Background>(_ background: Background) -> Video<Background> where Background: View {
        var new = Video<Background>(stream, background: background)
        new.controller = controller
        return new
    }

    public func videoStop(_ flag: Bool) -> Video<Background> {
        if flag {
            controller.videoView.stop()
        } else if !controller.videoView.isRendering {
            controller.videoView.start()
        }
        return self
    }

    public func videoClear(_ flag: Bool) -> Video<Background> {
        if flag {
            controller.videoView.clear()
            controller.isCleared = true
        }
        return self
    }

    public func videoOnChange(perform: @escaping (CGSize) -> Void) -> Video<Background> {
        controller.videoView.handlers.onChange = perform
        return self
    }

    public func videoOnRender(perform: @escaping (VideoFrame?) -> Void) -> Video<Background> {
        controller.videoView.handlers.onRender = perform
        return self
    }
}

fileprivate struct RepresentedVideoView: UIViewRepresentable {
    typealias UIViewType = VideoView

    @ObservedObject private var controller: VideoController

    public init(_ controller: VideoController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> VideoView {
        return controller.videoView
    }

    public func updateUIView(_ uiView: VideoView, context: Context) {
        controller.stream?.videoRenderer = uiView
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
