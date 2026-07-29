import Foundation
import WebRTC

private let iceTransportPolicyTable: PairTable<ICETransportPolicy, RTCIceTransportPolicy> =
  PairTable(
    name: "ICETransportPolicy",
    pairs: [(.relay, .relay), (.all, .all)])

/// ICE 通信ポリシーを表します。
public enum ICETransportPolicy: Sendable {
  /// TURN サーバーを経由するメディアリレー候補のみを使用します。
  case relay

  /// すべての候補を使用します。
  case all

  var nativeValue: RTCIceTransportPolicy {
    // PairTable の定義上、全 case が網羅されているため安全
    // swiftlint:disable:next force_unwrapping
    iceTransportPolicyTable.right(other: self)!
  }
}

/// :nodoc:
extension ICETransportPolicy: CustomStringConvertible {
  public var description: String {
    switch self {
    case .relay:
      return "relay"
    case .all:
      return "all"
    }
  }
}

/// :nodoc:
extension ICETransportPolicy: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    if value == "relay" {
      self = .relay
    } else {
      throw
        DecodingError
        .dataCorruptedError(
          in: container,
          debugDescription: "invalid value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .relay:
      try container.encode("relay")
    case .all:
      try container.encode("all")
    }
  }
}
