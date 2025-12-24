import Foundation

/// RPC メソッドを表す。
public enum RPCMethod: Equatable {
  case requestSimulcastRid
  case requestSpotlightRid
  case resetSpotlightRid
  case putSignalingNotifyMetadata
  case putSignalingNotifyMetadataItem

  public init?(_ rawValue: String) {
    switch rawValue {
    case "2025.2.0/RequestSimulcastRid":
      self = .requestSimulcastRid
    case "2025.2.0/RequestSpotlightRid":
      self = .requestSpotlightRid
    case "2025.2.0/ResetSpotlightRid":
      self = .resetSpotlightRid
    case "2025.2.0/PutSignalingNotifyMetadata":
      self = .putSignalingNotifyMetadata
    case "2025.2.0/PutSignalingNotifyMetadataItem":
      self = .putSignalingNotifyMetadataItem
    default:
      return nil
    }
  }

  public var rawValue: String {
    switch self {
    case .requestSimulcastRid:
      return "2025.2.0/RequestSimulcastRid"
    case .requestSpotlightRid:
      return "2025.2.0/RequestSpotlightRid"
    case .resetSpotlightRid:
      return "2025.2.0/ResetSpotlightRid"
    case .putSignalingNotifyMetadata:
      return "2025.2.0/PutSignalingNotifyMetadata"
    case .putSignalingNotifyMetadataItem:
      return "2025.2.0/PutSignalingNotifyMetadataItem"
    }
  }
}

public protocol RPCMethodProtocol {
  associatedtype Params: Encodable
  associatedtype Result: Decodable
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

public enum RequestSimulcastRid: RPCMethodProtocol {
  public typealias Params = RequestSimulcastRidParams
  public typealias Result = RequestSimulcastRidResult
  public static let name = "2025.2.0/RequestSimulcastRid"
}

public enum RequestSpotlightRid: RPCMethodProtocol {
  public typealias Params = RequestSpotlightRidParams
  public typealias Result = RequestSpotlightRidResult
  public static let name = "2025.2.0/RequestSpotlightRid"
}

public enum ResetSpotlightRid: RPCMethodProtocol {
  public typealias Params = ResetSpotlightRidParams
  public typealias Result = ResetSpotlightRidResult
  public static let name = "2025.2.0/ResetSpotlightRid"
}

public enum PutSignalingNotifyMetadata<Metadata: Codable>: RPCMethodProtocol {
  public typealias Params = PutSignalingNotifyMetadataParams<Metadata>
  public typealias Result = Metadata
  public static var name: String {
    "2025.2.0/PutSignalingNotifyMetadata"
  }
}

public enum PutSignalingNotifyMetadataItem<Metadata: Decodable, Value: Encodable>:
  RPCMethodProtocol
{
  public typealias Params = PutSignalingNotifyMetadataItemParams<Value>
  public typealias Result = Metadata
  public static var name: String {
    "2025.2.0/PutSignalingNotifyMetadataItem"
  }
}
