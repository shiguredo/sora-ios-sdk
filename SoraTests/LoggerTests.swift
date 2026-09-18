import Foundation
import XCTest

@testable import Sora

/// 並行実行した結果を集めるためのスレッド安全な collector です。
///
/// handler は複数の executor から並行に呼ばれ得るため、可変配列を直接 capture せず、
/// lock と配列をこの型に閉じ込めます。
private final class StringCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
}

/// テストごとに 1 回だけ成立する条件を扱うスレッド安全なフラグです。
///
/// handler の再入を 1 段に制限するためと、並行実行中の不正を記録するために使います。
private final class FlagBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  /// まだ設定されていなければ true を返して設定します。
  func setIfUnset() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if value {
      return false
    }
    value = true
    return true
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Logger の設定 storage と出力経路のテストです。
///
/// - handler は Logger の lock の外で呼ばれるため、handler の中から設定を変更しても deadlock しません。
/// - 1 回の出力が単一の snapshot だけを使うことは、公開 API から interleaving を制御できず決定的な
///   テストでは検出できないため、本テストでは検証せず `Sora/Logger.swift` のコードで確認します。
/// - `Logger.shared` はプロセス全体の共有状態のため、書き換えるテストは `setUp` / `tearDown` で復元します。
final class LoggerTests: XCTestCase {
  /// 復元用に保存する `Logger.shared` の状態です。
  ///
  /// Implicitly Unwrapped Optional は使わず、`SoraTests/E2ETestBase.swift` と同じく Optional で
  /// 保持します。
  private var originalShared: Logger?
  private var originalLevel: LogLevel?
  private var originalGroups: [Logger.Group]?
  private var originalOnOutputHandler: ((Log) -> Void)?

  override func setUp() {
    super.setUp()
    originalShared = Logger.shared
    originalLevel = Logger.shared.level
    originalGroups = Logger.shared.groups
    originalOnOutputHandler = Logger.shared.onOutputHandler
  }

  override func tearDown() {
    // Logger.shared はプロセス全体の共有状態です。保存した instance と設定を復元し、
    // 復元を検証してから次のテストへ進みます。
    // 保存値が無い場合は既定値へ戻します (`SoraTests/E2ETestBase.swift` と同じ形)。
    let shared = originalShared ?? Logger.shared
    let level = originalLevel ?? .info
    let groups = originalGroups ?? [Logger.Group.channels, Logger.Group.user]
    Logger.shared = shared
    Logger.shared.level = level
    Logger.shared.groups = groups
    Logger.shared.onOutputHandler = originalOnOutputHandler
    XCTAssertTrue(Logger.shared === shared, "Logger.shared の instance が復元されること")
    XCTAssertEqual(Logger.shared.level, level, "Logger.shared.level が復元されること")
    XCTAssertEqual(
      Logger.shared.groups, groups,
      "Logger.shared.groups が復元されること")
    // closure は同一性を比較できないため、nil かどうかだけで復元を確認します。
    XCTAssertEqual(
      Logger.shared.onOutputHandler == nil, originalOnOutputHandler == nil,
      "Logger.shared.onOutputHandler の nil 状態が復元されること")
    super.tearDown()
  }

  /// 新しい instance の既定値が現行と同じであることを確認します。
  func testDefaultSettings() {
    let logger = Logger()
    XCTAssertEqual(logger.level, .info, "既定の level は .info であること")
    XCTAssertEqual(
      logger.groups,
      [Logger.Group.channels, Logger.Group.user],
      "既定の groups は .channels と .user であること")
    XCTAssertNil(logger.onOutputHandler, "既定の onOutputHandler は nil であること")
  }

  /// 複数の executor から同時に出力しても、全てのログが handler に 1 回ずつ届くことを確認します。
  func testConcurrentOutputCallsHandlerForEveryLog() {
    // ここは Logger.shared を使わず、テストローカルの instance で検証します。
    let logger = Logger()
    let collector = StringCollector()
    logger.level = .debug
    logger.groups = [.channels]
    logger.onOutputHandler = { collector.append($0.message) }

    let count = 100
    DispatchQueue.concurrentPerform(iterations: count) { index in
      logger.output(log: Log(level: .debug, type: .sora, message: "message-\(index)"))
    }

    let messages = collector.snapshot()
    XCTAssertEqual(messages.count, count, "全ての出力が handler に届くこと")
    XCTAssertEqual(Set(messages).count, count, "同じ message が重複して届かないこと")
  }

