import Foundation

@testable import Sora

/// テスト中だけ `Logger.shared` の設定 (level / groups / onOutputHandler) を変更し、
/// 出力されたログの message を集めるヘルパーです。
///
/// `Logger.shared` はプロセス全体の共有状態のため、この型のインスタンスが解放される
/// (`deinit`) ときに元の設定へ戻します。テストが失敗して早期に return しても復元されます。
/// 復元の時期はインスタンスの寿命に依存するため、テストメソッドのローカル変数として保持し、
/// クラスのプロパティには保持しないでください。`Logger.shared` を書き換えるテストは直列に
/// 実行する前提です。
/// handler は複数の executor から呼ばれ得るため、収集は `StringCollector` の lock で行います。
final class LoggerCapture {
  /// 出力されたログの message
  private let collector = StringCollector()

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
    shared.onOutputHandler = { [collector, onMessage] log in
      collector.append(log.message)
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
    collector.snapshot()
  }
}
