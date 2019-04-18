import Foundation

/**
 接続するクライアントのロールを表します。
 */
public enum Role {
    
    /// パブリッシャー
    case publisher
    
    /// サブスクライバー
    case subscriber
    
    /// グループ (マルチストリーム、配信)
    case group
    
    /// グループ (マルチストリーム、視聴のみ)
    case groupSub
}

private var roleTable: PairTable<String, Role> =
    PairTable(name: "Role",
              pairs: [("publisher", .publisher),
                      ("subscriber", .subscriber),
                      ("group", .group),
                      ("groupSub", .groupSub)])

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
        get {
            return roleTable.left(other: self)!
        }
    }
    
}
