import Foundation

public enum LogType {
    case sora
    case webSocketChannel
    case signalingChannel
    case peerChannel
    case aliveMonitor
    case mediaChannel
    case mediaStream
    case snapshot
    case videoRenderer
    case videoView
    case user(String)
    case configurationViewController
    
    func description() -> String {
        switch self {
        case .sora:
            return "Sora"
        case .webSocketChannel:
            return "WebSocketChannel"
        case .signalingChannel:
            return "SignalingChannel"
        case .peerChannel:
            return "PeerChannel"
        case .aliveMonitor:
            return "AliveMonitor"
        case .mediaChannel:
            return "MediaChannel"
        case .mediaStream:
            return "MediaStream"
        case .snapshot:
            return "Snapshot"
        case .videoRenderer:
            return "VideoRenderer"
        case .videoView:
            return "VideoView"
        case .user(let name):
            return name
        case .configurationViewController:
            return "ConfigurationViewController"
        }
    }
    
}

public enum LogLevel: Int {
    case fatal
    case error
    case warn
    case info
    case debug
    case trace
    
    public func description() -> String {
        switch self {
        case .fatal:
            return "FATAL"
        case .error:
            return "ERROR"
        case .warn:
            return "WARN"
        case .info:
            return "INFO"
        case .debug:
            return "DEBUG"
        case .trace:
            return "TRACE"
        }
    }
    
}

public class Log {
    
    public static var level: LogLevel = .debug
    
    public static func debug(type: LogType, message: String) {
        Log(level: .debug, type: type, message: message).output()
    }
    
    public static func trace(type: LogType, message: String) {
        Log(level: .trace, type: type, message: message).output()
    }
    
    var level: LogLevel
    var type: LogType
    var timestamp: Date
    var message: String
    
    init(level: LogLevel, type: LogType, message: String) {
        self.level = level
        self.type = type
        self.timestamp = Date()
        self.message = message
    }
    
    func output() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let desc = String(format: "%@ %@ %@: %@",
                          formatter.string(from: timestamp),
                          type.description(),
                          level.description(),
                          message)
        print(desc)
    }
    
}
