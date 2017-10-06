import Foundation

public struct MediaChannelStatistics {
    
    public let connectionTime: Int
    public let connectionCount: Int
    public let publisherCount: Int
    public let subscriberCount: Int
    
    init(message: SignalingNotifyMessage) {
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
