import Foundation

/**
 接続するクライアントのロールを表します。
 */
public enum Role {
    
    /// この列挙子は sendonly に置き換えられました。
    @available(*, deprecated, renamed: "sendonly",
    message: "この列挙子は sendonly に置き換えられました。")
    case publisher
    
    /// この列挙子は recvonly に置き換えられました。
    @available(*, deprecated, renamed: "recvonly",
    message: "この列挙子は recvonly に置き換えられました。")
    case subscriber
    
    /// この列挙子は sendrecv に置き換えられました。
    @available(*, deprecated, renamed: "sendrecv",
    message: "この列挙子は sendrecv に置き換えられました。")
    case group
    
    /// この列挙子は廃止されました。マルチストリームで recvonly を指定してください。
    @available(*, deprecated,
    message: "この列挙子は廃止されました。マルチストリームで recvonly を指定してください。")
    case groupSub
    
    // 送信のみ
    case sendonly
    
    // 受信のみ
    case recvonly
    
    // 送受信
    case sendrecv
    
}

private var roleTable: PairTable<String, Role> =
    PairTable(name: "Role",
              pairs: [("publisher", .publisher),
                      ("subscriber", .subscriber),
                      ("group", .group),
                      ("groupSub", .groupSub),
                      ("sendonly", .sendonly),
                      ("recvonly", .recvonly),
                      ("sendrecv", .sendrecv)])

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
