import Foundation

/**
 接続中のチャネルの統計情報です。
 サーバーによって通知されます。
 */
public struct MediaChannelStatistics {
    
    /// 接続時間
    public let connectionTime: Int
    
    /// チャネルに接続中のクライアントの数
    public let connectionCount: Int
    
    /// チャネルに接続中のクライアントのうち、パブリッシャーの数
    public let publisherCount: Int
    
    /// チャネルに接続中のクライアントの数のうち、サブスクライバーの数
    public let subscriberCount: Int
    
    init(message: SignalingNotifyMessage) {
        connectionTime = message.connectionTime
        connectionCount = message.connectionCount
        publisherCount = message.publisherCount
        subscriberCount = message.subscriberCount
    }
    
}

/**
 サーバーから通知されたイベントです。
 詳細は Sora のドキュメントを参照してください。
 */
public enum NotificationEvent {
    
    /// 接続中のチャネルに新しい接続が追加されたことを示します。
    case connectionCreated(statistics: MediaChannelStatistics)
    
    /// 1 分ごとに通知されます。
    case connectionUpdated(statistics: MediaChannelStatistics)
    
    /// 接続中のチャネルのいずれかの接続が解除されたことを示します。
    case connectionDestroyed(statistics: MediaChannelStatistics)
    
    init(message: SignalingNotifyMessage) {
        switch message.eventType {
        case .connectionCreated:
            let stats = MediaChannelStatistics(message: message)
            self = .connectionCreated(statistics: stats)
        case .connectionUpdated:
            let stats = MediaChannelStatistics(message: message)
            self = .connectionUpdated(statistics: stats)
        case .connectionDestroyed:
            let stats = MediaChannelStatistics(message: message)
            self = .connectionDestroyed(statistics: stats)
        }
    }
    
}
