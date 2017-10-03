import Foundation

public struct MediaChannelStatistics {
    
    public var connectionTime: Int
    public var connectionCount: Int
    public var publisherCount: Int
    public var subscriberCount: Int
    
    public init(message: SignalingNotifyMessage) {
        connectionTime = message.connectionTime
        connectionCount = message.connectionCount
        publisherCount = message.publisherCount
        subscriberCount = message.subscriberCount
    }
    
}

public enum Event {
    
    case connectionCreated(statistics: MediaChannelStatistics)
    case connectionUpdated(statistics: MediaChannelStatistics)
    case connectionDestroyed(statistics: MediaChannelStatistics)
    
    public init(message: SignalingNotifyMessage) {
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
