// 検査する契約:
//   - Swift 5 言語モードで compile される consumer が、manifest の swiftLanguageModes で
//     Swift 6 言語モードになる Sora を import して公開 API を利用できること。
//     この file の compile 行が -swift-version 5、Sora target の compile 行が
//     -swift-version 6 になることを build ログで確認する。
//   - Swift 5 言語モードのアプリで典型的な書き方 (handler closure が self を capture する、
//     main queue の完了 closure から MediaChannel を参照する、nonisolated な VideoRenderer、
//     @MainActor の文脈で VideoView を扱う) がそのまま build できること。
//   - nonisolated な global shared mutable state が診断されないこと。この file を Swift 6
//     言語モードで compile すると MutableGlobalVariable の error になるため、この契約は
//     consumer の言語モードが実際に Swift 5 であることの担保にもなる。
// 期待する診断: なし (error 0 件、warning 0 件)
//
// 注意: 明示的に @Sendable と書いた closure への非 Sendable な capture は、Swift 5 言語モードでも
// warning ("this is an error in the Swift 6 language mode") になり、この target の
// warnings-as-errors では error になる。そのためこの file では明示的な @Sendable の closure を
// 使わない。同じ capture を Swift 6 言語モードの負例として
// NegativeChecks/core-sendable-capture.swift が SendableClosureCaptures で検査する。
import Foundation
import Sora
import UIKit

/// Sora へ渡す接続メタデータ。
/// Swift 5 言語モードのアプリで典型的な Codable な値を signalingConnectMetadata に設定する。
struct Swift5SignalingMetadata: Codable {
  let appName: String
  let version: Int
}

/// 接続設定を組み立てる。
func makeConfiguration(url: URL, channelId: String) -> Configuration {
  var configuration = Configuration(url: url, channelId: channelId, role: .sendrecv)
  configuration.clientId = "swift5-consumer"
  configuration.bundleId = "jp.shiguredo.swift5-consumer"
  configuration.signalingConnectMetadata = Swift5SignalingMetadata(
    appName: "ConsumerSwift5",
    version: 1
  )
  configuration.videoEnabled = true
  configuration.audioEnabled = true
  return configuration
}

/// 接続状態を保持する、Swift 5 言語モードのアプリで典型的な class。
/// handler の closure が self を capture し、接続中の MediaChannel を保持する。
final class Swift5SoraClient {
  /// 接続中の MediaChannel。切断後は nil にする。
  private var mediaChannel: MediaChannel?

  /// 実行中の接続タスク。
  private var connectionTask: ConnectionTask?

  /// 接続を開始し、完了時の MediaChannel を保持する。
  /// connect は同期メソッドで handler は非 Sendable な closure 型のため、
  /// Swift 5 言語モードのアプリと同じく self をそのまま capture できる。
  func connect(configuration: Configuration) {
    connectionTask = Sora.shared.connect(configuration: configuration) { mediaChannel, error in
      self.mediaChannel = mediaChannel
      _ = error
    }
  }

  /// 接続を中断する。
  func disconnect() {
    connectionTask?.cancel()
    connectionTask = nil
  }

  /// 保持している MediaChannel の統計を取得する。
  func fetchStatistics() {
    mediaChannel?.getStats { result in
      switch result {
      case .success(let statistics):
        _ = statistics
      case .failure(let error):
        _ = error
      }
    }
  }

  /// 保持している MediaChannel の公開プロパティを参照する。
  func describeChannel() {
    guard let mediaChannel = mediaChannel else {
      return
    }
    _ = mediaChannel.state
    _ = mediaChannel.isAvailable
    _ = mediaChannel.connectionId
    _ = mediaChannel.clientId
    _ = mediaChannel.connectionCount
    _ = mediaChannel.publisherCount
    _ = mediaChannel.subscriberCount
  }

  /// DataChannel でメッセージを送る。
  func sendMessage(label: String, data: Data) -> Error? {
    mediaChannel?.sendMessage(label: label, data: data)
  }
}

/// Swift 5 言語モードのアプリでよくある、グローバルな可変状態としての client。
/// Swift 6 言語モードでは nonisolated な global shared mutable state として
/// MutableGlobalVariable の error になるが、Swift 5 言語モードでは診断されない。
var sharedSwift5Client = Swift5SoraClient()

/// グローバルな client を参照する。
func useSharedClient() {
  sharedSwift5Client.disconnect()
  _ = sharedSwift5Client.sendMessage(label: "swift5", data: Data())
}

/// 映像を描画しない VideoRenderer の実装。
/// Swift 5 言語モードのアプリと同じく nonisolated な型で VideoRenderer に準拠する。
final class Swift5VideoRenderer: VideoRenderer {
  func onChange(size: CGSize) {}

  func render(videoFrame: VideoFrame?) {}

  func onDisconnect(from mediaChannel: MediaChannel?) {}

  func onAdded(from mediaStream: MediaStream) {}

  func onRemoved(from mediaStream: MediaStream) {}

  func onSwitch(video: Bool) {}

  func onSwitch(audio: Bool) {}
}

/// MediaStream へ renderer を設定し、公開プロパティを参照する。
func attachRenderer(to mediaStream: MediaStream) {
  mediaStream.videoRenderer = Swift5VideoRenderer()
  mediaStream.videoEnabled = true
  mediaStream.audioEnabled = true
  _ = mediaStream.streamId
  _ = mediaStream.hasVideoTrack
  _ = mediaStream.hasAudioTrack
  mediaStream.terminate()
}

/// MainActor の文脈で VideoView を生成して操作する。
/// UIKit の型は MainActor に隔離されるため、Swift 5 言語モードでも @MainActor の注釈が要る。
@MainActor
func useVideoView() {
  let videoView = VideoView(frame: .zero)
  videoView.connectionMode = .autoClear
  videoView.backgroundView = UIView(frame: .zero)
  videoView.debugMode = false
  videoView.start()
  videoView.stop()
  videoView.clear()
  _ = videoView.isRendering
  _ = videoView.currentVideoFrameSize
}

/// MainActor の文脈で MediaStream へ VideoView を renderer として設定する。
@MainActor
func attachVideoView(to mediaStream: MediaStream) {
  let videoView = VideoView(frame: .zero)
  mediaStream.videoRenderer = videoView
}

/// main queue の完了 closure から MediaChannel を参照する。
/// Swift 5 言語モードのアプリで典型的な、main queue へ戻して SDK の状態を読む書き方。
func accessChannelOnMainQueue(_ mediaChannel: MediaChannel) {
  DispatchQueue.main.async {
    _ = mediaChannel.connectionId
  }
}
