import XCTest

@testable import Sora

/// `LogType` は `Equatable` ではないため、対象のログ種別を `case` で判定する accessor です。
extension LogType {
  var isSora: Bool {
    if case .sora = self {
      return true
    }
    return false
  }

  var isMediaChannel: Bool {
    if case .mediaChannel = self {
      return true
    }
    return false
  }

  var isConnectionTimer: Bool {
    if case .connectionTimer = self {
      return true
    }
    return false
  }
}

/// `Logger.shared` の出力 handler が受け取ったログの記録です。
///
/// handler は複数のスレッドから呼ばれるため、lock で保護します
/// (`SoraTests/CameraStateOwnerTests.swift` の collector と同じ形)。
final class LoggerCallUnderLockLogCollector {
  private let lock = NSLock()
  private var _logs: [Log] = []

  func append(_ log: Log) {
    lock.lock()
    _logs.append(log)
    lock.unlock()
  }

  var logs: [Log] {
    lock.lock()
    defer { lock.unlock() }
    return _logs
  }

  /// 条件に一致する最初のログを返します。
  func firstLog(where predicate: (Log) -> Bool) -> Log? {
    logs.first(where: predicate)
  }

  /// 条件に一致するログの数を返します。
  func count(where predicate: (Log) -> Bool) -> Int {
    logs.filter(predicate).count
  }

  /// 条件に一致するログのメッセージを出現順に返します。
  func messages(where predicate: (Log) -> Bool) -> [String] {
    logs.filter(predicate).map(\.message)
  }
}

/// 出力 handler の再入を 1 段に制限するフラグです。
///
/// 制限が無いと、修正後は再入が無限に続きます。handler は複数のスレッドから呼ばれるため
/// lock で保護します。
final class LoggerCallUnderLockReentrancyLimiter {
  private let lock = NSLock()
  private var used = false

  /// まだ使っていなければ `true` を返して使用済みにします (2 回目以降は `false`)。
  func consume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if used {
      return false
    }
    used = true
    return true
  }
}

/// 非 Sendable な `MediaChannel` を `@Sendable` closure へ capture せずに入口呼び出しへ渡す box です。
///
/// `MediaChannel` は Sendable ではないため、`DispatchQueue.async` の closure が直接 capture すると
/// `SoraTests` の concurrency 診断 (`0118` で 0 件) が退行します。box は immutable な参照を
/// 保持するだけで、SDK の API はテストが用意した queue から直列に呼び出します。
private final class MediaChannelEntryBox: @unchecked Sendable {
  private let channel: MediaChannel

  init(_ channel: MediaChannel) {
    self.channel = channel
  }

  func add(to sora: Sora) {
    sora.add(mediaChannel: channel)
  }

  func remove(from sora: Sora) {
    sora.remove(mediaChannel: channel)
  }

  /// 接続を開始し、接続試行の `ConnectionTask` を返します (テストスレッドから呼びます)。
  @discardableResult
  func connect() -> ConnectionTask {
    channel.connect(webRTCConfiguration: WebRTCConfiguration()) { _ in }
  }

  func disconnect() {
    channel.disconnect(error: nil)
  }
}

/// 非 Sendable な `ConnectionTask` を `@Sendable` closure へ capture せずに渡す box です
/// (`MediaChannelEntryBox` と同じ理由)。
private final class ConnectionTaskEntryBox: @unchecked Sendable {
  private let task: ConnectionTask

  init(_ task: ConnectionTask) {
    self.task = task
  }

  func cancel() {
    task.cancel()
  }
}

/// SDK 内部の排他区間を保持したまま Logger を呼ぶと利用者の出力 handler が deadlock する問題の回帰テスト
///
/// `Logger.shared.onOutputHandler` に実 handler を設定し、handler から同じ lock / serial queue を使う
/// SDK の API を呼ぶ経路を作ります。deadlock を起こす入口の SDK 呼び出しはすべて専用 queue から実行し、
/// テストスレッドは expectation を待つだけにします (テストスレッドで同期実行すると、退行時に
/// `wait(for:timeout:)` に到達する前に停止してテスト実行全体がハングします)。
///
/// 対象ログの到達は expectation で確認し、`level` / `type` / `message` と経路ごとの相対順序は
/// collector に記録した `Log` で確認します。
///
/// `Logger.shared` と `Sora.shared` はプロセス全体の共有状態のため、このクラスのテストは直列実行を前提とします。
final class LoggerCallUnderLockTests: XCTestCase {
  /// 復元用に保存する `Logger.shared` の状態です。
  private var originalLevel: LogLevel?
  private var originalGroups: [Logger.Group]?
  private var originalOnOutputHandler: ((Log) -> Void)?

