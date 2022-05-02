import Foundation
import Sora
import SwiftUI
import UIKit

public struct Video<Background>: View where Background: View {

    private var background: Background

    @ObservedObject private var controller: VideoController

    public init(_ controller: VideoController) where Background == EmptyView {
        self.init(controller, background: {
            EmptyView()
        })
    }

    public init(_ controller: VideoController,
                background: () -> Background) {
        self.controller = controller
        self.background = background()
    }

    public var body: some View {
        ZStack {
            background
                .opacity(controller.isCleared ? 1 : 0)
            MainVideo(controller)
                .opacity(controller.isCleared ? 0 : 1)
        }
    }
}

fileprivate struct MainVideo: UIViewRepresentable {
    typealias UIViewType = VideoView

    @ObservedObject private var controller: VideoController

    public init(_ controller: VideoController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> VideoView {
        controller.videoView
    }

    public func updateUIView(_ uiView: VideoView, context: Context) {}

}

public class VideoController: ObservableObject {
    public var stream: MediaStream? {
        didSet {
            stream?.videoRenderer = videoView
        }
    }

    public var connectionMode: VideoViewConnectionMode = .autoClear {
        didSet {
            videoView.connectionMode = connectionMode
        }
    }

    public var debugMode: Bool = false {
        didSet {
            videoView.debugMode = debugMode
        }
    }

    public var currentVideoFrameSize: CGSize? {
        videoView.currentVideoFrameSize
    }

    public internal(set) var videoView: VideoView

    public private(set) var isRendering: Bool = true

    @Published var isCleared = false

    public init() {
        videoView = VideoView()
        videoView.start()
    }

    public func start() {
        videoView.start()
        isRendering = true
        isCleared = false
    }

    public func stop() {
        videoView.stop()
        isRendering = false
    }

    public func clear() {
        videoView.clear()
        isCleared = true
    }
}
