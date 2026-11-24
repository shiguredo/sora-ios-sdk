import Foundation
import XCTest

@testable import Sora

// `DeviceInfo.current` と lock 付き storage の並行性を検証します。
//
// モックやスタブは使わず、実 `DeviceInfo` / 実 `DeviceInfoStorage` / 実 `PeerChannel` /
// 実 `Configuration` などの実コンポーネントだけを使います。
//
// lock の取得順:
// - 初期 snapshot の生成は `DeviceInfoStorage` の lock の外で行い、lock を保持したまま
//   main queue / MainActor を待ちません。
// - `currentSystemInfo()` は main thread 以外では main queue へ同期するため、その待ちを storage の
//   lock 下で行いません。main queue を回す必要がある待機は `wait(for:)` を使います。
//
// 並行度 64 は既存の並行 stress test (`PeerChannelConnectCompletionTests` /
// `StreamFrameOwnerTests`) と同じ値です。connect の 32 は 8 write / 24 read の比率です。
// 並行区間の判定は外側で行います。`runConcurrently` / `runConcurrentlyWithMain` は全 task を
// enqueue してから gate を開きますが、並列度そのものは保証されないため、最終的な競合検出は
// TSan に依存します。
//
// main thread と background thread が同じ storage へ同時に初回取得する直接テストは、
// 退行時に test runner 全体をハングさせるため行いません。lock 外生成は
// `testStorageInitialGenerationRunsOutsideLock`、実 main.sync は
// `testCurrentSystemInfoOnMainAndBackgroundThread` と
// `testStorageRealInitialGenerationRunsOutsideLock` で確認します。`static let` の初期化子内で
// snapshot を生成しないことは、テストプロセス内で再現できないためコードレビューで確認します。
//
// なお、呼び出し側が main thread を塞いだ状態で background thread が初回取得すると、
// currentSystemInfo() の main queue 同期で deadlock し得ます。これは SDK の lock ではなく
// 呼び出し側の待ちに起因するため、本テストの対象外です。
final class DeviceInfoTests: XCTestCase {
  /// `DeviceInfo.current` はプロセス全体の共有状態のため、実 `current` を書き換えるテストは
  /// 直列実行を前提とします。
  private var originalCurrent: DeviceInfo?

  override func setUp() {
    super.setUp()
    // 最初の取得を main thread で行います。これにより並行区間では currentSystemInfo() の
    // main queue 同期が発生しません。
    originalCurrent = DeviceInfo.current
  }

  override func tearDown() {
    if let originalCurrent {
      DeviceInfo.current = originalCurrent
      XCTAssertEqual(
        DeviceInfo.current.description, originalCurrent.description,
        "DeviceInfo.current が元の値へ復元されること")
    }
    super.tearDown()
  }

  // MARK: - DeviceInfo.current

  /// main thread と複数の background thread から `DeviceInfo.current` を同時に読み書きし、
  /// 取得した値が完全な 1 snapshot であることを確認します。
  func testCurrentReadWriteFromMultipleThreads() {
    let values = makeDeviceInfoValues(prefix: "race")
    let allowed = Set(values.map(\.description))
    XCTAssertEqual(allowed.count, values.count, "fixture の description が一意であること")

    // setUp の実初期値は最初の write より前に観測され得るため、競合区間の開始値を
    // テスト内の値へ固定します。
    DeviceInfo.current = values[0]
    XCTAssertEqual(
      DeviceInfo.current.description, values[0].description,
      "競合区間の開始値を setter で設定できること")

    let collector = StringCollector()
    runConcurrentlyWithMain(
      iterations: 32,
      mainIterations: 16,
      backgroundBody: { index in
        if index.isMultiple(of: 2) {
          DeviceInfo.current = values[(index / 2) % values.count]
        } else {
          collector.append(DeviceInfo.current.description)
        }
      },
      mainBody: { index in
        if index.isMultiple(of: 2) {
          DeviceInfo.current = values[(index / 2) % values.count]
        } else {
          collector.append(DeviceInfo.current.description)
        }
      })

    let descriptions = collector.snapshot()
    XCTAssertEqual(
      collector.count, 24,
      "main thread と background thread の read がすべて記録されること")
    XCTAssertTrue(
      descriptions.allSatisfy { allowed.contains($0) },
      "読み出した description が既知の snapshot のいずれかであること")

    // 競合区間の後に既知の値を書き、setter の値が getter から読めることを確認します。
    DeviceInfo.current = values[values.count - 1]
    XCTAssertEqual(
      DeviceInfo.current.description, values[values.count - 1].description,
      "setter で書いた値が getter からそのまま読めること")
  }

