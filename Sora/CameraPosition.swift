import Foundation

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
