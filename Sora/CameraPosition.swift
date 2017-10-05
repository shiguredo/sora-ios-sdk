import Foundation

private var descriptionTable: PairTable<String, CameraPosition> =
    PairTable(pairs: [("front", .front),
                      ("back", .back)])

public enum CameraPosition {
    
    case front
    case back
    
    public func flip() -> CameraPosition {
        switch self {
        case .front:
            return .back
        case .back:
            return .front
        }
    }
    
}

extension CameraPosition: CustomStringConvertible {
    
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}
