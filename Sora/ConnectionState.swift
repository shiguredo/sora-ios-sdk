import Foundation
import WebRTC

/**
 PeerChannel, MediaChannel の接続状態を表します。
 TODO: enum 名が適切か検討する
 */
public enum SoraConnectionState {
    
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
    case unknown
    
    internal init(_ state: RTCPeerConnectionState) {
        // 参照: https://www.w3.org/TR/webrtc/#dom-rtcicetransportstate
        switch state {
        case .new:
            self = .new
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .failed:
            self = .failed
        case .closed:
            self = .closed
        @unknown default:
            self = .unknown
            break
        }
    }
}

/**
 接続状態を表します。
 WebRTC の ConnectionState とは異なります。
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
    
    internal init(_ state: SoraConnectionState) {
        switch state {
        case .new:
            self = .connecting
        case .connecting:
            self = .connecting
        // TODO: 要議論
        case .connected, .disconnected:
            self = .connected
        case .closed, .failed, .unknown:
            self = .disconnected
        }
    }
}
