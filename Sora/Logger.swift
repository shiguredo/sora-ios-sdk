import Foundation

/// :nodoc:
public enum LogType: Sendable {
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
  case dummyAudioDevice
}

/// :nodoc:
extension LogType: CustomStringConvertible {
  public var description: String {
    switch self {
    case .sora:
      return "Sora"
    case .webSocketChannel:
      return "WebSocketChannel"
    case .signaling:
      return "Signaling"
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
    case .dataChannel:
      return "DataChannel"
    case .dummyAudioDevice:
      return "DummyAudioDevice"
    }
  }
}

// MARK: -

/// ログレベルです。
/// 上から下に向かってログの重要度が下がり、詳細度が上がります。
/// `off` はログを出力しません。
///
/// 6. `fatal`
/// 5. `error`
/// 4. `warn`
/// 3. `info`
/// 2. `debug`
/// 1. `trace`
/// 0. `off`
public enum LogLevel: Sendable {
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
public struct Log: Sendable {
  public let level: LogLevel
  public let type: LogType
  public let timestamp: Date
  public let message: String

  init(level: LogLevel, type: LogType, timestamp: Date = Date(), message: String) {
    self.level = level
    self.type = type
    self.timestamp = timestamp
    self.message = message
  }
}

/// :nodoc:
extension Log: CustomStringConvertible {
  /// 日時整形に使う共有 formatter です。
  ///
  /// `NSDateFormatter` は SDK のヘッダで `NS_SWIFT_SENDABLE`
  /// (`All mutable state protected by locks, subclasses must be thread-safe`) が付いており、
  /// `DateFormatter` は `Sendable` として公開されています。
  /// この formatter は初期化後に `dateFormat` を変更しないため、複数の executor から同時に
  /// `string(from:)` を呼んでもかまいません。
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  public var description: String {
    String(
      format: "%@ %@ %@: %@",
      Log.formatter.string(from: timestamp),
      type.description,
      level.description,
      message)
  }
}

// MARK: -

/// 1 回のログ出力で使う設定の snapshot です。
///
/// 設定 storage の lock 区間内で値コピーを作り、lock の外ではこの値だけを使います。
/// `onOutputHandler` は利用者所有の closure であり、`@Sendable` な境界へ渡さないため、
/// この型は `Sendable` にしません。
struct LoggerSettingsSnapshot {
  let level: LogLevel
  let groups: [Logger.Group]
  let onOutputHandler: ((Log) -> Void)?
}

/// Logger の設定 (level / groups / onOutputHandler) を保持する storage です。
///
/// `@unchecked Sendable` としている根拠は次の 3 点です。
/// - `level` / `groups` / `onOutputHandler` への全アクセスが単一の `NSLock` 区間であること
/// - snapshot は lock 区間内で値コピーを作り、lock の外ではそのコピーだけを使うこと
/// - 保持する `onOutputHandler` は利用者所有の closure であり、呼び出し元 executor 上で並行に
///   呼ばれ得るため、handler 側の排他は利用者の責任であること
final class LoggerStateStorage: @unchecked Sendable {
  private let lock = NSLock()

  private var _level: LogLevel = .info
  private var _groups: [Logger.Group] = [.channels, .user]
  private var _onOutputHandler: ((Log) -> Void)?

  /// 設定を 1 回の lock 区間でまとめて取得します。
  func snapshot() -> LoggerSettingsSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return LoggerSettingsSnapshot(
      level: _level,
      groups: _groups,
      onOutputHandler: _onOutputHandler)
  }

  // level / groups は単純な値型で、旧値を lock 内で解放しても利用者コードは走りません。
  var level: LogLevel {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _level
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _level = newValue
    }
  }

  var groups: [Logger.Group] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _groups
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _groups = newValue
    }
  }

  var onOutputHandler: ((Log) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _onOutputHandler
    }
    set {
      lock.lock()
      let previous = _onOutputHandler
      _onOutputHandler = newValue
      lock.unlock()
      // 旧 closure の解放 (捕捉した object の deinit) を lock の外で行うため、
      // unlock 後も previous の寿命を伸ばします。
      withExtendedLifetime(previous) {}
    }
  }
}

/// 現在の `Logger` を保持する storage です。
///
/// `@unchecked Sendable` としている根拠は、保持する `Logger` instance への全アクセスが
/// 単一の `NSLock` 区間であることです。
/// また、stored な `static var` は `nonisolated(unsafe)` を付けない限り Swift 6 で error に
/// なるため、mutable な参照は `static let` のこの storage に閉じ込めています。
final class LoggerSharedStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var _current: Logger

  init(_ current: Logger) {
    self._current = current
  }

  var current: Logger {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _current
    }
    set {
      lock.lock()
      let previous = _current
      _current = newValue
      lock.unlock()
      // 旧 instance の解放 (LoggerStateStorage が保持する closure の deinit) を lock の外で
      // 行うため、unlock 後も previous の寿命を伸ばします。
      withExtendedLifetime(previous) {}
    }
  }
}

// MARK: -

