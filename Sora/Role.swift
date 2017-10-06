import Foundation

public enum Role {
    case publisher
    case subscriber
    case group
}

private var roleTable: PairTable<String, Role> =
    PairTable(pairs: [("publisher", .publisher),
                      ("subscriber", .subscriber),
                      ("group", .group)])

/**
 :nodoc:
 */
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
