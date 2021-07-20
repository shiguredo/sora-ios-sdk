import Foundation
import Starscream

/**
 SDK に関するエラーを表します。
 */
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
    
}

/// :nodoc:
extension SoraError: LocalizedError {
    
    public var errorDescription: String? {
        switch self {
        case .connectionCancelled:
            return "Connection is cancelled"
        case .connectionTimeout:
            return "Connection is timeout"
        case .connectionBusy(reason: let reason):
            return "Connection is busy (\(reason))"
        case .webSocketClosed(statusCode: let statusCode, reason: let reason):
            var desc = "WebSocket is closed (\(statusCode.intValue()) "
            if let reason = reason {
                desc.append(reason)
            } else {
                desc.append("Unknown reason")
            }
            desc.append(")")
            return desc
        case .webSocketError(let error):
            return "WebSocket error (\(error.localizedDescription))"
        case .signalingChannelError(reason: let reason):
            return "SignalingChannel error (\(reason))"
        case .invalidSignalingMessage:
            return "Invalid signaling message format"
        case .unknownSignalingMessageType(type: let type):
            return "Unknown signaling message type \(type)"
        case .peerChannelError(reason: let reason):
            return "PeerChannel error (\(reason))"
        case .cameraError(reason: let reason):
            return "Camera error: \(reason)"
        }
    }
    
}

/// :nodoc:
extension WSError: LocalizedError {
    
    public var errorDescription: String? {
        var desc = "\(code): "
        /*
        switch type {
        case .closeError:
            desc += "close error"
        case .compressionError:
            desc += "compression error"
        case .invalidSSLError:
            desc += "invalid SSL error"
        case .outputStreamWriteError:
            desc += "output stream write error"
        case .protocolError:
            desc += "protocol error"
        case .upgradeError:
            desc += "upgrade error"
        case .writeTimeoutError:
            desc += "write timeout error"
        }
        desc += ": \(message)"
 */
        return desc
    }

}
