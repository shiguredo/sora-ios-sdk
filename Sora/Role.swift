import Foundation

/// 接続するクライアントのロールを表します。
public enum Role {
  /// 送信のみ
  case sendonly

  /// 受信のみ
  case recvonly

  /// 送受信
  case sendrecv
}

private var roleTable: PairTable<String, Role> =
  PairTable(
    name: "Role",
    pairs: [
      ("sendonly", .sendonly),
      ("recvonly", .recvonly),
      ("sendrecv", .sendrecv),
    ])

/// :nodoc:
extension Role: Codable {
  public init(from decoder: Decoder) throws {
    self = try roleTable.decode(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try roleTable.encode(self, to: encoder)
  }
}

extension Role: CustomStringConvertible {
  /// 文字列表現を返します。
  public var description: String {
    roleTable.left(other: self)!
  }
}
