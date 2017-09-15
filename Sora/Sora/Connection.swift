import Foundation
import WebRTC
import SocketRocket
import UIKit

public indirect enum ConnectionError: Error {
    case failureSetConfiguration(RTCConfiguration)
    case connectionWaitTimeout
    case connectionDisconnected
    case connectionTerminated
    case connectionBusy
    case webSocketClose(Int, String?)
    case webSocketError(Error)
    case signalingFailure(reason: String)
    case peerConnectionError(Error)
    case iceConnectionFailed
    case iceConnectionDisconnected
    case mediaCapturerFailed
    case mediaStreamNotFound
    case aggregateError([ConnectionError])
    case updateError(ConnectionError)
}

public class Connection {
    
    public struct NotificationKey {
        
        public enum UserInfo: String {
            case connectionError = "Sora.Connection.UserInfo.connectionError"
            case mediaConnection = "Sora.Connection.UserInfo.mediaConnection"
        }
        
        public static var onConnect =
            Notification.Name("Sora.Connection.Notification.onConnect")
        public static var onDisconnect =
            Notification.Name("Sora.Connection.Notification.onDisconnect")
        public static var onFailure =
            Notification.Name("Sora.Connection.Notification.onFailure")
        
    }
    
    public var URL: Foundation.URL
    public var mediaChannelId: String
    public var eventLog: EventLog
    public var mediaPublisher: MediaPublisher!
    public var mediaSubscriber: MediaSubscriber!
    
    public var numberOfConnections: (Int, Int) = (0, 0) {
        willSet {
            if numberOfConnections != newValue {
                onChangeNumberOfConnectionsHandler?(newValue.0, newValue.1)
            }
        }
    }
    
    public init(URL: Foundation.URL, mediaChannelId: String) {
        self.URL = URL
        self.mediaChannelId = mediaChannelId
        eventLog = EventLog(URL: URL, mediaChannelId: mediaChannelId)
        mediaPublisher = MediaPublisher(connection: self)
        mediaSubscriber = MediaSubscriber(connection: self)
    }

    // MARK: イベントハンドラ
    
    var onChangeNumberOfConnectionsHandler: ((Int, Int) -> ())?
    
    public func onChangeNumberOfConnections(handler: @escaping (Int, Int) -> ()) {
        onChangeNumberOfConnectionsHandler = handler
    }

}
