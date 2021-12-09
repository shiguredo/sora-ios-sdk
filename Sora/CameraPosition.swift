import Foundation

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
