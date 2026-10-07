// 検査する契約:
//   - RPC を nonisolated な async 文脈から呼べること (RPCMethodProtocol は params / result に
//     Sendable を要求しないため、非 Sendable な値でも呼べる。Sendable 化は別の作業)
//   - 利用者定義の RPCMethodProtocol 準拠型 (`static var name`) で rpc を呼べること
//   - RPC のサーバーエラーが運ぶ `data` を公開 JSONValue の case 分岐で読めること
//   - 戻り値 Error? の API (sendMessage / setAudioSoftMute) を nonisolated な文脈から呼べること
//   - getStats(handler:) に非 Sendable な closure を渡せること
//   - getStatsSnapshot(handler:) に非 Sendable な closure を渡せること
//   - getStatsSnapshot() の戻り値 (StatisticsSnapshot) を actor / Task 境界へ渡せること
//   - SendableRPCMethodProtocol 準拠型で sendableRPC を呼べること
//   - sendableRPC の params / result と SendableRPCResponse を @Sendable closure へ渡せること
//   - 新旧両方の protocol へ準拠した同じ型で、既存 rpc の戻り値が RPCResponse<M.Result>? の
//     ままであること (sendableRPC が別名のため overload の解決先が変わらないこと)
//   - 型パラメータが非 Sendable な場合、ジェネリックな組み込みメソッドは従来どおり
//     RPCMethodProtocol だけに準拠し、既存 rpc の呼び出しが壊れないこと
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

/// サイマルキャストの rid を、Sendable な RPC API で切り替える。
///
/// 組み込みの `RequestSimulcastRid` は `SendableRPCMethodProtocol` へも準拠しているため、
/// `sendableRPC` から呼べる。戻り値は `SendableRPCResponse<RequestSimulcastRidResult>?` になる。
func requestSimulcastRidSendable(_ mediaChannel: MediaChannel, rid: Rid) async throws {
  let response = try await mediaChannel.sendableRPC(
    method: RequestSimulcastRid.self,
    params: RequestSimulcastRidParams(rid: rid)
  )
  _ = response?.result
}

/// シグナリング通知メタデータを、Sendable な RPC API で設定する。
///
/// ジェネリックな組み込みメソッドは `SendablePutSignalingNotifyMetadata` を使う。
func putSignalingNotifyMetadataSendable(_ mediaChannel: MediaChannel) async throws {
  let metadata = SignalingMetadata(appName: "Swift6Consumer", version: 2)
  let response = try await mediaChannel.sendableRPC(
    method: SendablePutSignalingNotifyMetadata<SignalingMetadata>.self,
    params: PutSignalingNotifyMetadataParams(metadata: metadata)
  )
  if let result = response?.result {
    _ = result.appName
  }
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

/// `Sendable` ではない型パラメータ。
///
/// `final class` は可変の stored property を持つ場合に `Sendable` が推論されないため、
/// 非 `Sendable` な params / result の代わりに使う (`internal` な struct は `Sendable` が
/// 推論されるため、この検証には使えない)。
///
/// `Sendable` な `Metadata` だけを扱う `SendablePutSignalingNotifyMetadata` の型パラメータには
/// 指定できない。指定できるのは既存 `PutSignalingNotifyMetadata` だけである。
final class NonSendableMetadata: Codable {
  var appName: String

  init(appName: String) {
    self.appName = appName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appName = try container.decode(String.self, forKey: .appName)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appName, forKey: .appName)
  }

  private enum CodingKeys: String, CodingKey {
    case appName
  }
}

/// 型パラメータが非 `Sendable` な場合でも、既存 `PutSignalingNotifyMetadata` + `rpc` を呼べること。
///
/// 既存 `RPCMethodProtocol` の associated type の制約は `Encodable` / `Decodable` のままで、
/// `Sendable` を要求しない。この scenario がコンパイルできることが、非 `Sendable` な型パラメータを
/// 使う既存の呼び出しを新 API の追加が壊していないことの確認になる。
func putSignalingNotifyMetadataWithNonSendableMetadata(_ mediaChannel: MediaChannel) async throws {
  let metadata = NonSendableMetadata(appName: "Swift6Consumer")
  let response = try await mediaChannel.rpc(
    method: PutSignalingNotifyMetadata<NonSendableMetadata>.self,
    params: PutSignalingNotifyMetadataParams(metadata: metadata)
  )
  if let result = response?.result {
    _ = result.appName
  }
}

