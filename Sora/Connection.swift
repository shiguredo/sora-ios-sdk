import Foundation
import WebRTC
import SocketRocket
import UIKit
import Unbox

public indirect enum ConnectionError: Error {
    case invalidProtocol
    case failureSetConfiguration(RTCConfiguration)
    case connectionWaitTimeout
    case connectionDisconnected
    case connectionTerminated
    case connectionBusy
    case connectionCancelled
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
    
    public var description: String {
        get {
            switch self {
            case .invalidProtocol:
                return "protocol must be \"ws\" or \"wss\""
            case .failureSetConfiguration(_):
                return "setting configuration failed"
            case .connectionWaitTimeout:
                return "connection timeout"
            case .connectionDisconnected:
                return "connection disconnected"
            case .connectionTerminated:
                return "connection terminated"
            case .connectionBusy:
                return "connection busy"
            case .connectionCancelled:
                return "connection cancelled"
            case .webSocketClose(let code, let reason):
                return String(format: "WebSocket closed %d (%@)",
                              code, reason ?? "unknown reason")
            case .webSocketError(let error):
                return String(format: "WebSocket error (%@)",
                              error.localizedDescription)
            case .signalingFailure(reason: let reason):
                return String(format: "signaling failed (%@)", reason)
            case .peerConnectionError(let error):
                return String(format: "peer connection error (%@)",
                              error.localizedDescription)
            case .iceConnectionFailed:
                return "ICE connection failed"
            case .iceConnectionDisconnected:
                return "ICE connection disconnected"
            case .mediaCapturerFailed:
                return "media capturer initialization failed"
            case .mediaStreamNotFound:
                return "media stream not found"
            case .updateError(let error):
                return String(format: "signaling update error (%@)",
                              error.description)
            case .aggregateError(let errors):
                var buf = "aggregate error ("
                buf.append(errors.map { err in return err.description }
                    .joined(separator: "; "))
                buf.append(")")
                return buf
            }
        }
    }
    
}

public enum Role: String, UnboxableEnum {
    case publisher
    case subscriber
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
    
    public init(URL: Foundation.URL, mediaChannelId: String) {
        self.URL = URL
        self.mediaChannelId = mediaChannelId
        eventLog = EventLog(URL: URL, mediaChannelId: mediaChannelId)
        mediaPublisher = MediaPublisher(connection: self)
        mediaSubscriber = MediaSubscriber(connection: self)
    }

}
