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
///
/// - Note: 通常のユーザーは、このプロトコルを直接実装する必要はありません
public protocol RPCMethodProtocol {
  /// RPC メソッドのパラメータ型
  associatedtype Params: Encodable
  /// RPC メソッドの戻り値型
  associatedtype Result: Decodable
  /// RPC メソッド名 (例: "2025.2.0/RequestSimulcastRid")
  static var name: String { get }
}

public struct RequestSimulcastRidParams: Encodable {
  public let rid: String
  public let senderConnectionId: String?

  public init(rid: String, senderConnectionId: String? = nil) {
    self.rid = rid
    self.senderConnectionId = senderConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case rid
    case senderConnectionId = "sender_connection_id"
  }
}

public struct RequestSpotlightRidParams: Encodable {
  public let sendConnectionId: String?
  public let spotlightFocusRid: String
  public let spotlightUnfocusRid: String

  public init(
    sendConnectionId: String? = nil,
    spotlightFocusRid: String,
    spotlightUnfocusRid: String
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

public struct ResetSpotlightRidParams: Encodable {
  public let sendConnectionId: String?

  public init(sendConnectionId: String? = nil) {
    self.sendConnectionId = sendConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case sendConnectionId = "send_connection_id"
  }
}

public struct PutSignalingNotifyMetadataParams<Metadata: Encodable>: Encodable {
  public let metadata: Metadata
  public let push: Bool?

  public init(metadata: Metadata, push: Bool? = nil) {
    self.metadata = metadata
    self.push = push
  }
}

public struct PutSignalingNotifyMetadataItemParams<Value: Encodable>: Encodable {
  public let key: String
  public let value: Value
  public let push: Bool?

  public init(key: String, value: Value, push: Bool? = nil) {
    self.key = key
    self.value = value
    self.push = push
  }
}

public struct RequestSimulcastRidResult: Decodable {
  public let channelId: String
  public let receiverConnectionId: String
  public let rid: String
  public let senderConnectionId: String?

  public init(
    channelId: String,
    receiverConnectionId: String,
    rid: String,
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

public struct RequestSpotlightRidResult: Decodable {
  public let channelId: String
  public let recvConnectionId: String
  public let spotlightFocusRid: String
  public let spotlightUnfocusRid: String

  public init(
    channelId: String,
    recvConnectionId: String,
    spotlightFocusRid: String,
    spotlightUnfocusRid: String
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

public struct ResetSpotlightRidResult: Decodable {
  public let channelId: String
  public let recvConnectionId: String

  public init(channelId: String, recvConnectionId: String) {
    self.channelId = channelId
    self.recvConnectionId = recvConnectionId
  }

  enum CodingKeys: String, CodingKey {
    case channelId = "channel_id"
    case recvConnectionId = "recv_connection_id"
  }
}

// MARK: - RPC メソッド型の命名規則について

/// # RPC メソッド型の命名規則
///
/// ## 現在の命名規則
/// 現在、RPC メソッド型は `RequestSimulcastRid`、`RequestSpotlightRid` のようにメソッド名のみで命名しています。
/// メソッド名のバージョン情報（例：`2025.2.0`）は、型の `name` プロパティに格納されています。
///
/// ```swift
/// public enum RequestSimulcastRid: RPCMethodProtocol {
///   public static let name = "2025.2.0/RequestSimulcastRid"
/// }
/// ```
///
/// ## 将来の命名規則への移行計画
/// 同じメソッド名でバージョンが異なる場合（例：`2025.2.0/RequestSpotlightRid` と `2027.2.0/RequestSpotlightRid`）が増えた際には、
/// バージョン情報を型名に含める新しい命名規則に移行する予定です。
///
/// ### 新しい命名規則の例
/// ```swift
/// // 新しい命名規則の例（将来のバージョン）
/// public enum RequestSpotlightRid_2025_2_0: RPCMethodProtocol { ... }
/// public enum RequestSpotlightRid_2027_2_0: RPCMethodProtocol { ... }
/// ```
///
/// ## 移行時のアプローチ
/// 1. **既存の型はエイリアスを作成**
///    - 既存の型は新しい命名規則の型のエイリアスとして提供します
/// 2. **deprecated マーク**
///    - 既存の型を `@deprecated` マークし、ユーザーに移行を促します
/// 3. **新規メソッドは新しい命名規則で追加**
///    - 将来追加されるメソッドは新しい命名規則で定義します
///
/// このアプローチにより、既存コードとの互換性を保ちながら、スムーズに移行できるようにしています。

/// サイマルキャスト の rid をリクエストする RPC メソッド
///
/// 視聴するサイマルキャスト映像の解像度を指定する RPC メソッドです。
public enum RequestSimulcastRid: RPCMethodProtocol {
  public typealias Params = RequestSimulcastRidParams
  public typealias Result = RequestSimulcastRidResult
  public static let name = RPCMethodNames.requestSimulcastRid
}

/// スポットライト rid をリクエストする RPC メソッド
///
/// スポットライト機能で注目する接続を指定する RPC メソッドです。
public enum RequestSpotlightRid: RPCMethodProtocol {
  public typealias Params = RequestSpotlightRidParams
  public typealias Result = RequestSpotlightRidResult
  public static let name = RPCMethodNames.requestSpotlightRid
}

/// スポットライト rid をリセットする RPC メソッド
///
/// スポットライト機能の設定をリセットする RPC メソッドです。
public enum ResetSpotlightRid: RPCMethodProtocol {
  public typealias Params = ResetSpotlightRidParams
  public typealias Result = ResetSpotlightRidResult
  public static let name = RPCMethodNames.resetSpotlightRid
}

/// シグナリング通知メタデータを設定する RPC メソッド
///
/// シグナリング通知全体にメタデータを設定する RPC メソッドです。
/// ジェネリック型パラメータで任意の型のメタデータを指定できます。
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
public enum PutSignalingNotifyMetadataItem<Metadata: Decodable, Value: Encodable>:
  RPCMethodProtocol
{
  public typealias Params = PutSignalingNotifyMetadataItemParams<Value>
  public typealias Result = Metadata
  public static var name: String {
    RPCMethodNames.putSignalingNotifyMetadataItem
  }
}

/// RPC メソッドを型安全に表現する Enum
///
/// MediaChannel.rpcMethods で利用可能なメソッドをこの型として取得できます。
/// このEnum を使用することで、コンパイル時にメソッド名の妥当性が検証されます。
///
/// # 使用例
/// ```swift
/// if mediaChannel.rpcMethods.contains(.requestSimulcastRid) {
///   let params = RequestSimulcastRidParams(rid: "r0")
///   let response = try await mediaChannel.rpc(
///     method: RequestSimulcastRid.self,
///     params: params
///   )
/// }
/// ```
public enum RPCMethod {
  case requestSimulcastRid
  case requestSpotlightRid
  case resetSpotlightRid
  case putSignalingNotifyMetadata
  case putSignalingNotifyMetadataItem

  var name: String {
    switch self {
    case .requestSimulcastRid:
      return RPCMethodNames.requestSimulcastRid
    case .requestSpotlightRid:
      return RPCMethodNames.requestSpotlightRid
    case .resetSpotlightRid:
      return RPCMethodNames.resetSpotlightRid
    case .putSignalingNotifyMetadata:
      return RPCMethodNames.putSignalingNotifyMetadata
    case .putSignalingNotifyMetadataItem:
      return RPCMethodNames.putSignalingNotifyMetadataItem
    }
  }

  init?(name: String) {
    let allMethods: [RPCMethod] = [
      .requestSimulcastRid,
      .requestSpotlightRid,
      .resetSpotlightRid,
      .putSignalingNotifyMetadata,
      .putSignalingNotifyMetadataItem,
    ]
    guard let method = allMethods.first(where: { $0.name == name }) else {
      return nil
    }
    self = method
  }
}
