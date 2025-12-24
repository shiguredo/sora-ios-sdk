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

public enum RPCJSONValue: Codable {
  case object([String: RPCJSONValue])
  case array([RPCJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init?(any value: Any) {
    if let dictionary = value as? [String: Any] {
      var mapped: [String: RPCJSONValue] = [:]
      for (key, item) in dictionary {
        guard let jsonValue = RPCJSONValue(any: item) else {
          return nil
        }
        mapped[key] = jsonValue
      }
      self = .object(mapped)
      return
    }
    if let array = value as? [Any] {
      let mapped = array.compactMap { RPCJSONValue(any: $0) }
      guard mapped.count == array.count else {
        return nil
      }
      self = .array(mapped)
      return
    }
    if let string = value as? String {
      self = .string(string)
      return
    }
    if let bool = value as? Bool {
      self = .bool(bool)
      return
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
      return
    }
    if value is NSNull {
      self = .null
      return
    }
    return nil
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: DynamicCodingKeys.self) {
      var object: [String: RPCJSONValue] = [:]
      for key in container.allKeys {
        object[key.stringValue] = try container.decode(RPCJSONValue.self, forKey: key)
      }
      self = .object(object)
      return
    }
    if var container = try? decoder.unkeyedContainer() {
      var array: [RPCJSONValue] = []
      while !container.isAtEnd {
        array.append(try container.decode(RPCJSONValue.self))
      }
      self = .array(array)
      return
    }
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
      return
    }
    if let number = try? container.decode(Double.self) {
      self = .number(number)
      return
    }
    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "RPCJSONValue のデコードに失敗しました")
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .object(let object):
      var container = encoder.container(keyedBy: DynamicCodingKeys.self)
      for (key, value) in object {
        try container.encode(value, forKey: DynamicCodingKeys(stringValue: key))
      }
    case .array(let array):
      var container = encoder.unkeyedContainer()
      for value in array {
        try container.encode(value)
      }
    case .string(let string):
      var container = encoder.singleValueContainer()
      try container.encode(string)
    case .number(let number):
      var container = encoder.singleValueContainer()
      try container.encode(number)
    case .bool(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }
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

public struct PutSignalingNotifyMetadataParams: Encodable {
  public let metadata: [String: RPCJSONValue]
  public let push: Bool?

  public init(metadata: [String: RPCJSONValue], push: Bool? = nil) {
    self.metadata = metadata
    self.push = push
  }
}

public struct PutSignalingNotifyMetadataItemParams: Encodable {
  public let key: String
  public let value: RPCJSONValue
  public let push: Bool?

  public init(key: String, value: RPCJSONValue, push: Bool? = nil) {
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

public typealias PutSignalingNotifyMetadataResult = [String: RPCJSONValue]
public typealias PutSignalingNotifyMetadataItemResult = [String: RPCJSONValue]

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

public enum PutSignalingNotifyMetadata: RPCMethodProtocol {
  public typealias Params = PutSignalingNotifyMetadataParams
  public typealias Result = PutSignalingNotifyMetadataResult
  public static let name = "2025.2.0/PutSignalingNotifyMetadata"
}

public enum PutSignalingNotifyMetadataItem: RPCMethodProtocol {
  public typealias Params = PutSignalingNotifyMetadataItemParams
  public typealias Result = PutSignalingNotifyMetadataItemResult
  public static let name = "2025.2.0/PutSignalingNotifyMetadataItem"
}

private struct DynamicCodingKeys: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(intValue: Int) {
    return nil
  }

  init(stringValue: String) {
    self.stringValue = stringValue
  }
}
