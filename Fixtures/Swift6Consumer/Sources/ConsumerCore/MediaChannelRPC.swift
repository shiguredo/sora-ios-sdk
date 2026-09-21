// 検査する契約:
//   - Sendable な params / result を持つ RPC を nonisolated な async 文脈から呼べること
//   - 戻り値 Error? の API (sendMessage / setAudioSoftMute) を nonisolated な文脈から呼べること
//   - getStats(handler:) に非 Sendable な closure を渡せること
// 期待する診断: なし (error 0 件、warning 0 件)
import Foundation
import Sora

/// サイマルキャストの rid を切り替える。
/// params と result は SDK の公開型で、Sendable な値として async 境界を渡る。
func requestSimulcastRid(_ mediaChannel: MediaChannel, rid: Rid) async throws {
  let response = try await mediaChannel.rpc(
    method: RequestSimulcastRid.self,
    params: RequestSimulcastRidParams(rid: rid)
  )
  if let result = response?.result {
    _ = result
  }
}

/// シグナリング通知メタデータを設定する。
/// ジェネリックな RPC メソッドでも params と result の型が一致していれば呼べる。
func putSignalingNotifyMetadata(_ mediaChannel: MediaChannel) async throws {
  let metadata = SignalingMetadata(appName: "Swift6Consumer", version: 2)
  let response = try await mediaChannel.rpc(
    method: PutSignalingNotifyMetadata<SignalingMetadata>.self,
    params: PutSignalingNotifyMetadataParams(metadata: metadata)
  )
  if let result = response?.result {
    _ = result.appName
  }
}

/// 統計情報を取得する。handler は非 Sendable な closure 型のため、
/// nonisolated な文脈からそのまま渡せる。
func fetchStatistics(_ mediaChannel: MediaChannel) {
  mediaChannel.getStats { result in
    switch result {
    case .success(let statistics):
      _ = statistics
    case .failure(let error):
      _ = error
    }
  }
}

/// DataChannel でメッセージを送る。失敗時は Error が返る。
func sendMessage(_ mediaChannel: MediaChannel, label: String, data: Data) -> Error? {
  mediaChannel.sendMessage(label: label, data: data)
}

/// 音声の soft mute を設定する。失敗時は Error が返る。
func setAudioSoftMute(_ mediaChannel: MediaChannel, mute: Bool) -> Error? {
  mediaChannel.setAudioSoftMute(mute)
}

/// MediaChannel の公開プロパティを参照する。
func describe(_ mediaChannel: MediaChannel) {
  _ = mediaChannel.state
  _ = mediaChannel.isAvailable
  _ = mediaChannel.connectionId
  _ = mediaChannel.clientId
  _ = mediaChannel.bundleId
  _ = mediaChannel.contactUrl
  _ = mediaChannel.connectedUrl
  _ = mediaChannel.connectionTime
  _ = mediaChannel.connectionCount
  _ = mediaChannel.publisherCount
  _ = mediaChannel.subscriberCount
  _ = mediaChannel.mainStream
  _ = mediaChannel.senderStream
  _ = mediaChannel.receiverStreams
  _ = mediaChannel.description
}
