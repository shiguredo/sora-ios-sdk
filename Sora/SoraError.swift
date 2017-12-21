import Foundation

/**
 SDK に関するエラーを表します。
 */
public enum SoraError: Error {
    
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
    case invalidSignalingMessage(text: String)
    
    /// ``PeerChannel`` で発生したエラー
    case peerChannelError(reason: String)
    
}

/// :nodoc:
extension SoraError: LocalizedError {
    
    public var errorDescription: String? {
        get {
            switch self {
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
            case .invalidSignalingMessage(text: let text):
                return "Invalid signaling message format (\"\(text)\")"
            case .peerChannelError(reason: let reason):
                return "PeerChannel error (\(reason))"
            }
        }
    }
    
}
