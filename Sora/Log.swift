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

public class LogMessage {

    public let level: LogLevel
    public let type: LogType
    public let timestamp: Date
    public let message: String

    public var description: String {
        get {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return String(format: "%@ %@ %@: %@",
                          formatter.string(from: timestamp),
                          type.description(),
                          level.description(),
                          message)
        }
    }
    
    init(level: LogLevel, type: LogType, message: String) {
        self.level = level
        self.type = type
        self.timestamp = Date()
        self.message = message
    }
    
}

public class Log {
    
    public static var shared: Log = Log()
        
    public var onOutputHandler: ((LogMessage) -> Void)?
    
    public static func fatal(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .fatal,
                                              type: type,
                                              message: message))
    }
    
    public static func error(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .error,
                                              type: type,
                                              message: message))
    }
    
    public static func debug(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .debug,
                                              type: type,
                                              message: message))
    }
    
    public static func warn(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .warn,
                                              type: type,
                                              message: message))
    }
    
    public static func info(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .info,
                                              type: type,
                                              message: message))
    }
    
    public static func trace(type: LogType, message: String) {
        Log.shared.output(message: LogMessage(level: .trace,
                                              type: type,
                                              message: message))
    }
    
    func output(message: LogMessage) {
        onOutputHandler?(message)
        print(message.description)
    }
    
}
