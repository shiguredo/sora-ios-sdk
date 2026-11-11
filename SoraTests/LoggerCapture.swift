import Foundation

@testable import Sora

/// テスト中だけ `Logger.shared` の設定 (level / groups / onOutputHandler) を変更し、
/// 出力されたログの message と `Log` を集めるヘルパーです。
///
/// `Logger.shared` はプロセス全体の共有状態のため、この型のインスタンスが解放される
/// (`deinit`) ときに元の設定へ戻します。テストが失敗して早期に return しても復元されます。
/// 復元の時期はインスタンスの寿命に依存するため、テストメソッドのローカル変数として保持し、
/// クラスのプロパティには保持しないでください。`Logger.shared` を書き換えるテストは直列に
/// 実行する前提です。
/// handler は複数の executor から呼ばれ得るため、収集は `LogCollector` の lock で行います。
/// handler に渡る `Log` は `Logger.output(log:)` がマスクした後の値である点に注意してください。
final class LoggerCapture {
  /// 出力されたログ
  private let logCollector = LogCollector()

  /// ログが 1 件出力されるたびに呼ばれるクロージャー
  private let onMessage: ((String) -> Void)?

  private let originalLevel: LogLevel
  private let originalGroups: [Logger.Group]
  private let originalOnOutputHandler: ((Log) -> Void)?

  /// ログの収集を開始します。
  init(
    level: LogLevel = .debug,
    groups: [Logger.Group] = [.channels],
    onMessage: ((String) -> Void)? = nil
  ) {
    self.onMessage = onMessage
    // 設定は 1 回取得した `Logger.shared` から読みます。`restore()` はその時点の
    // `Logger.shared` へ戻すため、実行中に `Logger.shared` が差し替えられると復元先が
    // 変わります。このヘルパーは直列実行前提です。
    let shared = Logger.shared
    originalLevel = shared.level
    originalGroups = shared.groups
    originalOnOutputHandler = shared.onOutputHandler
    shared.level = level
    shared.groups = groups
    shared.onOutputHandler = { [logCollector, onMessage] log in
      logCollector.append(log)
      onMessage?(log.message)
    }
  }

  /// 設定を元に戻します。
  ///
  /// 通常は `deinit` から呼ばれます。2 回呼んでも同じ値を設定するだけなので安全です。
  func restore() {
    Logger.shared.onOutputHandler = originalOnOutputHandler
    Logger.shared.level = originalLevel
    Logger.shared.groups = originalGroups
  }

  deinit {
    restore()
  }

  /// 収集したログの message の一覧
  var messages: [String] {
    logs.map(\.message)
  }

  /// 収集したログの一覧
  var logs: [Log] {
    logCollector.snapshot()
  }
}

/// 出力された `Log` を集めるためのスレッド安全な collector です。
///
/// handler が複数の executor から並行に呼ばれ得るため、lock と配列をこの型に閉じ込めます。
private final class LogCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Log] = []

  func append(_ log: Log) {
    lock.lock()
    defer { lock.unlock() }
    values.append(log)
  }

  func snapshot() -> [Log] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
