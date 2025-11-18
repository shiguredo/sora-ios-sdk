import SwiftUI
import UIKit

/// SwiftUI から ``VideoView`` を利用するための ``UIViewRepresentable`` です。
///
/// 参考: https://developer.apple.com/documentation/swiftui/uiviewrepresentable
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
    // SwiftUI と UIKit 間の調整役となる Coordinator を生成する
    Coordinator()
  }

  public func makeUIView(context: Context) -> VideoView {
    // SwiftUI 上に表示する VideoView を生成し初期設定を適用する
    let videoView = VideoView(frame: .zero)
    configure(videoView)
    // MediaStream と VideoView を接続して映像が描画されるようにする
    context.coordinator.bind(stream: stream, to: videoView)
    return videoView
  }

  public func updateUIView(_ uiView: VideoView, context: Context) {
    // 既存の VideoView に最新の設定を反映する
    configure(uiView)
    // MediaStream の差し替えなどがあれば再バインドを行う
    context.coordinator.bind(stream: stream, to: uiView)
  }

  public static func dismantleUIView(_ uiView: VideoView, coordinator: Coordinator) {
    // SwiftUI から破棄される際に MediaStream との関連を切り離す
    coordinator.unbind(view: uiView)
  }

  private func configure(_ view: VideoView) {
    // connectionMode が変更されていれば反映する
    if view.connectionMode != connectionMode {
      view.connectionMode = connectionMode
    }
    // contentMode の差異を検知して適用する
    if view.contentMode != contentMode {
      view.contentMode = contentMode
    }
    // デバッグ表示の有無を同期する
    if view.debugMode != debugMode {
      view.debugMode = debugMode
    }

    // 背景ビューは参照が異なる場合のみ付け替えを行う
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
    // 現在 VideoView にバインドされている MediaStream を弱参照で保持する
    private weak var currentStream: MediaStream?

    fileprivate func bind(stream: MediaStream?, to view: VideoView) {
      // すでに同じストリームがバインドされていれば何もしない
      guard currentStream !== stream else {
        return
      }
      // 変更前のストリームとの接続を解除する
      detach(from: currentStream, view: view)
      // 新しいストリームが存在すれば VideoView に描画先として割り当てる
      if let stream {
        stream.videoRenderer = view
      }
      currentStream = stream
    }

    fileprivate func unbind(view: VideoView) {
      // 保持しているストリームとの接続を解除する
      detach(from: currentStream, view: view)
    }

    private func detach(from stream: MediaStream?, view: VideoView) {
      // ストリームがなければ状態をクリアして終了する
      guard let stream else {
        currentStream = nil
        return
      }
      // VideoView が描画先として登録されていれば解除する
      if stream.videoRenderer === view {
        stream.videoRenderer = nil
      }
      // Coordinator が保持するストリーム参照も破棄する
      if currentStream === stream {
        currentStream = nil
      }
    }
  }
}
