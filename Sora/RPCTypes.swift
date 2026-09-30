import Foundation

/// RPC メソッド名の定数定義
private enum RPCMethodNames {
  static let requestSimulcastRid = "2025.2.0/RequestSimulcastRid"
  static let requestSpotlightRid = "2025.2.0/RequestSpotlightRid"
  static let resetSpotlightRid = "2025.2.0/ResetSpotlightRid"
  static let putSignalingNotifyMetadata = "2025.2.0/PutSignalingNotifyMetadata"
  static let putSignalingNotifyMetadataItem = "2025.2.0/PutSignalingNotifyMetadataItem"
}

/// RPC メソッドを定義するためのプロトコル
///
/// 新しい RPC メソッドを SDK に追加する場合は、このプロトコルに準拠した型を定義してください。
public protocol RPCMethodProtocol {
  /// RPC メソッドのパラメータ型
  associatedtype Params: Encodable
  /// RPC メソッドの戻り値型
  associatedtype Result: Decodable
  /// RPC メソッド名 (例: "2025.2.0/RequestSimulcastRid")
  static var name: String { get }
}

/// actor / Task 境界へ安全に渡せる RPC メソッドを定義するためのプロトコル
///
/// `RPCMethodProtocol` を refine し、`Params` / `Result` に `Sendable` を要求します。
/// パラメータと結果を actor 境界や `Task` の `@Sendable` closure を越えて受け渡す場合は
/// このプロトコルへ準拠し、`MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:)`
/// を利用してください。
///
/// 既存の `RPCMethodProtocol` の制約は変更していないため、`Sendable` でない params / result を
/// 使う既存の利用者定義メソッドはそのまま `MediaChannel.rpc` を利用できます。
///
/// # 使用例
/// ```swift
/// struct MyRPCMethod: SendableRPCMethodProtocol {
///   typealias Params = MyParams
///   typealias Result = MyResult
///   static let name = "2025.2.0/MyRPCMethod"
/// }
/// ```
public protocol SendableRPCMethodProtocol: RPCMethodProtocol
where Params: Sendable, Result: Sendable {}

/// RequestSimulcastRid のパラメータ。
public struct RequestSimulcastRidParams: Codable, Sendable {
  /// 要求する映像の rid。
  public let rid: Rid
  /// 送信者のコネクション ID。
  public let senderConnectionId: String?

  /// RequestSimulcastRid のパラメータを作成する。
  public init(rid: Rid, senderConnectionId: String? = nil) {
    self.rid = rid
    self.senderConnectionId = senderConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case rid
    case senderConnectionId = "sender_connection_id"
  }
}

/// RequestSpotlightRid のパラメータ。
public struct RequestSpotlightRidParams: Codable, Sendable {
  /// 送信者のコネクション ID。
  public let sendConnectionId: String?
  /// 要求するスポットライトフォーカス時 rid。
  public let spotlightFocusRid: Rid
  /// 要求するスポットライトアンフォーカス時 rid。
  public let spotlightUnfocusRid: Rid

  /// RequestSpotlightRid のパラメータを作成する。
  public init(
    sendConnectionId: String? = nil,
    spotlightFocusRid: Rid,
    spotlightUnfocusRid: Rid
  ) {
    self.sendConnectionId = sendConnectionId
    self.spotlightFocusRid = spotlightFocusRid
    self.spotlightUnfocusRid = spotlightUnfocusRid
  }

  enum CodingKeys: String, CodingKey {
    case sendConnectionId = "send_connection_id"
    case spotlightFocusRid = "spotlight_focus_rid"
    case spotlightUnfocusRid = "spotlight_unfocus_rid"
  }
}

/// ResetSpotlightRid のパラメータ。
public struct ResetSpotlightRidParams: Encodable, Sendable {
  /// 送信者のコネクション ID。
  public let sendConnectionId: String?

  /// ResetSpotlightRid のパラメータを作成する。
  public init(sendConnectionId: String? = nil) {
    self.sendConnectionId = sendConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case sendConnectionId = "send_connection_id"
  }
}

/// PutSignalingNotifyMetadata のパラメータ。
///
/// `Metadata` が `Sendable` の場合は `Sendable` へも準拠します。actor / Task 境界へ渡す場合は
/// メソッド型に `SendablePutSignalingNotifyMetadata` を使ってください (既存の
/// `PutSignalingNotifyMetadata` は `Metadata` に `Sendable` を要求しないため、
/// `SendableRPCMethodProtocol` の要件を満たすメソッド型に `Metadata` を固定できません)。
public struct PutSignalingNotifyMetadataParams<Metadata: Encodable>: Encodable {
  /// 設定するメタデータ。
  public let metadata: Metadata
  /// メタデータ更新時に push 通知するかどうか。
  public let push: Bool?