  /// `PeerChannel` の connect message 生成と `DeviceInfo.current` の変更を競合させ、
  /// environment が完全な 1 snapshot の description に一致することを確認します。
  func testConnectMessageUsesCoherentSnapshot() throws {
    let peerChannelBox = PeerChannelBox(try makePeerChannel())
    let values = makeDeviceInfoValues(prefix: "connect")
    let allowed = Set(values.map(\.description))
    DeviceInfo.current = values[0]
    XCTAssertEqual(
      DeviceInfo.current.description, values[0].description,
      "競合区間の開始値を setter で設定できること")

    let collector = StringCollector()
    runConcurrently(iterations: 32) { index in
      if index.isMultiple(of: 4) {
        DeviceInfo.current = values[(index / 4) % values.count]
      } else {
        // makeSignalingConnect は DeviceInfo.current を 1 回だけ読み、その description を
        // environment に設定します。
        let connect = peerChannelBox.peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
        collector.append(connect.environment ?? "<nil>")
      }
    }

    let environments = collector.snapshot()
    XCTAssertEqual(collector.count, 24, "environment を取得した connect message が 24 件であること")
    XCTAssertFalse(environments.contains("<nil>"), "environment が nil の connect message が無いこと")
    XCTAssertTrue(
      environments.allSatisfy { allowed.contains($0) },
      "environment が既知の snapshot のいずれかであること")
  }

