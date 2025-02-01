import Foundation

/// :nodoc:
public enum LogType {
    case sora
    case webSocketChannel
    case signaling
    case signalingChannel
    case peerChannel
    case nativePeerChannel
    case connectionTimer
    case mediaChannel
    case mediaStream
    case cameraVideoCapturer
    case videoRenderer
    case videoView
    case user(String)
    case configurationViewController
    case dataChannel
}

/// :nodoc:
extension LogType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sora:
            "Sora"
        case .webSocketChannel:
            "WebSocketChannel"
        case .signaling:
            "Signaling"
        case .signalingChannel:
            "SignalingChannel"
        case .peerChannel:
            "PeerChannel"
        case .nativePeerChannel:
            "NativePeerChannel"
        case .connectionTimer:
            "ConnectionTimer"
        case .mediaChannel:
            "MediaChannel"
        case .mediaStream:
            "MediaStream"
        case .cameraVideoCapturer:
            "CameraVideoCapturer"
        case .videoRenderer:
            "VideoRenderer"
        case .videoView:
            "VideoView"
        case let .user(name):
            name
        case .configurationViewController:
            "ConfigurationViewController"
        case .dataChannel:
            "DataChannel"
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
            6
        case .error:
            5
        case .warn:
            4
        case .info:
            3
        case .debug:
            2
        case .trace:
            1
        case .off:
            0
        }
    }
}

/// :nodoc:
extension LogLevel: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fatal:
            "FATAL"
        case .error:
            "ERROR"
        case .warn:
            "WARN"
        case .info:
            "INFO"
        case .debug:
            "DEBUG"
        case .trace:
            "TRACE"
        case .off:
            "OFF"
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
        timestamp = Date()
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
        String(format: "%@ %@ %@: %@",
               Log.formatter.string(from: timestamp),
               type.description,
               level.description,
               message)
    }
}

// MARK: -

/// :nodoc:
public final class Logger {
    public enum Group {
        case channels
        case connectionTimer
        case videoCapturer
        case videoRenderer
        case configurationViewController
        case user
    }

    public static var shared = Logger()

    public var onOutputHandler: ((Log) -> Void)?

    public var groups: [Group] = [.channels, .user]

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
        var out = false
        for group in groups {
            switch group {
            case .channels:
                switch log.type {
                case .sora,
                     .webSocketChannel,
                     .signalingChannel,
                     .peerChannel,
                     .nativePeerChannel,
                     .mediaChannel,
                     .mediaStream,
                     .dataChannel,
                     .cameraVideoCapturer:
                    out = true
                default:
                    break
                }
            case .connectionTimer:
                switch log.type {
                case .connectionTimer:
                    out = true
                default:
                    break
                }
            case .videoCapturer:
                switch log.type {
                case .cameraVideoCapturer:
                    out = true
                default:
                    break
                }
            case .videoRenderer:
                switch log.type {
                case .videoRenderer, .videoView:
                    out = true
                default:
                    break
                }
            case .user:
                switch log.type {
                case .user:
                    out = true
                default:
                    break
                }
            case .configurationViewController:
                switch log.type {
                case .configurationViewController:
                    out = true
                default:
                    break
                }
            }
        }
        if !out { return }

        if level.value > 0, level.value <= log.level.value {
            onOutputHandler?(log)
            print(log.description)
        }
    }
}