  /// PutSignalingNotifyMetadata のパラメータを作成する。
  public init(metadata: Metadata, push: Bool? = nil) {
    self.metadata = metadata
    self.push = push
  }
}

/// `Metadata` が `Sendable` の場合に `PutSignalingNotifyMetadataParams` を actor / Task 境界へ渡せるようにする。
///
/// public で non-frozen な型は `Sendable` が推論されないため明示的に準拠させる。
/// `Sendable` への conditional conformance は許可されているため、既存の宣言は変えずに済む。
extension PutSignalingNotifyMetadataParams: Sendable where Metadata: Sendable {}

/// PutSignalingNotifyMetadataItem のパラメータ。
///
/// `Value` が `Sendable` の場合は `Sendable` へも準拠します。actor / Task 境界へ渡す場合は
/// メソッド型に `SendablePutSignalingNotifyMetadataItem` を使ってください (既存の
/// `PutSignalingNotifyMetadataItem` は `Value` に `Sendable` を要求しないため、
/// `SendableRPCMethodProtocol` の要件を満たすメソッド型に `Value` を固定できません)。
public struct PutSignalingNotifyMetadataItemParams<Value: Encodable>: Encodable {
  /// 設定するメタデータのキー。
  public let key: String
  /// 設定するメタデータの値。
  public let value: Value
  /// メタデータ更新時に push 通知するかどうか。
  public let push: Bool?

  /// PutSignalingNotifyMetadataItem のパラメータを作成する。
  public init(key: String, value: Value, push: Bool? = nil) {
    self.key = key
    self.value = value
    self.push = push
  }
}

/// `Value` が `Sendable` の場合に `PutSignalingNotifyMetadataItemParams` を actor / Task 境界へ渡せるようにする。
///
/// `Metadata` 側と同じ理由 (`PutSignalingNotifyMetadataParams` の extension を参照) で明示的に準拠させる。
extension PutSignalingNotifyMetadataItemParams: Sendable where Value: Sendable {}

/// RequestSimulcastRid の正常終了時の result。
public struct RequestSimulcastRidResult: Decodable, Sendable {
  /// チャンネル ID。
  public let channelId: String
  /// 受信者のコネクション ID。
  public let receiverConnectionId: String
  /// 適用された rid。
  public let rid: Rid
  /// 送信者のコネクション ID。
  public let senderConnectionId: String?

  /// RequestSimulcastRid の結果を作成する。
  public init(
    channelId: String,
    receiverConnectionId: String,
    rid: Rid,
    senderConnectionId: String?
  ) {
    self.channelId = channelId
    self.receiverConnectionId = receiverConnectionId
    self.rid = rid
    self.senderConnectionId = senderConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case channelId = "channel_id"
    case receiverConnectionId = "receiver_connection_id"
    case rid
    case senderConnectionId = "sender_connection_id"
  }
}

/// RequestSpotlightRid の正常終了時の result。
public struct RequestSpotlightRidResult: Decodable, Sendable {
  /// チャンネル ID。
  public let channelId: String
  /// 受信者のコネクション ID。
  public let recvConnectionId: String
  /// 要求するスポットライトフォーカス時 rid。
  public let spotlightFocusRid: Rid
  /// 要求するスポットライトアンフォーカス時 rid。
  public let spotlightUnfocusRid: Rid

  /// RequestSpotlightRid の結果を作成する。
  public init(
    channelId: String,
    recvConnectionId: String,
    spotlightFocusRid: Rid,
    spotlightUnfocusRid: Rid
  ) {
    self.channelId = channelId
    self.recvConnectionId = recvConnectionId
    self.spotlightFocusRid = spotlightFocusRid
    self.spotlightUnfocusRid = spotlightUnfocusRid
  }

  enum CodingKeys: String, CodingKey {
    case channelId = "channel_id"
    case recvConnectionId = "recv_connection_id"
    case spotlightFocusRid = "spotlight_focus_rid"
    case spotlightUnfocusRid = "spotlight_unfocus_rid"
  }
}

/// ResetSpotlightRid の正常終了時の result。
public struct ResetSpotlightRidResult: Decodable, Sendable {
  /// チャンネル ID。
  public let channelId: String
  /// 受信者のコネクション ID。
  public let recvConnectionId: String

