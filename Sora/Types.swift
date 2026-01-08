/// 映像の rid を表します。
public enum Rid: Equatable {
  /// 映像を受信しない
  case none

  /// r0
  case r0

  /// r1
  case r1

  /// r2
  case r2
}

private var ridTable: PairTable<String, Rid> =
  PairTable(
    name: "rid",
    pairs: [
      ("none", .none),
      ("r0", .r0),
      ("r1", .r1),
      ("r2", .r2),
    ])

/// :nodoc:
extension Rid: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let rid = ridTable.right(other: string) else {
      throw SoraError.invalidSignalingMessage
    }
    self = rid
  }

  public func encode(to encoder: Encoder) throws {
    try ridTable.encode(self, to: encoder)
  }
}
