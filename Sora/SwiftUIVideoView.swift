import SwiftUI
import UIKit

/// SwiftUI から ``VideoView`` を利用するための ``UIViewRepresentable`` です。
@available(iOS 14, *)
public struct SwiftUIVideoView: UIViewRepresentable {
  public typealias UIViewType = VideoView

  public var stream: MediaStream?
  public var connectionMode: VideoViewConnectionMode
  public var contentMode: UIView.ContentMode
  public var debugMode: Bool
  public var backgroundView: UIView?

  /// 初期化します。
  /// - Parameters:
  ///   - stream: 映像を描画する ``MediaStream``。
  ///   - connectionMode: ``VideoView.connectionMode`` に設定する値。
  ///   - contentMode: ``VideoView.contentMode`` に設定する値。
  ///   - debugMode: ``VideoView.debugMode`` の設定。
  ///   - backgroundView: ``VideoView.backgroundView`` に使用するビュー。
  public init(
    stream: MediaStream? = nil,
    connectionMode: VideoViewConnectionMode = .autoClear,
    contentMode: UIView.ContentMode = .scaleAspectFit,
    debugMode: Bool = false,
    backgroundView: UIView? = nil
  ) {
    self.stream = stream
    self.connectionMode = connectionMode
    self.contentMode = contentMode
    self.debugMode = debugMode
    self.backgroundView = backgroundView
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  public func makeUIView(context: Context) -> VideoView {
    let videoView = VideoView(frame: .zero)
    configure(videoView)
    context.coordinator.bind(stream: stream, to: videoView)
    return videoView
  }

  public func updateUIView(_ uiView: VideoView, context: Context) {
    configure(uiView)
    context.coordinator.bind(stream: stream, to: uiView)
  }

  public static func dismantleUIView(_ uiView: VideoView, coordinator: Coordinator) {
    coordinator.unbind(view: uiView)
  }

  private func configure(_ view: VideoView) {
    if view.connectionMode != connectionMode {
      view.connectionMode = connectionMode
    }
    if view.contentMode != contentMode {
      view.contentMode = contentMode
    }
    if view.debugMode != debugMode {
      view.debugMode = debugMode
    }

    switch (view.backgroundView, backgroundView) {
    case let (lhs?, rhs?) where lhs !== rhs:
      view.backgroundView = rhs
    case (nil, .some(let rhs)):
      view.backgroundView = rhs
    case (.some, nil):
      view.backgroundView = nil
    default:
      break
    }
  }

  public final class Coordinator {
    private weak var currentStream: MediaStream?

    fileprivate func bind(stream: MediaStream?, to view: VideoView) {
      guard currentStream !== stream else {
        return
      }
      detach(from: currentStream, view: view)
      if let stream {
        stream.videoRenderer = view
      }
      currentStream = stream
    }

    fileprivate func unbind(view: VideoView) {
      detach(from: currentStream, view: view)
    }

    private func detach(from stream: MediaStream?, view: VideoView) {
      guard let stream else {
        currentStream = nil
        return
      }
      if stream.videoRenderer === view {
        stream.videoRenderer = nil
      }
      if currentStream === stream {
        currentStream = nil
      }
    }
  }
}