  /// ResetSpotlightRid の結果を作成する。
  public init(channelId: String, recvConnectionId: String) {
    self.channelId = channelId
    self.recvConnectionId = recvConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case channelId = "channel_id"
    case recvConnectionId = "recv_connection_id"
  }
}

// # RPC メソッド型の命名規則
//
// ## 現在の命名規則
// 現在、RPC メソッド型は `RequestSimulcastRid`、`RequestSpotlightRid` のようにメソッド名のみで命名しています。
// メソッド名のバージョン情報（例：`2025.2.0`）は、型の `name` プロパティに格納されています。
//
// ```swift
// public enum RequestSimulcastRid: RPCMethodProtocol {
//   public static let name = "2025.2.0/RequestSimulcastRid"
// }
// ```
//
// ## 将来の命名規則への移行計画
// 同じメソッド名でバージョンが異なる場合（例：`2025.2.0/RequestSpotlightRid` と `2027.2.0/RequestSpotlightRid`）が増えた際には、
// バージョン情報を型名に含める新しい命名規則に移行する予定です。
//
// ### 新しい命名規則の例
// ```swift
// // 新しい命名規則の例（将来のバージョン）
// public enum RequestSpotlightRid_2025_2_0: RPCMethodProtocol { ... }
// public enum RequestSpotlightRid_2027_2_0: RPCMethodProtocol { ... }
// ```
//
// ## 移行時のアプローチ
// 1. **既存の型はエイリアスを作成**
//    - 既存の型は新しい命名規則の型のエイリアスとして提供します
// 2. **deprecated マーク**
//    - 既存の型を `@deprecated` マークし、ユーザーに移行を促します
// 3. **新規メソッドは新しい命名規則で追加**
//    - 将来追加されるメソッドは新しい命名規則で定義します
//
// このアプローチにより、既存コードとの互換性を保ちながら、スムーズに移行できるようにしています。

/// サイマルキャストの rid をリクエストする RPC メソッド
///
/// 視聴するサイマルキャスト映像の解像度を指定する RPC メソッドです。
public enum RequestSimulcastRid: RPCMethodProtocol {
  public typealias Params = RequestSimulcastRidParams
  public typealias Result = RequestSimulcastRidResult
  public static let name = RPCMethodNames.requestSimulcastRid
}

// params / result が `Sendable` のため、同じ型を `MediaChannel.sendableRPC` からも呼べる
extension RequestSimulcastRid: SendableRPCMethodProtocol {}

/// スポットライト rid をリクエストする RPC メソッド
///
/// スポットライト機能で注目する接続を指定する RPC メソッドです。
public enum RequestSpotlightRid: RPCMethodProtocol {
  public typealias Params = RequestSpotlightRidParams
  public typealias Result = RequestSpotlightRidResult
  public static let name = RPCMethodNames.requestSpotlightRid
}

// params / result が `Sendable` のため、同じ型を `MediaChannel.sendableRPC` からも呼べる
extension RequestSpotlightRid: SendableRPCMethodProtocol {}

/// スポットライト rid をリセットする RPC メソッド
///
/// スポットライト機能の設定をリセットする RPC メソッドです。
public enum ResetSpotlightRid: RPCMethodProtocol {
  public typealias Params = ResetSpotlightRidParams
  public typealias Result = ResetSpotlightRidResult
  public static let name = RPCMethodNames.resetSpotlightRid
}

// params / result が `Sendable` のため、同じ型を `MediaChannel.sendableRPC` からも呼べる
extension ResetSpotlightRid: SendableRPCMethodProtocol {}

/// シグナリング通知メタデータを設定する RPC メソッド
///
/// シグナリング通知全体にメタデータを設定する RPC メソッドです。
/// ジェネリック型パラメータで任意の型のメタデータを指定できます。
///
/// # 使用例
/// ```swift
/// struct MyMetadata: Codable {
///   let userId: String
///   let sessionId: String
/// }
///
/// do {
///   let metadata = MyMetadata(userId: "user123", sessionId: "sess456")
///   let result = try await mediaChannel.rpc(
///     method: PutSignalingNotifyMetadata<MyMetadata>.self,
///     params: PutSignalingNotifyMetadataParams(metadata: metadata)
///   )
///   if let metadata = result?.result {
///     print("Set metadata: \(metadata)")
///   }
/// } catch {
///   print("Failed to set metadata: \(error)")
/// }
/// ```
public enum PutSignalingNotifyMetadata<Metadata: Codable>: RPCMethodProtocol {
  public typealias Params = PutSignalingNotifyMetadataParams<Metadata>
  public typealias Result = Metadata
  public static var name: String {
    RPCMethodNames.putSignalingNotifyMetadata
  }
}