  /// connect message の environment が `DeviceInfo.current.description` と同じ文字列表現で
  /// あることを、JSON 経由で確認します。
  func testSignalingConnectEnvironmentUsesCurrentDescription() throws {
    let value = makeDeviceInfo("environment")
    DeviceInfo.current = value

    let connect = try makePeerChannel().makeSignalingConnect(sdp: nil, redirect: nil)
    let data = try JSONEncoder().encode(Signaling.connect(connect))
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any],
      "connect message を JSON に変換できること")
    XCTAssertEqual(
      json["environment"] as? String, value.description,
      "environment の文字列表現が DeviceInfo.description と一致すること")
  }

  /// machine name、system name、system version の既存形式が維持されることを確認します。
  func testCurrentDescriptionUsesRealDeviceInfo() {
    let current = DeviceInfo.current
    let snapshot = DeviceInfo.makeSnapshot()
    XCTAssertFalse(current.machineName.isEmpty, "machineName が空でないこと")
    XCTAssertFalse(current.systemName.isEmpty, "systemName が空でないこと")
    XCTAssertFalse(current.systemVersion.isEmpty, "systemVersion が空でないこと")
    XCTAssertEqual(
      current.description, snapshot.description,
      "現在の snapshot が実端末情報と一致すること")
    XCTAssertEqual(
      current.description,
      "\(current.machineName); \(current.systemName) \(current.systemVersion)",
      "description の形式が既存のままであること")
  }

  /// main thread と background thread の `currentSystemInfo()` が同じ値を返し、main run loop を
  /// 回している状態で background thread の `DispatchQueue.main.sync` が deadlock しないことを
  /// 確認します。
  func testCurrentSystemInfoOnMainAndBackgroundThread() {
    guard Thread.isMainThread else {
      XCTFail("main queue を回すため main thread から呼ぶこと")
      return
    }

    let mainInfo = currentSystemInfo()
    XCTAssertFalse(mainInfo.systemName.isEmpty, "main thread で systemName が取得できること")
    XCTAssertFalse(mainInfo.systemVersion.isEmpty, "main thread で systemVersion が取得できること")

    let collector = StringCollector()
    let finished = expectation(description: "background thread の currentSystemInfo が完了すること")
    DispatchQueue.global().async {
      let info = currentSystemInfo()
      collector.append("\(info.systemName) \(info.systemVersion)")
      finished.fulfill()
    }

    // wait(for:) は待機中も main RunLoop を回すため、background thread の
    // DispatchQueue.main.sync を処理できます。ここで DispatchSemaphore.wait を使うと
    // main が止まり、deadlock します。
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(
      collector.snapshot(), ["\(mainInfo.systemName) \(mainInfo.systemVersion)"],
      "main thread と background thread で同じ system 情報が得られること")
  }

  // MARK: - DeviceInfoStorage

  /// 初期 snapshot の生成が storage の lock を保持せずに行われることを確認します。
  func testStorageInitialGenerationRunsOutsideLock() {
    let storage = DeviceInfoStorage()
    let generated = makeDeviceInfo("generated")
    let userValue = makeDeviceInfo("user")
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let collector = StringCollector()
    let generatedFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      let value = storage.current {
        started.signal()
        _ = proceed.wait(timeout: .now() + 10)
        return generated
      }
      collector.append(value.description)
      generatedFinished.signal()
    }

    XCTAssertEqual(
      started.wait(timeout: .now() + 5), .success,
      "生成の開始を 5 秒以内に観測できること")

    let setterFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      storage.set(userValue)
      setterFinished.signal()
    }
    XCTAssertEqual(
      setterFinished.wait(timeout: .now() + 5), .success,
      "生成中でも setter が storage の lock を待たずに完了すること")

    proceed.signal()
    XCTAssertEqual(
      generatedFinished.wait(timeout: .now() + 5), .success,
      "生成が 5 秒以内に完了すること")

    XCTAssertEqual(
      collector.snapshot(), [userValue.description],
      "生成中に設定された setter の値が返ること")
    XCTAssertEqual(
      storage.value?.description, userValue.description,
      "setter の値だけが storage に publish されること")
  }

  /// 実 `DeviceInfo.makeSnapshot()` を background thread で実行し、生成中の setter を
  /// 待たせないことと、setter の値が優先されることを確認します。
  func testStorageRealInitialGenerationRunsOutsideLock() {
    guard Thread.isMainThread else {
      XCTFail("main queue を回すため main thread から呼ぶこと")
      return
    }

    let storage = DeviceInfoStorage()
    let userValue = makeDeviceInfo("user")
    let collector = StringCollector()
    let started = expectation(description: "background の生成開始")
    let setterFinished = expectation(description: "setter の完了")
    let generated = expectation(description: "background の生成完了")
    let proceed = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      let value = storage.current {
        started.fulfill()
        _ = proceed.wait(timeout: .now() + 10)
        return DeviceInfo.makeSnapshot()
      }
      collector.append(value.description)
      generated.fulfill()
    }
    wait(for: [started], timeout: 5)

    DispatchQueue.global().async {
      storage.set(userValue)
      setterFinished.fulfill()
    }
    wait(for: [setterFinished], timeout: 5)

    // 退行時は setter の timeout で失敗し、生成側の thread は残るが、storage は local な
    // instance なので他テストへ影響しない。
    proceed.signal()
    wait(for: [generated], timeout: 5)

    XCTAssertEqual(
      collector.snapshot(), [userValue.description],
      "生成中に設定された setter の値が返ること")
    XCTAssertEqual(
      storage.value?.description, userValue.description,
      "setter の値が storage に publish されること")
  }

  /// setter が初期 snapshot の生成より先に呼ばれた場合、生成を行わず setter の値を返すことを
  /// 確認します。
  func testStorageSetterBeforeFirstGetDoesNotGenerate() {
    let storage = DeviceInfoStorage()
    let userValue = makeDeviceInfo("user-first")
    var createCallCount = 0

    storage.set(userValue)
    let value = storage.current {
      createCallCount += 1
      return makeDeviceInfo("generated")
    }

    XCTAssertEqual(value.description, userValue.description, "setter で設定した値が返ること")
    XCTAssertEqual(createCallCount, 0, "設定済みの場合は create を呼ばないこと")
  }

  /// `create` の中から `set(_:)` を呼んでも lock を再取得せず、setter の値が優先されることを
  /// 確認します。
  func testStorageCreateCanSetValue() {
    let storage = DeviceInfoStorage()
    let userValue = makeDeviceInfo("user")
    let value = storage.current {
      storage.set(userValue)
      return makeDeviceInfo("generated")
    }

    XCTAssertEqual(value.description, userValue.description, "create 内の setter の値が返ること")
    XCTAssertEqual(
      storage.value?.description, userValue.description,
      "setter の値が storage に残ること")
  }

  /// publish 後に `current` を呼んでも `create` が再実行されないことを確認します。
  func testStoragePublishDoesNotCreateAgain() {
    let storage = DeviceInfoStorage()
    var createCallCount = 0

    let first = storage.current {
      createCallCount += 1
      return makeDeviceInfo("first")
    }
    let second = storage.current {
      createCallCount += 1
      return makeDeviceInfo("second")
    }

    XCTAssertEqual(second.description, first.description, "publish 済みの値を返すこと")
    XCTAssertEqual(createCallCount, 1, "publish 後に create を呼ばないこと")
  }

  /// 複数 thread からの同時初回取得で、publish される snapshot が 1 つに定まり、
  /// すべての呼び出しが同じ値を観測することを確認します。
  func testStorageConcurrentInitialAccessPublishesOneSnapshot() {
    let storage = DeviceInfoStorage()
    let collector = StringCollector()

    runConcurrently(iterations: 64) { index in
      let generated = makeDeviceInfo("concurrent-\(index)")
      collector.append(storage.current { generated }.description)
    }

    let descriptions = Set(collector.snapshot())
    XCTAssertEqual(collector.count, 64, "並行区間の取得がすべて記録されること")
    XCTAssertEqual(descriptions.count, 1, "同時初回取得で異なる snapshot が観測されないこと")
    XCTAssertEqual(
      storage.value?.description, descriptions.first,
      "最初に publish された値が残ること")
  }

  /// main thread からの初回取得が生成した値を publish することを確認します。
  func testStorageFirstAccessFromMainThread() {
    let storage = DeviceInfoStorage()
    let expected = makeDeviceInfo("main-first")

    let value = storage.current { expected }

    XCTAssertEqual(value.description, expected.description, "main thread から生成した値が返ること")
    XCTAssertEqual(
      storage.value?.description, expected.description,
      "生成した値が publish されること")
  }

  /// background thread からの初回取得が生成した値を publish することを確認します。
  func testStorageFirstAccessFromBackgroundThread() {
    let storage = DeviceInfoStorage()
    let expected = makeDeviceInfo("background-first")
    let collector = StringCollector()
    let finished = expectation(description: "background thread の初回取得が完了すること")

    DispatchQueue.global().async {
      collector.append(storage.current { expected }.description)
      finished.fulfill()
    }

    wait(for: [finished], timeout: 5)
    XCTAssertEqual(
      collector.snapshot(), [expected.description],
      "background thread から生成した値が返ること")
    XCTAssertEqual(
      storage.value?.description, expected.description,
      "生成した値が publish されること")
  }
}

