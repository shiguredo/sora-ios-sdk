import Foundation

/**
 接続するクライアントのロールを表します。
 */
public enum Role {
    
    /// パブリッシャー
    case publisher
    
    /// サブスクライバー
    case subscriber
    
    /// グループ (マルチストリーム)
    case group
}

private var roleTable: PairTable<String, Role> =
    PairTable(pairs: [("publisher", .publisher),
                      ("subscriber", .subscriber),
                      ("group", .group)])

/// :nodoc:
extension Role: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = roleTable.right(other: try container.decode(String.self))!
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(roleTable.left(other: self)!)
    }
    
}

extension Role: CustomStringConvertible {
    
    public var description: String {
        get {
            return roleTable.left(other: self)!
        }
    }
    
}
