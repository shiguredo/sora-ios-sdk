import Foundation

/**
 接続状態を表します。
 */
public enum ConnectionState {
    
    /// 接続試行中
    case connecting
    
    /// 接続成功済み
    case connected
    
    /// 接続解除試行中
    case disconnecting
    
    /// 接続解除済み
    case disconnected
    
    var isConnecting: Bool {
        get {
            return self == .connecting
        }
    }
    
    var isDisconnected: Bool {
        get {
            switch self {
            case .disconnecting, .disconnected:
                return true
            default:
                return false
            }
        }
    }
}