// MARK: - テスト用のヘルパー

/// テスト用の `DeviceInfo` を生成します。
///
/// `systemName` / `systemVersion` も値ごとに変え、異なる snapshot の field が混ざった
/// tear が description の一致判定を通過しないようにします。
private func makeDeviceInfo(_ name: String) -> DeviceInfo {
  DeviceInfo(
    machineName: "machine-\(name)",
    systemName: "system-\(name)",
    systemVersion: "version-\(name)")
}

/// 競合させる複数の `DeviceInfo` を生成します。
private func makeDeviceInfoValues(prefix: String) -> [DeviceInfo] {
  (0..<8).map { makeDeviceInfo("\(prefix)-\($0)") }
}

/// 複数の処理を gate 付きで並行実行します。
///
/// 全 task を enqueue してから semaphore を signal するため、worker 数が参加数より
/// 少なくても deadlock しません。各 task は main queue を同期 wait しない処理に限ります。
private func runConcurrently(
  iterations: Int,
  _ body: @escaping @Sendable (Int) -> Void
) {
  let group = DispatchGroup()
  let start = DispatchSemaphore(value: 0)
  for index in 0..<iterations {
    group.enter()
    DispatchQueue.global().async {
      _ = start.wait(timeout: .now() + 10)
      body(index)
      group.leave()
    }
  }
  for _ in 0..<iterations {
    start.signal()
  }
  XCTAssertEqual(
    group.wait(timeout: .now() + 15), .success,
    "並行処理が 15 秒以内に完了すること")
}

