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

  /// ``WebSocketChannel`` が接続解除されたことを示します。
  /// 導入当初は Sora から受信したクローズフレームのステータスコードが 1000 以外のときにこの Error を返していたが
  /// 2025.2.0 から、ステータスコードが 1000 のときも onDisconnect に切断理由を返すためにこの Error を使うようになった
  /// また、この Error は onDisconnect では Error ではなく、SoraCloseEvent.ok(code, reason) としてユーザーに通知される
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

  /// RPC 機能が利用できない
  case rpcUnavailable(reason: String)

  /// 利用を許可されていない RPC メソッド
  case rpcMethodNotAllowed(method: String)

  /// RPC リクエストのエンコードに失敗
  case rpcEncodingError(reason: String)

  /// RPC レスポンスのデコードに失敗
  case rpcDecodingError(reason: String)

  /// RPC の送受信に利用する DataChannel が切断された
  case rpcDataChannelClosed(reason: String)

  /// RPC の応答がタイムアウトした
  case rpcTimeout

  /// RPC のエラー応答
  case rpcServerError(detail: RPCErrorDetail)

  /// DataChannel 経由のシグナリングで type: close を受信し、接続が解除されたことを示します。
  /// - statusCode: ステータスコード
  /// - reason: 切断理由
  case dataChannelClosed(statusCode: Int, reason: String)
}

/// :nodoc:
extension SoraError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .connectionCancelled:
      return "Connection is cancelled"
    case .connectionTimeout:
      return "Connection is timeout"
    case .connectionBusy(let reason):
      return "Connection is busy (\(reason))"
    case .webSocketClosed(let statusCode, let reason):
      var desc = "WebSocket is closed (\(statusCode.intValue()) "
      if let reason {
        desc.append(reason)
      } else {
        desc.append("Unknown reason")
      }
      desc.append(")")
      return desc
    case .webSocketError(let error):
      return "WebSocket error (\(error.localizedDescription))"
    case .signalingChannelError(let reason):
      return "SignalingChannel error (\(reason))"
    case .invalidSignalingMessage:
      return "Invalid signaling message format"
    case .unknownSignalingMessageType(let type):
      return "Unknown signaling message type \(type)"
    case .peerChannelError(let reason):
      return "PeerChannel error (\(reason))"
    case .cameraError(let reason):
      return "Camera error: \(reason)"
    case .messagingError(let reason):
      return "Messaging error: \(reason)"
    case .rpcUnavailable(let reason):
      return "RPC unavailable: \(reason)"
    case .rpcMethodNotAllowed(let method):
      return "RPC method not allowed: \(method)"
    case .rpcEncodingError(let reason):
      return "RPC encoding error: \(reason)"
    case .rpcDecodingError(let reason):
      return "RPC decoding error: \(reason)"
    case .rpcDataChannelClosed(let reason):
      return "RPC DataChannel is closed: \(reason)"
    case .rpcTimeout:
      return "RPC response timeout"
    case .rpcServerError(let detail):
      return "RPC server error: \(detail.message) (\(detail.code))"
    case .dataChannelClosed(let statusCode, let reason):
      return "DataChannel is closed (\(statusCode) \(reason))"
    }
  }
}
