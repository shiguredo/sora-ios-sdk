import Foundation

/// SDK に関するエラーを表します。
public enum SoraError: Error {
  /// 接続試行中に処理がキャンセルされたことを示します。
  case connectionCancelled

  /// 接続タイムアウト。
  /// 接続試行開始から一定時間内に接続できなかったことを示します。
  case connectionTimeout

  /// 何らかの処理の実行中で、指定された処理を実行できないことを示します。
  case connectionBusy(reason: String)

  /// ``WebSocketChannel`` が正常ではない状態で接続解除されたことを示します。
  case webSocketClosed(statusCode: WebSocketStatusCode, reason: String?)

  /// ``WebSocketChannel`` で発生したエラー
  case webSocketError(Error)

  /// ``SignalingChannel`` で発生したエラー
  case signalingChannelError(reason: String)

  /// シグナリングメッセージのフォーマットが無効
  case invalidSignalingMessage

  /// 非対応のシグナリングメッセージ種別
  case unknownSignalingMessageType(type: String)

  /// ``PeerChannel`` で発生したエラー
  case peerChannelError(reason: String)

  /// カメラに関するエラー
  case cameraError(reason: String)

  /// メッセージング機能のエラー
  case messagingError(reason: String)
}

/// :nodoc:
extension SoraError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .connectionCancelled:
      return "Connection is cancelled"
    case .connectionTimeout:
      return "Connection is timeout"
    case let .connectionBusy(reason: reason):
      return "Connection is busy (\(reason))"
    case let .webSocketClosed(statusCode: statusCode, reason: reason):
      var desc = "WebSocket is closed (\(statusCode.intValue()) "
      if let reason {
        desc.append(reason)
      } else {
        desc.append("Unknown reason")
      }
      desc.append(")")
      return desc
    case let .webSocketError(error):
      return "WebSocket error (\(error.localizedDescription))"
    case let .signalingChannelError(reason: reason):
      return "SignalingChannel error (\(reason))"
    case .invalidSignalingMessage:
      return "Invalid signaling message format"
    case let .unknownSignalingMessageType(type: type):
      return "Unknown signaling message type \(type)"
    case let .peerChannelError(reason: reason):
      return "PeerChannel error (\(reason))"
    case let .cameraError(reason: reason):
      return "Camera error: \(reason)"
    case let .messagingError(reason: reason):
      return "Messaging error: \(reason)"
    }
  }
}
