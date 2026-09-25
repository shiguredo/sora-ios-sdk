// 検査する契約:
//   - RPC を nonisolated な async 文脈から呼べること (RPCMethodProtocol は params / result に
//     Sendable を要求しないため、非 Sendable な値でも呼べる。Sendable 化は別の作業)
//   - 利用者定義の RPCMethodProtocol 準拠型 (`static var name`) で rpc を呼べること
//   - RPC のサーバーエラーが運ぶ `data` を公開 JSONValue の case 分岐で読めること
//   - 戻り値 Error? の API (sendMessage / setAudioSoftMute) を nonisolated な文脈から呼べること
//   - getStats(handler:) に非 Sendable な closure を渡せること
// 期待する診断: なし (error 0 件、warning 0 件)
import Foundation
import Sora

/// サイマルキャストの rid を切り替える。
/// params と result は SDK の公開型で、非 Sendable のまま async メソッドへ渡せる。
func requestSimulcastRid(_ mediaChannel: MediaChannel, rid: Rid) async throws {
  let response = try await mediaChannel.rpc(
    method: RequestSimulcastRid.self,
    params: RequestSimulcastRidParams(rid: rid)
  )
  _ = response?.result
}

/// シグナリング通知メタデータを設定する。
/// ジェネリックな RPC メソッドでも associated type が定まれば呼べる
/// (params は `PutSignalingNotifyMetadataParams<Metadata>`、result は `Metadata`)。
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

/// 利用者定義の RPC メソッド。
/// SDK が提供する型ではなく、利用者側で RPCMethodProtocol へ準拠した型を定義できる。
enum ConsumerPing: RPCMethodProtocol {
  typealias Params = ConsumerPingParams
  typealias Result = ConsumerPingResult

  static var name: String { "jp.shiguredo.swift6-consumer/Ping" }
}

/// 利用者定義の RPC メソッドのパラメータ。
struct ConsumerPingParams: Encodable {
  let message: String
}

/// 利用者定義の RPC メソッドの戻り値。
struct ConsumerPingResult: Decodable {
  let message: String
}

/// 利用者定義の RPCMethodProtocol 準拠型で RPC を呼ぶ。
func callUserDefinedMethod(_ mediaChannel: MediaChannel) async throws {
  let response = try await mediaChannel.rpc(
    method: ConsumerPing.self,
    params: ConsumerPingParams(message: "ping")
  )
  _ = response?.result.message
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

/// RPC のサーバーエラーが運ぶ追加情報を `JSONValue` の case 分岐で読む。
///
/// `RPCErrorDetail` は利用者側で組み立てられないため、`Error` から受け取って読む。
/// `data` は JSON-RPC 2.0 では任意フィールドで、サーバーが返したときだけ入る。
func describeRPCError(_ error: Error) -> String {
  guard let soraError = error as? SoraError,
    case .rpcServerError(let detail) = soraError
  else {
    return "RPC のサーバーエラーではない"
  }
  let dataDescription: String
  switch detail.data {
  case .none:
    dataDescription = "data なし"
  case .some(.null):
    dataDescription = "null"
  case .some(.bool(let value)):
    dataDescription = "\(value)"
  case .some(.decimal(let value)):
    dataDescription = "\(value)"
  case .some(.double(let value)):
    dataDescription = "\(value)"
  case .some(.string(let value)):
    dataDescription = value
  case .some(.array(let value)):
    dataDescription = "配列 \(value.count) 件"
  case .some(.object(let value)):
    dataDescription = "辞書 \(value.count) 件"
  }
  return "\(detail.message) (\(detail.code)) : \(dataDescription)"
}