  /// 設定を並行変更しても、出力が欠落しないことを確認します。
  ///
  /// 出力するログを `.fatal` にし、設定する level を「必ず通る値」だけにすることで、
  /// 期待値を設定に依存させずに「取りこぼしが無いこと」だけを検証します。
  func testConcurrentSettingsChangeDoesNotDropLogs() {
    let logger = Logger()
    let collector = StringCollector()
    logger.onOutputHandler = { collector.append($0.message) }

    let count = 100
    DispatchQueue.concurrentPerform(iterations: count) { index in
      if index.isMultiple(of: 2) {
        logger.level = .debug
        logger.groups = [.channels]
      } else {
        logger.level = .fatal
        logger.groups = [.channels, .user]
      }
      logger.output(log: Log(level: .fatal, type: .sora, message: "message-\(index)"))
    }

    XCTAssertEqual(collector.count, count, "設定を並行変更しても全ての出力が handler に届くこと")
    XCTAssertEqual(
      Set(collector.snapshot()), Set((0..<count).map { "message-\($0)" }),
      "同じ message が重複して届かず、欠落もしないこと")
  }

  /// handler の中から設定を変更し、再度ログを出力しても deadlock しないことを確認します。
  ///
  /// handler は Logger の lock の外で呼ばれるため、handler の中から同じ instance の設定の
  /// 読み書きと再出力ができます。lock を保持したまま handler を呼ぶ実装へ退行した場合は、
  /// 出力側の専用 queue が停止して expectation が timeout するためテストは失敗します
  /// (テストスレッドは expectation を待つだけなので、テスト実行全体は停止しません)。
  func testHandlerCanChangeSettingsAndLogAgain() {
    let logger = Logger()
    let localCollector = StringCollector()
    let sharedCollector = StringCollector()
    let didReenter = FlagBox()
    let reentrancyCompleted = expectation(description: "handler の再入が完了すること")

    logger.level = .debug
    logger.groups = [.channels]
    logger.onOutputHandler = { log in
      localCollector.append(log.message)
      // 同じ Log を再出力すると無限再帰になるため、再入は 1 段に制限します。
      guard didReenter.setIfUnset() else {
        return
      }

      // 同じ instance の設定を読み書きしてから再出力します。
      logger.level = .debug
      logger.groups = [.channels]
      logger.onOutputHandler = { inner in localCollector.append(inner.message) }
      // handler の中から読んでも、書き込んだ値が読み出せることを確認します。
      XCTAssertEqual(logger.level, .debug, "handler の中から読んだ level が書き込んだ値であること")
      XCTAssertEqual(logger.groups, [.channels], "handler の中から読んだ groups が書き込んだ値であること")
      XCTAssertNotNil(logger.onOutputHandler, "handler の中から読んだ onOutputHandler が非 nil であること")
      logger.output(log: Log(level: .debug, type: .sora, message: "reentrant local"))

      // Logger.info の到達は Logger.shared の設定で決まるため、呼ぶ直前に出力が通る値へ戻します。
      Logger.shared.level = .debug
      Logger.shared.groups = [.channels]
      Logger.shared.onOutputHandler = { sharedLog in sharedCollector.append(sharedLog.message) }
      XCTAssertEqual(
        Logger.shared.level, .debug, "handler の中から読んだ Logger.shared.level が書き込んだ値であること")
      XCTAssertNotNil(
        Logger.shared.onOutputHandler, "handler の中から読んだ Logger.shared.onOutputHandler が非 nil であること")
      Logger.info(type: .sora, message: "reentrant shared")
      Logger.shared.onOutputHandler = nil

      // 公開 API からの読み書きでも deadlock しません。
      XCTAssertEqual(Sora.logLevel, .debug, "handler の中から読んだ Sora.logLevel が書き込んだ値であること")
      Sora.logLevel = .debug

      // 再入が戻ってから fulfillment します (先に fulfillment すると、退行時に
      // 成功したように見えてしまいます)。
      reentrancyCompleted.fulfill()
    }

    // 出力は専用 queue から行い、テストスレッドは expectation を待つだけにします。
    let queue = DispatchQueue(label: "jp.shiguredo.sora.tests.logger.reentrancy")
    queue.async {
      logger.output(log: Log(level: .debug, type: .sora, message: "origin"))
    }

    // lock を保持したまま handler を呼ぶ実装へ退行した場合は専用 queue が停止するため、
    // timeout したら後続の検証を行わずにテストを終了します (停止した queue は待ちません)。
    guard XCTWaiter.wait(for: [reentrancyCompleted], timeout: 5) == .completed else {
      XCTFail("handler の再入が lock の外で完了すること")
      return
    }
    XCTAssertEqual(localCollector.snapshot(), ["origin", "reentrant local"], "再入した出力も記録されること")
    XCTAssertEqual(sharedCollector.snapshot(), ["reentrant shared"], "公開経路からの出力も記録されること")
  }

