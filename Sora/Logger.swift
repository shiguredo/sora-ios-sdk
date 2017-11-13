import Foundation

/// :nodoc:
public enum LogType {
    case sora
    case webSocketChannel
    case signalingChannel
    case peerChannel
    case nativePeerChannel
    case connectionTimer
    case mediaChannel
    case mediaStream
    case snapshot
    case cameraVideoCapturer
    case videoRenderer
    case videoView
    case user(String)
    case configurationViewController
}

/// :nodoc:
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
        case .connectionTimer:
            return "ConnectionTimer"
        case .mediaChannel:
            return "MediaChannel"
        case .mediaStream:
            return "MediaStream"
        case .snapshot:
            return "Snapshot"
        case .cameraVideoCapturer:
            return "CameraVideoCapturer"
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

/**
 ログレベルです。
 上から下に向かってログの重要度が下がり、詳細度が上がります。
 `off` はログを出力しません。
 
 6. `fatal`
 5. `error`
 4. `warn`
 3. `info`
 2. `debug`
 1. `trace`
 0. `off`
 
 */
public enum LogLevel {
    
    /// 致命的なエラー情報
    case fatal
    
    /// エラー情報
    case error
    
    /// 警告
    case warn
    
    /// 一般的な情報
    case info
    
    /// デバッグ情報
    case debug
    
    /// 最も詳細なデバッグ情報
    case trace
    
    /// ログを出力しない
    case off
    
}

/// :nodoc:
extension LogLevel {
    
    var value: Int {
        switch self {
        case .fatal:
            return 6
        case .error:
            return 5
        case .warn:
            return 4
        case .info:
            return 3
        case .debug:
            return 2
        case .trace:
            return 1
        case .off:
            return 0
        }
    }
    
}

/// :nodoc:
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
        case .off:
            return "OFF"
        }
    }
    
}

// MARK: -

/// :nodoc:
public struct Log {
    
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

/// :nodoc:
extension Log: CustomStringConvertible {
    
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    public var description: String {
        return String(format: "%@ %@ %@: %@",
                      Log.formatter.string(from: timestamp),
                      type.description,
                      level.description,
                      message)
    }
    
}

// MARK: -

/// :nodoc:
public final class Logger {
    
    public static var shared: Logger = Logger()
    
    public var onOutputHandler: ((Log) -> Void)?
    
    public static func fatal(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .fatal,
                                      type: type,
                                      message: message))
    }
    
    public static func error(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .error,
                                      type: type,
                                      message: message))
    }
    
    public static func debug(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .debug,
                                      type: type,
                                      message: message))
    }
    
    public static func warn(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .warn,
                                      type: type,
                                      message: message))
    }
    
    public static func info(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .info,
                                      type: type,
                                      message: message))
    }
    
    public static func trace(type: LogType, message: String) {
        Logger.shared.output(log: Log(level: .trace,
                                      type: type,
                                      message: message))
    }
    
    public var level: LogLevel = .info
    
    func output(log: Log) {
        if 0 < level.value && level.value <= log.level.value {
            onOutputHandler?(log)
            print(log.description)
        }
    }
    
}