/// :nodoc:
///
/// Logger は設定 storage への handle です。`level` / `groups` / `onOutputHandler` は instance ごとの
/// storage が保持し、全てのアクセスを `NSLock` で保護します。Logger 自身は可変状態を持たないため
/// checked な `Sendable` に準拠します。出力 handler は Logger の lock を保持せずに呼ばれます
/// (契約は `onOutputHandler` の doc を参照)。
public final class Logger: Sendable {
  public enum Group: Sendable {
    case channels
    case connectionTimer
    case videoCapturer
    case videoRenderer
    case configurationViewController
    case user
  }

  /// この instance の設定 storage です。
  private let state = LoggerStateStorage()

  /// 現在の共有 instance を保持する storage です。
  private static let sharedStorage = LoggerSharedStorage(Logger())

  /// 共有インスタンスです。
  ///
  /// - 設定 (`level` / `groups` / `onOutputHandler`) は instance ごとに保持します。差し替えると
  ///   新しい instance の設定が使われ、既定値の instance を設定した場合は既定値に戻ります。
  /// - static メソッドはこの getter を 1 回読んでから出力します。差し替えと競合した場合は、
  ///   差し替え前の instance の設定で出力され得ます。
  /// - `Logger.shared.level = ...` のような設定の書き込みは、この storage と instance の storage の
  ///   2 つの lock を跨ぎます。差し替えと競合すると、書き込んだ値が差し替え前の instance に
  ///   適用されて観測されなくなり得ます (差し替え自体は失われません)。
  public static var shared: Logger {
    get { sharedStorage.current }
    set { sharedStorage.current = newValue }
  }

  /// 出力する handler です。設定しない場合は nil です。
  ///
  /// - handler は logging を呼び出した executor 上で同期的に呼ばれます。queue への hop は行いません。
  /// - handler の中から Logger の設定を読み書きし、再度ログを出力しても deadlock しません。
  /// - handler が同じ `Log` を再出力すると無限再帰になります。再帰の防御は行わないため、
  ///   再入の制御は利用者の責任です。
  /// - handler は複数の executor から並行に呼ばれ得ます。handler 側の排他は利用者の責任です。
  public var onOutputHandler: ((Log) -> Void)? {
    get { state.onOutputHandler }
    set { state.onOutputHandler = newValue }
  }

  /// 出力するログ group です。
  /// デフォルトは `.channels` と `.user` です。
  /// 空配列を設定すると、どの group のログも出力されません。
  public var groups: [Group] {
    get { state.groups }
    set { state.groups = newValue }
  }

  public static func fatal(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .fatal,
        type: type,
        message: message))
  }

  public static func error(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .error,
        type: type,
        message: message))
  }

  public static func debug(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .debug,
        type: type,
        message: message))
  }

  public static func warn(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .warn,
        type: type,
        message: message))
  }

  public static func info(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .info,
        type: type,
        message: message))
  }

  public static func trace(type: LogType, message: String) {
    Logger.shared.output(
      log: Log(
        level: .trace,
        type: type,
        message: message))
  }

  /// ログレベルです。指定したレベルより詳細なログは出力されません。
  /// デフォルトは `info` です。
  public var level: LogLevel {
    get { state.level }
    set { state.level = newValue }
  }

  func output(log: Log) {
    // 設定は 1 回の lock 区間で snapshot として取得します。
    // filtering、secret masking、文字列整形、handler 呼び出し、print の間は Logger の lock を
    // 保持しないため、handler から Logger の設定を変更しても deadlock しません。
    let settings = state.snapshot()

    var out = false
    for group in settings.groups {
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
          .cameraVideoCapturer,
          .dummyAudioDevice:
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

    if settings.level.value > 0, settings.level.value <= log.level.value {
      let masked = Logger.maskSecrets(in: log.message)
      let maskedLog = Log(
        level: log.level, type: log.type,
        timestamp: log.timestamp, message: masked)
      settings.onOutputHandler?(maskedLog)
      print(maskedLog.description)
    }
  }

  // MARK: - シークレットマスク

  /// マスク対象のシークレットキー
  /// この文字列が含まれるキーの値はマスク対象とする
  private static let secretKeys = [
    "access_token", "token", "secret", "authorization", "credential",
  ]

  /// 事前コンパイルされた秘密情報マスク用の正規表現パターン
  ///
  /// `NSRegularExpression` は SDK のヘッダで `NS_SWIFT_SENDABLE`
  /// (`Immutable with no mutable subclasses`) が付いており、初期化後に変更しないため、
  /// lock を追加せずに複数の executor から共有します。
  private static let secretPatterns: [(key: String, regex: NSRegularExpression)] = {
    secretKeys.compactMap { key in
      let escaped = NSRegularExpression.escapedPattern(for: key)
      let pattern = "\"\(escaped)\"\\s*:\\s*\"[^\"]*\""
      let regex = try! NSRegularExpression(pattern: pattern)
      return (key, regex)
    }
  }()

  /// ログメッセージに含まれるシークレット情報をマスクする
  ///
  /// JSON 文字列内のシークレットキーに該当する値を `"***"` に置換する
  private static func maskSecrets(in message: String) -> String {
    var result = message
    for (key, regex) in secretPatterns {
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(
        in: result,
        options: [],
        range: range,
        withTemplate: "\"\(key)\": \"***\"")
    }
    return result
  }
}
