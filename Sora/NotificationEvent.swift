import Foundation

/**
 サーバーから定期的に通知されるイベントです。
 詳細は Sora のドキュメントを参照してください。
 */
public enum NotificationEvent {
    
    /// 接続中のチャネルに新しい接続が追加されたことを示します。
    case connectionCreated
    
    /// 1 分ごとに通知されます。
    case connectionUpdated
    
    /// 接続中のチャネルのいずれかの接続が解除されたことを示します。
    case connectionDestroyed
    
    init(message: SignalingNotifyMessage) {
        switch message.eventType {
        case .connectionCreated:
            self = .connectionCreated
        case .connectionUpdated:
            self = .connectionUpdated
        case .connectionDestroyed:
            self = .connectionDestroyed
        }
    }
    
}
