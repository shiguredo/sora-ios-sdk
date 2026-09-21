// 検査する契約:
//   - Configuration を組み立てて signalingConnectMetadata に Encodable な値を設定できること
//   - Sora.shared.connect(configuration:handler:) を nonisolated な文脈から呼べること
//   - 戻り値の ConnectionTask の state を参照し cancel できること
// 期待する診断: なし (error 0 件、warning 0 件)
import Foundation
import Sora

/// Sora へ渡す接続メタデータ。
struct SignalingMetadata: Codable {
  let appName: String
  let version: Int
}

/// 接続設定を組み立てる。
func makeConfiguration(url: URL, channelId: String) -> Configuration {
  var configuration = Configuration(url: url, channelId: channelId, role: .sendrecv)
  configuration.clientId = "swift6-consumer"
  configuration.bundleId = "jp.shiguredo.swift6-consumer"
  configuration.signalingConnectMetadata = SignalingMetadata(appName: "Swift6Consumer", version: 1)
  configuration.videoEnabled = true
  configuration.audioEnabled = true
  return configuration
}

/// 接続を開始して ConnectionTask を返す。
/// connect は同期メソッドで handler は非 Sendable な closure 型のため、
/// nonisolated な文脈からそのまま渡せる。
func connectToSora(configuration: Configuration) -> ConnectionTask {
  let task = Sora.shared.connect(configuration: configuration) { mediaChannel, error in
    if let error {
      _ = error
    }
    if let mediaChannel {
      _ = mediaChannel.connectionId
    }
  }
  return task
}

/// 接続タスクの状態を参照する。
func connectionState(of task: ConnectionTask) -> ConnectionTask.State {
  task.state
}

/// 接続タスクをキャンセルする。
func cancelConnection(_ task: ConnectionTask) {
  task.cancel()
}