  /// 後始末で MediaChannel を `remove` する対象です (`add` した instance と揃える)。
  private var addedSora: Sora?
  private var addedMediaChannel: MediaChannel?

  /// deadlock で停止した経路がある場合は `true` になり、後始末で SDK の状態を触りません
  /// (停止した lock を待たないため)。
  private var hasStuckPath = false

  private static let timeout: TimeInterval = 5

  override func setUp() {
    super.setUp()
    // handler から `Sora.shared` を最初に読むと遅延初期化が再帰するため、先に初期化しておく。
    _ = Sora.shared
    originalLevel = Logger.shared.level
    originalGroups = Logger.shared.groups
    originalOnOutputHandler = Logger.shared.onOutputHandler
  }

  override func tearDown() {
    // `remove` 自身が `Logger.debug` を出すため、handler を戻す前に `remove` すると handler が再度走る。
    // まず handler を戻し、その後に追加した MediaChannel を片付ける。
    Logger.shared.onOutputHandler = originalOnOutputHandler
    if let level = originalLevel {
      Logger.shared.level = level
    }
    if let groups = originalGroups {
      Logger.shared.groups = groups
    }
    if !hasStuckPath, let sora = addedSora, let channel = addedMediaChannel {
      sora.remove(mediaChannel: channel)
      XCTAssertFalse(sora.mediaChannels.contains(channel), "追加した MediaChannel が remove されること")
    }
    addedSora = nil
    addedMediaChannel = nil
    hasStuckPath = false
    super.tearDown()
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "logger-call-under-lock",
      role: .sendrecv)
  }

  // テスト用の MediaChannel を構築する
  private func makeMediaChannel() throws -> MediaChannel {
    try MediaChannel(configuration: makeConfiguration())
  }

  /// 入口の SDK 呼び出しを専用 queue から実行し、handler からの 1 段の再入を待ちます。
  ///
  /// 入口呼び出しと再入呼び出しは同じ `Logger.shared` の handler を通るため、対象ログの判定は
  /// `type` と `message` の両方で行います (`changed state from ...` は `SignalingChannel` も
  /// 同じ文言で出すため、message だけでは区別できません)。
  ///
  /// - returns: handler が受け取ったログの collector
  private func runEntry(
    label: String,
    target: @escaping (Log) -> Bool,
    reenter: @escaping () -> Void,
    entry: @escaping @Sendable () -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> LoggerCallUnderLockLogCollector {
    let collector = LoggerCallUnderLockLogCollector()
    let limiter = LoggerCallUnderLockReentrancyLimiter()
    let reentered = expectation(description: "handler から SDK の API を呼ぶ")
    Logger.shared.onOutputHandler = { log in
      collector.append(log)
      guard target(log) else {
        return
      }
      guard limiter.consume() else {
        return
      }
      reenter()
      reentered.fulfill()
    }

    DispatchQueue(label: "jp.shiguredo.sora.tests.loggerCallUnderLock.\(label)").async(
      execute: entry)

    let result = XCTWaiter.wait(for: [reentered], timeout: Self.timeout)
    if result == .timedOut {
      hasStuckPath = true
    }
    XCTAssertEqual(
      result, .completed,
      "handler からの再入が \(Self.timeout) 秒以内に戻ること (deadlock の疑い)",
      file: file, line: line)
    return collector
  }

  /// 対象ログの `level` / `type` / `message` を確認します。
  private func assertLog(
    _ log: Log?,
    level: LogLevel,
    type: (LogType) -> Bool,
    typeName: String,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertNotNil(log, "対象ログを handler が受け取ること", file: file, line: line)
    XCTAssertEqual(log?.level, level, "対象ログの level", file: file, line: line)
    XCTAssertEqual(
      log.map { type($0.type) }, true, "対象ログの type (\(typeName))", file: file, line: line)
    XCTAssertEqual(log?.message, message, "対象ログの message", file: file, line: line)
  }

  /// `Sora.add(mediaChannel:)` のログ出力中に handler から `mediaChannels` を読んでも deadlock しない
  ///
  /// handler が読む instance と `add` する instance をそろえます (`mediaChannelLock` は instance ごと)。
  func testAddMediaChannelFromOutputHandlerDoesNotDeadlock() throws {
    let sora = Sora()
    let channel = try makeMediaChannel()
    addedSora = sora
    addedMediaChannel = channel
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let readerQueue = DispatchQueue(label: "jp.shiguredo.sora.tests.loggerCallUnderLock.add.reader")
    let box = MediaChannelEntryBox(channel)
    let collector = runEntry(
      label: "add.entry",
      target: { $0.type.isSora && $0.message == "add media channel" },
      reenter: { readerQueue.sync { _ = sora.mediaChannels } },
      entry: { box.add(to: sora) })

    assertLog(
      collector.firstLog { $0.message == "add media channel" },
      level: .debug, type: { $0.isSora }, typeName: "sora", message: "add media channel")
  }

  /// `Sora.remove(mediaChannel:)` のログ出力中に handler から `mediaChannels` を読んでも deadlock しない
  func testRemoveMediaChannelFromOutputHandlerDoesNotDeadlock() throws {
    let sora = Sora()
    let channel = try makeMediaChannel()
    addedSora = sora
    addedMediaChannel = channel
    sora.add(mediaChannel: channel)
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.remove.reader")
    let box = MediaChannelEntryBox(channel)
    let collector = runEntry(
      label: "remove.entry",
      target: { $0.type.isSora && $0.message == "remove media channel" },
      reenter: { readerQueue.sync { _ = sora.mediaChannels } },
      entry: { box.remove(from: sora) })

    assertLog(
      collector.firstLog { $0.message == "remove media channel" },
      level: .debug, type: { $0.isSora }, typeName: "sora", message: "remove media channel")
  }

  /// `ConnectionTask.cancel()` のログ出力中に handler から `state` を読んでも deadlock しない
  func testCancelConnectionTaskFromOutputHandlerDoesNotDeadlock() {
    let task = ConnectionTask()
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.cancel.reader")
    let box = ConnectionTaskEntryBox(task)
    let collector = runEntry(
      label: "cancel.entry",
      target: { $0.type.isMediaChannel && $0.message == "connection task cancelled" },
      reenter: { readerQueue.sync { _ = task.state } },
      entry: { box.cancel() })

    assertLog(
      collector.firstLog { $0.message == "connection task cancelled" },
      level: .debug, type: { $0.isMediaChannel }, typeName: "mediaChannel",
      message: "connection task cancelled")
  }

  /// 接続試行中の `MediaChannel.disconnect(error:)` のログ出力中に handler から同じ API を呼んでも deadlock しない
  ///
  /// `connection task completed` が出るのは `connecting` からの遷移だけであるため、
  /// 接続試行中 (`state == .connecting`) に別 queue から `disconnect` を呼びます。
  func testDisconnectMediaChannelFromOutputHandlerDoesNotDeadlock() throws {
    let channel = try makeMediaChannel()
    addedMediaChannel = channel
    let box = MediaChannelEntryBox(channel)
    box.connect()
    XCTAssertEqual(channel.state, .connecting, "接続試行中の state であること")

    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.disconnect.reader")
    let collector = runEntry(
      label: "disconnect.entry",
      target: { $0.type.isMediaChannel && $0.message == "connection task completed" },
      reenter: { readerQueue.sync { box.disconnect() } },
      entry: { box.disconnect() })

    assertLog(
      collector.firstLog { $0.message == "connection task completed" },
      level: .debug, type: { $0.isMediaChannel }, typeName: "mediaChannel",
      message: "connection task completed")
    XCTAssertEqual(
      collector.count { $0.message == "connection task completed" }, 1,
      "完了ログは遷移した 1 回だけ出ること")
  }

  /// `MediaChannel.connect` から `ConnectionTimer.run` に到達したログ出力中に handler から `disconnect` を呼んでも deadlock しない
  func testMediaChannelTimerStartFromOutputHandlerDoesNotDeadlock() throws {
    let channel = try makeMediaChannel()
    addedMediaChannel = channel

    Logger.shared.level = .debug
    Logger.shared.groups = [.channels, .connectionTimer]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.timer.reader")
    let box = MediaChannelEntryBox(channel)
    let collector = runEntry(
      label: "timer.entry",
      target: { $0.type.isConnectionTimer && $0.message.hasPrefix("run (timeout:") },
      reenter: { readerQueue.sync { box.disconnect() } },
      entry: { box.connect() })

    let log = collector.firstLog {
      $0.type.isConnectionTimer && $0.message.hasPrefix("run (timeout:")
    }
    XCTAssertNotNil(log, "Timer 開始ログを handler が受け取ること")
    XCTAssertEqual(log?.level, .debug, "Timer 開始ログの level")
    XCTAssertEqual(log?.type.isConnectionTimer, true, "Timer 開始ログの type")
    XCTAssertEqual(log?.message.hasPrefix("run (timeout:"), true, "Timer 開始ログの message")
  }

  /// `MediaChannel.state` の遷移ログ出力中に handler から `disconnect` を呼んでも deadlock しない
  ///
  /// 遷移ログは `SignalingChannel` も同じ文言で出すため、判定は `type` で限定します。
  func testMediaChannelStateTransitionFromOutputHandlerDoesNotDeadlock() throws {
    let channel = try makeMediaChannel()
    addedMediaChannel = channel
    let box = MediaChannelEntryBox(channel)

    Logger.shared.level = .trace
    Logger.shared.groups = [.channels]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.state.reader")
    let collector = runEntry(
      label: "state.entry",
      target: { $0.type.isMediaChannel && $0.message.hasPrefix("changed state from") },
      reenter: { readerQueue.sync { box.disconnect() } },
      entry: { box.connect() })

    assertLog(
      collector.firstLog { $0.type.isMediaChannel && $0.message.hasPrefix("changed state from") },
      level: .trace, type: { $0.isMediaChannel }, typeName: "mediaChannel",
      message: "changed state from disconnected to connecting")
  }

  /// `ConnectionTimer.run` / `stop` のログ出力中に handler から `isRunning` を読んでも deadlock しない
  func testConnectionTimerFromOutputHandlerDoesNotDeadlock() {
    let timer = ConnectionTimer(monitors: [], timeout: 1)
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels, .connectionTimer]

    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.loggerCallUnderLock.connectionTimer.reader")
    let collector = runEntry(
      label: "connectionTimer.entry",
      target: { $0.type.isConnectionTimer && $0.message == "stop" },
      reenter: { readerQueue.sync { _ = timer.isRunning } },
      entry: {
        timer.run {}
        timer.stop()
      })

    assertLog(
      collector.firstLog { $0.message == "stop" },
      level: .debug, type: { $0.isConnectionTimer }, typeName: "connectionTimer",
      message: "stop")
  }

  /// `ConnectionTimer.run` がその呼び出しで有効になった timeout を返すことを確認する
  ///
  /// 呼び出し元 (`MediaChannel.basicConnect`) は戻り値を使って開始ログを出すため、引数で上書きした
  /// 値と、引数を省略したときに保持している値の両方を確認します。
  func testConnectionTimerRunReturnsEffectiveTimeout() {
    let timer = ConnectionTimer(monitors: [], timeout: 1)
    XCTAssertEqual(timer.run(timeout: 3) {}, 3, "引数で指定した timeout を返すこと")
    XCTAssertEqual(timer.run {}, 3, "引数を省略した場合は保持している timeout を返すこと")
    XCTAssertEqual(timer.timeout, 3, "保持している timeout が更新されること")
    timer.stop()
  }

  /// `MediaChannel.beginDisconnect` が完了ログ → 遷移ログの順に出すことを確認する
  func testDisconnectLogsCompletionBeforeStateChange() throws {
    let channel = try makeMediaChannel()
    addedMediaChannel = channel
    let box = MediaChannelEntryBox(channel)
    box.connect()
    XCTAssertEqual(channel.state, .connecting, "接続試行中の state であること")

    let collector = LoggerCallUnderLockLogCollector()
    Logger.shared.level = .trace
    Logger.shared.groups = [.channels]
    let finished = expectation(description: "disconnect のログを収集する")
    Logger.shared.onOutputHandler = { log in
      collector.append(log)
      if log.type.isMediaChannel, log.message == "did disconnect" {
        finished.fulfill()
      }
    }

    DispatchQueue(label: "jp.shiguredo.sora.tests.loggerCallUnderLock.order.entry").async {
      box.disconnect()
    }
    let result = XCTWaiter.wait(for: [finished], timeout: Self.timeout)
    if result == .timedOut {
      hasStuckPath = true
    }
    XCTAssertEqual(result, .completed, "切断完了が \(Self.timeout) 秒以内に届くこと")

    let completion = collector.logs.firstIndex { $0.message == "connection task completed" }
    let transition = collector.logs.firstIndex {
      $0.type.isMediaChannel && $0.message == "changed state from connecting to disconnecting"
    }
    XCTAssertNotNil(completion, "完了ログが出ること")
    XCTAssertNotNil(transition, "遷移ログが出ること")
    if let completion, let transition {
      XCTAssertLessThan(completion, transition, "完了ログが遷移ログより先に出ること")
    }

    // 切断済みの MediaChannel へ再度 disconnect しても遷移しないため、完了ログは増えない。
    // 2 回目も専用 queue から実行し、collector は 2 回目専用のものを用意する (1 回目の
    // 遅延ログを拾わないため)。
    let secondCollector = LoggerCallUnderLockLogCollector()
    let noCompletion = expectation(description: "2 回目の disconnect では完了ログが出ない")
    noCompletion.isInverted = true
    Logger.shared.onOutputHandler = { log in
      secondCollector.append(log)
      if log.type.isMediaChannel, log.message == "connection task completed" {
        noCompletion.fulfill()
      }
    }
    DispatchQueue(label: "jp.shiguredo.sora.tests.loggerCallUnderLock.order.second.entry")
      .async { box.disconnect() }
    wait(for: [noCompletion], timeout: 1)
  }

  /// `ConnectionTask.cancel()` の経路で `finishDisconnect` が遷移ログを出すことを確認する
  ///
  /// `cancel()` は PeerChannel を直接切断するため、`MediaChannel` は `beginDisconnect` を経由せずに
  /// `finishDisconnect` へ到達します。ここでは `connecting` → `disconnecting` → `disconnected` の
  /// 遷移がすべて記録されることを確認します。
  ///
  /// `finishDisconnect` の「遷移ログ → 完了ログ」の順は、`cancel()` が `ConnectionTask` を先に
  /// 終端するため (`complete()` が `false` を返す) このテストでは観測できません。`beginDisconnect` を
  /// 経由しない自発的な切断でしか到達しないため、順序の検証は `beginDisconnect` の経路
  /// (`testDisconnectLogsCompletionBeforeStateChange`) に限定します。
  func testCancelAfterConnectLogsStateChange() throws {
    let channel = try makeMediaChannel()
    addedMediaChannel = channel
    let box = MediaChannelEntryBox(channel)
    let task = box.connect()
    XCTAssertEqual(channel.state, .connecting, "接続試行中の state であること")

    let collector = LoggerCallUnderLockLogCollector()
    Logger.shared.level = .trace
    Logger.shared.groups = [.channels]
    let finished = expectation(description: "切断完了のログを収集する")
    Logger.shared.onOutputHandler = { log in
      collector.append(log)
      if log.type.isMediaChannel, log.message == "did disconnect" {
        finished.fulfill()
      }
    }

    let taskBox = ConnectionTaskEntryBox(task)
    DispatchQueue(label: "jp.shiguredo.sora.tests.loggerCallUnderLock.cancelConnect.entry")
      .async { taskBox.cancel() }
    let result = XCTWaiter.wait(for: [finished], timeout: Self.timeout)
    if result == .timedOut {
      hasStuckPath = true
    }
    XCTAssertEqual(result, .completed, "cancel 後の切断完了が \(Self.timeout) 秒以内に届くこと")

    let transitions = collector.messages {
      $0.type.isMediaChannel && $0.message.hasPrefix("changed state from")
    }
    XCTAssertTrue(
      transitions.contains("changed state from connecting to disconnecting"),
      "connecting → disconnecting の遷移ログが出ること (実際: \(transitions))")
    XCTAssertTrue(
      transitions.contains("changed state from disconnecting to disconnected"),
      "disconnecting → disconnected の遷移ログが出ること (実際: \(transitions))")
  }
}