/// シグナリング通知メタデータのアイテムを設定する RPC メソッド
///
/// シグナリング通知メタデータの特定キーに値を設定する RPC メソッドです。
/// ジェネリック型パラメータで値の型とレスポンスの型を指定できます。
///
/// # 使用例
/// ```swift
/// struct NotifyResponse: Decodable {
///   let key: String
///   let value: String
/// }
///
/// do {
///   let result = try await mediaChannel.rpc(
///     method: PutSignalingNotifyMetadataItem<NotifyResponse, String>.self,
///     params: PutSignalingNotifyMetadataItemParams(
///       key: "status",
///       value: "ready"
///     )
///   )
///   if let response = result?.result {
///     print("Set metadata item - key: \(response.key), value: \(response.value)")
///   }
/// } catch {
///   print("Failed to set metadata item: \(error)")
/// }
/// ```
public enum PutSignalingNotifyMetadataItem<Metadata: Decodable, Value: Encodable>:
  RPCMethodProtocol
{
  public typealias Params = PutSignalingNotifyMetadataItemParams<Value>
  public typealias Result = Metadata
  public static var name: String {
    RPCMethodNames.putSignalingNotifyMetadataItem
  }
}

// # ジェネリックな RPC メソッドを Sendable に対応させる方針
//
// 既存の `PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem` へ
// conditional conformance を追加することはできません。Swift は「non-marker protocol への
// conditional conformance が marker protocol (Sendable) の準拠に依存すること」を禁止しており、
// `extension PutSignalingNotifyMetadata: SendableRPCMethodProtocol where Metadata: Sendable` は
//
//   conditional conformance to non-marker protocol 'SendableRPCMethodProtocol' cannot depend on
//   conformance of 'Metadata' to marker protocol 'Sendable'
//
// で失敗します。このため新 protocol 用の型を別に用意し、既存の型の宣言は変更しません。
// メソッド名は既存と同じ定数を参照するため、サーバーから見たメソッドは同一です。

/// シグナリング通知メタデータを設定する Sendable な RPC メソッド
///
/// `Metadata` が `Sendable` な場合に `MediaChannel.sendableRPC` から呼び出せます。
/// 既存 `PutSignalingNotifyMetadata` との使い分けは上のコメントを参照してください。
///
/// # 使用例
/// ```swift
/// struct MyMetadata: Codable, Sendable {
///   let userId: String
///   let sessionId: String
/// }
///
/// do {
///   let response = try await mediaChannel.sendableRPC(
///     method: SendablePutSignalingNotifyMetadata<MyMetadata>.self,
///     params: PutSignalingNotifyMetadataParams(metadata: metadata)
///   )
///   if let result = response?.result {
///     print("Set metadata: \(result)")
///   }
/// } catch {
///   print("Failed to set metadata: \(error)")
/// }
/// ```
public enum SendablePutSignalingNotifyMetadata<Metadata: Codable & Sendable>:
  SendableRPCMethodProtocol
{
  public typealias Params = PutSignalingNotifyMetadataParams<Metadata>
  public typealias Result = Metadata
  public static var name: String {
    RPCMethodNames.putSignalingNotifyMetadata
  }
}

/// シグナリング通知メタデータのアイテムを設定する Sendable な RPC メソッド
///
/// `Metadata` / `Value` が `Sendable` な場合に `MediaChannel.sendableRPC` から呼び出せます。
/// 既存 `PutSignalingNotifyMetadataItem` との使い分けは上のコメントを参照してください。
///
/// # 使用例
/// ```swift
/// struct NotifyResponse: Decodable, Sendable {
///   let key: String
///   let value: String
/// }
///
/// do {
///   let response = try await mediaChannel.sendableRPC(
///     method: SendablePutSignalingNotifyMetadataItem<NotifyResponse, String>.self,
///     params: PutSignalingNotifyMetadataItemParams(key: "status", value: "ready")
///   )
///   if let result = response?.result {
///     print("Set metadata item - key: \(result.key), value: \(result.value)")
///   }
/// } catch {
///   print("Failed to set metadata item: \(error)")
/// }
/// ```
public enum SendablePutSignalingNotifyMetadataItem<
  Metadata: Decodable & Sendable, Value: Encodable & Sendable
>: SendableRPCMethodProtocol {
  public typealias Params = PutSignalingNotifyMetadataItemParams<Value>
  public typealias Result = Metadata
  public static var name: String {
    RPCMethodNames.putSignalingNotifyMetadataItem
  }
}