/// background の並行処理を開始した後、main thread でも `mainBody` を実行します。
///
/// 全 background task を enqueue してから gate を開き、`mainBody` の実行後に全 task の
/// 完了を待ちます。`mainBody` は main queue を同期 wait しない処理に限ります。
private func runConcurrentlyWithMain(
  iterations: Int,
  mainIterations: Int,
  backgroundBody: @escaping @Sendable (Int) -> Void,
  mainBody: (Int) -> Void
) {
  let group = DispatchGroup()
  let start = DispatchSemaphore(value: 0)
  for index in 0..<iterations {
    group.enter()
    DispatchQueue.global().async {
      _ = start.wait(timeout: .now() + 10)
      backgroundBody(index)
      group.leave()
    }
  }
  for _ in 0..<iterations {
    start.signal()
  }
  for index in 0..<mainIterations {
    mainBody(index)
  }
  XCTAssertEqual(
    group.wait(timeout: .now() + 15), .success,
    "並行処理が 15 秒以内に完了すること")
}

/// テスト用の `PeerChannel` を生成します。
private func makePeerChannel() throws -> PeerChannel {
  let url = try XCTUnwrap(URL(string: "wss://example.com"))
  let configuration = Configuration(
    urlCandidates: [url],
    channelId: "test",
    role: .sendonly)
  let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
  let signalingChannel = SignalingChannel(
    snapshot: snapshot,
    webSocketChannelHandlers: configuration.webSocketChannelHandlers)
  let nativeFactory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
  return PeerChannel(
    snapshot: snapshot,
    signalingChannel: signalingChannel,
    nativePeerChannelFactory: nativeFactory,
    mediaChannel: nil)
}

/// `PeerChannel` を `@Sendable` closure へ渡すための box です。
///
/// `makeSignalingConnect` は `PeerChannel` の可変状態を読まず、init で確定した `snapshot`、
/// `DeviceInfo.current`、`SDKInfo` / `WebRTCInfo` の static let と、そこから作る不変の
/// computed property (`WebRTCInfo.shortRevision` など) だけを読むため、この用途に限り
/// `@unchecked Sendable` として扱います (`PeerChannelConnectCompletionTests` の
/// `PeerChannelEntryBox` と同じ方針)。
private final class PeerChannelBox: @unchecked Sendable {
  let peerChannel: PeerChannel

  init(_ peerChannel: PeerChannel) {
    self.peerChannel = peerChannel
  }
}