/// 利用者定義の RPC メソッド (新旧両方の protocol へ準拠)。
///
/// `RPCMethodProtocol` と `SendableRPCMethodProtocol` の両方へ準拠した型を定義できることと、
/// 同じ型で `rpc` (旧) と `sendableRPC` (新) の両方を呼べることを検証する。
enum DualRPCMethod: RPCMethodProtocol, SendableRPCMethodProtocol {
  typealias Params = DualRPCMethodParams
  typealias Result = DualRPCMethodResult

  static var name: String { "jp.shiguredo.swift6-consumer/Dual" }
}

/// `DualRPCMethod` のパラメータ。
struct DualRPCMethodParams: Encodable, Sendable {
  let message: String
}

/// `DualRPCMethod` の戻り値。
struct DualRPCMethodResult: Decodable, Sendable {
  let message: String
}

/// 利用者定義の `SendableRPCMethodProtocol` 準拠型で `sendableRPC` を呼ぶ。
func callUserDefinedSendableMethod(_ mediaChannel: MediaChannel) async throws {
  let response = try await mediaChannel.sendableRPC(
    method: DualRPCMethod.self,
    params: DualRPCMethodParams(message: "ping")
  )
  _ = response?.result.message
}

/// 新旧両方の protocol へ準拠した同じ型で、既存 `rpc` の戻り値の型が変わらないことを検証する。
///
/// `sendableRPC` を同名 overload にすると呼び出しが新 overload へ解決されて戻り値の型が変わり、
/// source compatibility が壊れる。`RPCResponse<DualRPCMethod.Result>?` として受け取れることを
/// この代入でコンパイル時に検証する。
func callDualConformingMethodWithLegacyRPC(_ mediaChannel: MediaChannel) async throws {
  let response: RPCResponse<DualRPCMethod.Result>? = try await mediaChannel.rpc(
    method: DualRPCMethod.self,
    params: DualRPCMethodParams(message: "ping")
  )
  _ = response?.result.message
}

/// `sendableRPC` の params / result と `SendableRPCResponse` が `@Sendable` closure を越えられることを検証する。
///
/// `@Sendable` closure から外側の値を参照できるのは、その値が `Sendable` の場合だけである。
/// 参照は `_ = 値` で行う (参照しないと型検査されないため)。
func crossSendableRPCValuesInSendableClosure() {
  let params = DualRPCMethodParams(message: "ping")
  let result = DualRPCMethodResult(message: "pong")
  let response = SendableRPCResponse<DualRPCMethod.Result>(id: 1, result: result)
  let closure: @Sendable () -> Void = {
    _ = params
    _ = result
    _ = response.result
  }
  _ = closure
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

/// 統計情報を snapshot として取得する。戻り値は immutable で deep Sendable なため、
/// actor / Task 境界を越えて受け渡せる。
func fetchStatisticsSnapshot(_ mediaChannel: MediaChannel) async throws {
  // callback 版: handler は非 Sendable な closure 型のため、nonisolated な文脈からそのまま渡せる。
  mediaChannel.getStatsSnapshot { result in
    switch result {
    case .success(let snapshot):
      _ = snapshot.timestamp
      for entry in snapshot.entries {
        _ = entry.id
        _ = entry.type
        _ = entry.values
      }
    case .failure(let error):
      _ = error
    }
  }

  // async 版: snapshot は `Sendable` のため `@Sendable` closure へ渡せる。
  let snapshot = try await mediaChannel.getStatsSnapshot()
  let values: [String: JSONValue] = snapshot.entries.first?.values ?? [:]
  let closure: @Sendable () -> Void = {
    _ = snapshot
    _ = values
  }
  _ = closure
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