  /// handler が Logger の lock の外で呼ばれることを確認します。
  ///
  /// 1 回目の handler は同じスレッドで `level` を変更します。この setter は storage の lock を
  /// 取るため、lock を保持したまま handler を呼ぶ実装ではここで停止します。テストスレッドは
  /// handler の完了を待つだけで、その間に Logger の lock を取得しないため、退行時は timeout で
  /// 失敗します (停止した専用 queue は待ちません)。
  func testHandlerIsCalledOutsideLock() {
    let logger = Logger()
    let collector = StringCollector()
    let handlerCalled = expectation(description: "1 回目の handler が呼ばれること")
    let secondOutputCompleted = expectation(description: "2 回目の出力が完了すること")
    let queue = DispatchQueue(label: "jp.shiguredo.sora.tests.logger.snapshot")

    logger.level = .debug
    logger.groups = [.channels]
    logger.onOutputHandler = { log in
      collector.append(log.message)
      logger.level = .off
      handlerCalled.fulfill()
    }

    queue.async {
      logger.output(log: Log(level: .debug, type: .sora, message: "first"))
    }
    guard XCTWaiter.wait(for: [handlerCalled], timeout: 5) == .completed else {
      XCTFail("handler が lock の外で呼ばれること (lock 保持中に呼ぶ実装では停止します)")
      return
    }

    // 2 回目の出力は level = .off のため handler には到達しません。
    // 完了は出力側の block で fulfill します (`queue.sync {}` のような timeout の無い待機は使いません)。
    queue.async {
      logger.output(log: Log(level: .debug, type: .sora, message: "second"))
      secondOutputCompleted.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [secondOutputCompleted], timeout: 5), .completed,
      "2 回目の出力が完了すること")
    XCTAssertEqual(collector.snapshot(), ["first"], "level = .off の後の出力は handler に届かないこと")
  }

  /// `Logger.shared` の差し替え後に、新しい instance の設定が使われることを確認します。
  func testSharedReplacementUsesNewInstanceSettings() {
    let collectorA = StringCollector()
    let collectorB = StringCollector()
    let loggerA = Logger()
    loggerA.level = .debug
    loggerA.groups = [.channels]
    loggerA.onOutputHandler = { collectorA.append($0.message) }
    let loggerB = Logger()
    loggerB.level = .debug
    // groups を A と変えて、差し替え後に B の groups が使われることも検証できるようにします。
    loggerB.groups = [.user]
    loggerB.onOutputHandler = { collectorB.append($0.message) }

    Logger.shared = loggerA
    XCTAssertTrue(Logger.shared === loggerA, "設定した instance が共有されること")
    XCTAssertEqual(Logger.shared.level, .debug, "新しい instance の level が使われること")
    XCTAssertEqual(Logger.shared.groups, [Logger.Group.channels], "新しい instance の groups が使われること")
    Logger.info(type: .sora, message: "for A")
    XCTAssertEqual(collectorA.snapshot(), ["for A"], "差し替え後の出力が新しい instance の handler に届くこと")
    XCTAssertEqual(collectorB.count, 0, "共有していない instance の handler には届かないこと")

    Logger.shared = loggerB
    XCTAssertTrue(Logger.shared === loggerB, "2 回目の差し替えが共有されること")
    XCTAssertEqual(Logger.shared.groups, [Logger.Group.user], "差し替え後の groups が使われること")
    // B の groups は `.user` だけのため、`.sora` のログは B の handler に届きません。
    // 旧 instance (A) の groups を読む実装へ退行すると、ここで B に届いて失敗します。
    Logger.info(type: .sora, message: "not for B")
    XCTAssertEqual(collectorB.count, 0, "差し替え後の instance の groups では `.sora` が出力されないこと")
    // B の groups に含まれる `.user` のログは B の handler に届きます。
    Logger.info(type: .user("test"), message: "for B")
    XCTAssertEqual(collectorB.snapshot(), ["for B"], "2 回目の差し替えも反映されること")
    XCTAssertEqual(collectorA.count, 1, "差し替え前の instance の handler は使われないこと")
  }

  /// `Logger.shared` の差し替えと出力を競合させても、出力が欠落しないことを確認します。
  func testConcurrentSharedReplacementAndOutput() {
    let collectorA = StringCollector()
    let collectorB = StringCollector()
    let loggerA = Logger()
    loggerA.level = .debug
    loggerA.groups = [.channels]
    loggerA.onOutputHandler = { collectorA.append($0.message) }
    let loggerB = Logger()
    loggerB.level = .debug
    loggerB.groups = [.channels]
    loggerB.onOutputHandler = { collectorB.append($0.message) }

    // 開始前にどちらかを設定しておき、getter が常にこの 2 つのいずれかを返すようにします。
    Logger.shared = loggerA
    let sawUnknownInstance = FlagBox()

    let count = 100
    DispatchQueue.concurrentPerform(iterations: count) { index in
      if index.isMultiple(of: 2) {
        Logger.shared = loggerA
      } else {
        Logger.shared = loggerB
      }
      let current = Logger.shared
      if current !== loggerA && current !== loggerB {
        sawUnknownInstance.set()
      }
      Logger.info(type: .sora, message: "message-\(index)")
    }

    XCTAssertFalse(sawUnknownInstance.isSet, "getter が設定済みの instance のいずれかを返すこと")
    let messages = collectorA.snapshot() + collectorB.snapshot()
    XCTAssertEqual(messages.count, count, "全ての出力がどちらかの handler に届くこと")
    XCTAssertEqual(
      Set(messages), Set((0..<count).map { "message-\($0)" }),
      "同じ message が重複して届かず、欠落もしないこと")
  }

  /// groups と level による filtering の結果が実装前と同じであることを確認します。
  func testFilteringUnchanged() {
    let logger = Logger()
    let collector = StringCollector()
    logger.onOutputHandler = { collector.append($0.message) }

    logger.level = .info
    logger.groups = [.channels]
    logger.output(log: Log(level: .debug, type: .sora, message: "debug"))
    XCTAssertEqual(collector.count, 0, "level より詳細なログは出力されないこと")

    logger.output(log: Log(level: .info, type: .sora, message: "info"))
    XCTAssertEqual(collector.count, 1, "level と同じログは出力されること")

    logger.groups = [.user]
    logger.output(log: Log(level: .info, type: .sora, message: "not in groups"))
    XCTAssertEqual(collector.count, 1, "groups に含まれない type は出力されないこと")

    logger.groups = [.channels, .user]
    logger.output(log: Log(level: .info, type: .user("test"), message: "user"))
    XCTAssertEqual(collector.count, 2, "groups に含まれる type は出力されること")

    logger.level = .off
    logger.output(log: Log(level: .fatal, type: .sora, message: "off"))
    XCTAssertEqual(collector.count, 2, "level = .off では出力されないこと")

    // groups が空配列のときは、level に関係なくどの group のログも出力されません。
    logger.level = .debug
    logger.groups = []
    logger.output(log: Log(level: .fatal, type: .sora, message: "empty groups"))
    XCTAssertEqual(collector.count, 2, "groups が空配列では出力されないこと")
  }

  /// secret masking と `Log.description` の出力形式が実装前と同じであることを確認します。
  func testMaskingAndOutputFormatUnchanged() {
    let logger = Logger()
    let collector = StringCollector()
    logger.level = .debug
    logger.groups = [.channels]
    logger.onOutputHandler = { collector.append($0.message) }

    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    // `Sora/Logger.swift` の `secretKeys` にあるキーを全て含む入力を渡し、値が全てマスクされることを
    // 確認します (キーを追加した場合は、このテストの対象へ含めるかをそのとき判断します)。
    logger.output(
      log: Log(
        level: .info, type: .sora, timestamp: timestamp,
        message:
          "{\"access_token\": \"v1\", \"token\": \"v2\", \"secret\": \"v3\", \"authorization\": \"v4\", \"credential\": \"v5\", \"other\": 1}"
      ))

    XCTAssertEqual(
      collector.snapshot(),
      [
        "{\"access_token\": \"***\", \"token\": \"***\", \"secret\": \"***\", \"authorization\": \"***\", \"credential\": \"***\", \"other\": 1}"
      ],
      "対象キー 5 件の値が全てマスクされること")

    // Log.description の期待値は、共有 formatter と同じ dateFormat と locale / timeZone を使う
    // テストローカルの formatter で組み立てます (共有 formatter は locale / timeZone を既定値のまま使います)。
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    let log = Log(level: .info, type: .sora, timestamp: timestamp, message: "message")
    XCTAssertEqual(
      log.description,
      "\(formatter.string(from: timestamp)) Sora INFO: message",
      "Log.description の出力形式が変わらないこと")
  }

  /// 複数のスレッドから `Log.description` を呼んでも、同じ入力からは同じ文字列が得られることを確認します。
  ///
  /// `Log` は `Sendable` な公開値型であり、利用者が handler 経由で受け取った `Log` を任意の
  /// executor で文字列化できます (共有 `DateFormatter` は初期化後に変更しません)。
  func testConcurrentLogDescription() {
    let log = Log(
      level: .info, type: .sora, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      message: "message")
    let collector = StringCollector()

    let count = 100
    DispatchQueue.concurrentPerform(iterations: count) { _ in
      collector.append(log.description)
    }

    let values = collector.snapshot()
    XCTAssertEqual(values.count, count, "全ての description が得られること")
    XCTAssertEqual(Set(values).count, 1, "同じ入力からは同じ文字列が得られること")
  }
}
