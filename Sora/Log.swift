import Foundation

public enum LogType {
    case sora
    case webSocketChannel
    case signalingChannel
    case peerChannel
    case nativePeerChannel
    case aliveMonitor
    case mediaChannel
    case mediaStream
    case snapshot
    case videoRenderer
    case videoView
    case user(String)
    case configurationViewController
}

extension LogType: CustomStringConvertible {
    
    public var description: String {
        switch self {
        case .sora:
            return "Sora"
        case .webSocketChannel:
            return "WebSocketChannel"
        case .signalingChannel:
            return "SignalingChannel"
        case .peerChannel:
            return "PeerChannel"
        case .nativePeerChannel:
            return "NativePeerChannel"
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

// MARK: -

public enum LogLevel: Int {
    case fatal
    case error
    case warn
    case info
    case debug
    case trace
}

extension LogLevel: CustomStringConvertible {
    
    public var description: String {
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

// MARK: -

public struct LogMessage {
    
    public let level: LogLevel
    public let type: LogType
    public let timestamp: Date
    public let message: String
    
    init(level: LogLevel, type: LogType, message: String) {
        self.level = level
        self.type = type
        self.timestamp = Date()
        self.message = message
    }
    
}

extension LogMessage: CustomStringConvertible {
    
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    public var description: String {
        return String(format: "%@ %@ %@: %@",
                      LogMessage.formatter.string(from: timestamp),
                      type.description,
                      level.description,
                      message)
    }
    
}

// MARK: -

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
