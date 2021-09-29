import Foundation

private var descriptionTable: PairTable<String, CameraPosition> =
    PairTable(name: "CameraPosition",
              pairs: [("front", .front),
                      ("back", .back)])
/**
 カメラの位置を表します。
 廃止されました。
 */
@available(*, deprecated, message: "CameraPosition は廃止されました。")
public enum CameraPosition {
    
    /// 前面
    case front
    
    /// 背面
    case back
    
    /**
     カメラの位置の前面と背面を反転します。
     
     - returns: 反転後のカメラ位置
     */
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
    
    /// 文字列表現を返します。
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}
