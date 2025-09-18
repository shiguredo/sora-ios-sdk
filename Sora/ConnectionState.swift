import Foundation
import WebRTC

/// MediaChannel, SignalingChannel, WebSocketChannel の接続状態を表します。
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
    self == .connecting
  }

  var isDisconnected: Bool {
    switch self {
    case .disconnecting, .disconnected:
      return true
    default:
      return false
    }
  }

  init(_ state: PeerChannelConnectionState) {
    switch state {
    case .new:
      self = .disconnected
    case .connecting:
      self = .connecting
    // RTCPeerConnectionState の disconnected は connected に遷移する可能性があるため接続中として扱う
    case .connected, .disconnected:
      self = .connected
    case .closed, .failed, .unknown:
      self = .disconnected
    }
  }
}

/// PeerChannel の接続状態を表します。
enum PeerChannelConnectionState {
  case new
  case connecting
  case connected
  case disconnected
  case failed
  case closed
  case unknown

  init(_ state: RTCPeerConnectionState) {
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
    }
  }
}
