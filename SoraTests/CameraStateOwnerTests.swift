import XCTest

@testable import Sora

/// 並行実行した結果を集めるためのスレッド安全な accumulator です。
///
/// `DispatchQueue.concurrentPerform` の closure は `@Sendable` のため、可変配列を
/// 直接 capture すると Swift 6 で警告になります。lock と配列をこの型に閉じ込めます。
private final class CapturerCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var capturers: [CameraVideoCapturer] = []

  func append(_ capturer: CameraVideoCapturer) {
    lock.lock()
    defer { lock.unlock() }
    capturers.append(capturer)
  }

  func snapshot() -> [CameraVideoCapturer] {
    lock.lock()
    defer { lock.unlock() }
    return capturers
  }
}

/// CameraStateOwner のユニットテスト
///
/// 実カメラを必要としない範囲 (generation の採番と直列化、snapshot の publish、
/// stream の compare-and-swap、capturer の解放、隔離の判定) を device 非依存で検証します。
/// 実 instance を伴う検証はカメラがある環境でのみ実行し (Simulator では skip)、
/// 手動でしか確認できない項目は実機で確認します。
final class CameraStateOwnerTests: XCTestCase {
  /// テストごとに独立した owner を生成する
  ///
  /// `CameraStateOwner.shared` を使うとテスト間で状態が共有されるため、必ず新しい owner を使います。
  private func makeOwner() -> CameraStateOwner {
    CameraStateOwner()
  }

  /// テスト用の MediaStream を 2 つ生成する
  ///
  /// compare-and-swap は参照の同一性で判定するため、別 instance の stream が 2 つ必要です。
  private func makeStreams() throws -> (first: MediaStream, second: MediaStream) {
    let url = try XCTUnwrap(URL(string: "wss://example.com"))
    let mediaChannel = try MediaChannel(
      configuration: Configuration(urlCandidates: [url], channelId: "test", role: .sendonly))
    let peerChannel = mediaChannel.peerChannel
    let factory = peerChannel.nativePeerChannelFactory
    let first = BasicMediaStream(
      peerChannel: peerChannel,
      nativeStream: factory.createNativeStream(streamId: "first"))
    let second = BasicMediaStream(
      peerChannel: peerChannel,
      nativeStream: factory.createNativeStream(streamId: "second"))
    return (first, second)
  }

  // MARK: - 世代

  /// 世代の採番が並行呼び出しでも取りこぼしなく直列化されることを確認する
  func testNextGenerationIsSerialized() {
    let owner = makeOwner()
    let iterations = 200

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      _ = owner.nextGeneration()
    }

    XCTAssertEqual(
      owner.nextGeneration(), UInt64(iterations) + 1,
      "並行に採番しても取りこぼしなく単調増加すること")
  }

  // MARK: - ID

  /// capturer ID が値型として安定していることを確認する
  ///
  /// owner の各テーブルと coordinator の隔離は ID の値等価性に依存するため、
  /// 同一インスタンスの比較と辞書キーとしての往復を固定します。
  func testCapturerIDEqualityIsStable() {
    let id = CameraCapturerID()
    let sameValue = id
    let other = CameraCapturerID()

    XCTAssertEqual(id, sameValue, "同じ値の ID は等価であること")
    XCTAssertEqual(id.hashValue, sameValue.hashValue, "同じ値の ID は同じハッシュを持つこと")
    XCTAssertNotEqual(id, other, "別に発行した ID は非等価であること")

    let table = [id: 30]
    XCTAssertEqual(table[CameraCapturerID()], nil, "別の ID では引けないこと")
    XCTAssertEqual(table[sameValue], 30, "同じ値の ID で引けること")
  }

  // MARK: - snapshot

  /// handle が snapshot を publish し、 active は開始成功時に確定することを確認する
  func testHandlePublishesSnapshot() {
    let owner = makeOwner()
    let id = CameraCapturerID()

    _ = owner.handle(.startRequested(id: id, generation: 1))

    XCTAssertEqual(owner.snapshot.phase, .starting, "開始要求で phase が starting になること")
    XCTAssertNil(owner.snapshot.activeCapturerID, "開始要求では active が設定されないこと")

    _ = owner.handle(.startCompleted(id: id, generation: 1, success: true))

    XCTAssertEqual(owner.snapshot.activeCapturerID, id, "開始成功で active が設定されること")
  }

  /// 古い generation の完了イベントが状態を変えないことを確認する
  func testStaleEventDoesNotChangeState() {
    let owner = makeOwner()
    let id = CameraCapturerID()
    _ = owner.handle(.startRequested(id: id, generation: 2))

    _ = owner.handle(.startCompleted(id: id, generation: 1, success: true))

    XCTAssertEqual(owner.snapshot.phase, .starting, "古い世代の完了では phase が変わらないこと")
    XCTAssertNil(owner.snapshot.activeCapturerID, "古い世代の完了では active が変わらないこと")
  }

  /// isRunning が runningCapturers を反映することを確認する
  func testIsRunningReflectsState() {
    let owner = makeOwner()
    let id = CameraCapturerID()

    XCTAssertFalse(owner.isRunning(id: id), "初期状態では動作していないこと")

    _ = owner.handle(.startRequested(id: id, generation: 1))
    _ = owner.handle(.startCompleted(id: id, generation: 1, success: true))
    XCTAssertTrue(owner.isRunning(id: id), "開始成功で動作中になること")

    _ = owner.handle(.stopRequested(id: id, generation: 2))
    _ = owner.handle(.stopCompleted(id: id, generation: 2))
    XCTAssertFalse(owner.isRunning(id: id), "停止成功で動作中から外れること")
  }

  /// flip 完了で active が切り替え先へ移ることを owner の snapshot で確認する
  func testFlipCompletedMovesActiveCapturer() {
    let owner = makeOwner()
    let source = CameraCapturerID()
    let target = CameraCapturerID()
    _ = owner.handle(.startRequested(id: source, generation: 1))
    _ = owner.handle(.startCompleted(id: source, generation: 1, success: true))
    _ = owner.handle(.flipRequested(sourceID: source, targetID: target, generation: 2))
    XCTAssertTrue(owner.snapshot.isFlipping, "切り替え要求で切り替え中フラグが立つこと")

    _ = owner.handle(.stopCompleted(id: source, generation: 2))
    _ = owner.handle(
      .flipCompleted(sourceID: source, targetID: target, generation: 2, success: true))

    XCTAssertEqual(owner.snapshot.activeCapturerID, target, "active が切り替え先へ移ること")
    XCTAssertTrue(owner.isRunning(id: target), "切り替え先が動作中になること")
    XCTAssertFalse(owner.isRunning(id: source), "切り替え元が動作中から外れること")
    XCTAssertFalse(owner.snapshot.isFlipping, "切り替え中フラグが解除されること")
  }

  // MARK: - stream

  /// stream が capturer ID ごとに独立していることを確認する
  func testStreamIsScopedByCapturerID() throws {
    let owner = makeOwner()
    let first = CameraCapturerID()
    let second = CameraCapturerID()
    let (stream, _) = try makeStreams()

    owner.setStream(stream, id: first)

    XCTAssertTrue(owner.stream(id: first) === stream, "設定した stream が返ること")
    XCTAssertNil(owner.stream(id: second), "未設定の ID では nil が返ること")
  }

  /// compare-and-swap が現在値と一致する場合に置き換えることを確認する
  func testCompareAndSetStreamReplacesMatchingValue() throws {
    let owner = makeOwner()
    let id = CameraCapturerID()
    let (first, second) = try makeStreams()
    owner.setStream(first, id: id)

    let result = owner.compareAndSetStream(first, to: second, id: id)

    XCTAssertTrue(result, "現在値と一致する場合は書き換えること")
    XCTAssertTrue(owner.stream(id: id) === second, "書き換えた値が返ること")
  }

  /// compare-and-swap が現在値と一致しない場合は書き換えないことを確認する
  func testCompareAndSetStreamKeepsValueOnMismatch() throws {
    let owner = makeOwner()
    let id = CameraCapturerID()
    let (first, second) = try makeStreams()
    owner.setStream(first, id: id)

    let result = owner.compareAndSetStream(second, to: nil, id: id)

    XCTAssertFalse(result, "現在値と一致しない場合は false を返すこと")
    XCTAssertTrue(owner.stream(id: id) === first, "現在値が維持されること")
  }

  /// compare-and-swap が一致する現在値を nil へ戻せることを確認する
  func testCompareAndSetStreamClearsMatchingValue() throws {
    let owner = makeOwner()
    let id = CameraCapturerID()
    let (first, _) = try makeStreams()
    owner.setStream(first, id: id)

    let result = owner.compareAndSetStream(first, to: nil, id: id)

    XCTAssertTrue(result, "現在値と一致する場合は解除できること")
    XCTAssertNil(owner.stream(id: id), "解除後は nil が返ること")
  }

  /// command 実行中に利用者が代入した stream を rollback が破壊しないことを確認する
  func testCompareAndSetStreamDoesNotReplaceUserAssignment() throws {
    let owner = makeOwner()
    let id = CameraCapturerID()
    let (commandValue, userValue) = try makeStreams()
    // command が設定した後に、利用者が別の stream を代入した状況を作る
    owner.setStream(commandValue, id: id)
    owner.setStream(userValue, id: id)

    let result = owner.compareAndSetStream(commandValue, to: nil, id: id)

    XCTAssertFalse(result, "command が設定した値が残っていない場合は rollback しないこと")
    XCTAssertTrue(owner.stream(id: id) === userValue, "利用者の代入が維持されること")
  }

  /// 現在値が nil のときに nil へ書き換えても成功することを確認する
  func testCompareAndSetStreamWithNilMatchesNil() {
    let owner = makeOwner()
    let id = CameraCapturerID()

    XCTAssertTrue(owner.compareAndSetStream(nil, to: nil, id: id), "nil 同士は一致とみなすこと")
    XCTAssertNil(owner.stream(id: id))
  }

  // MARK: - 隔離

  /// 隔離と解除の phase 遷移を確認する
  func testQuarantineRoundTrip() {
    let owner = makeOwner()

    _ = owner.handle(.quarantined)
    XCTAssertEqual(owner.snapshot.phase, .quarantined, "隔離で phase が quarantined になること")

    _ = owner.handle(.quarantineCleared)
    XCTAssertEqual(owner.snapshot.phase, .idle, "解除で idle に戻ること")
  }

  // MARK: - 解放

  /// capturer の解放で資源と state が破棄されることを確認する
  func testReleaseDiscardsResourcesAndState() throws {
    let owner = makeOwner()
    let id = CameraCapturerID()
    let (stream, _) = try makeStreams()
    owner.setStream(stream, id: id)
    _ = owner.handle(.startRequested(id: id, generation: 1))
    _ = owner.handle(.startCompleted(id: id, generation: 1, success: true))
    _ = owner.handle(.formatResolved(id: id, frameRate: 30, generation: 1))

    owner.release(id: id)
    // release は eventQueue へ非同期に投入する。同じ serial queue の同期処理は FIFO で
    // 後から実行されるため、これを barrier として完了を待つ。
    // (nextGeneration は世代を進めるが publish しないため、このテストの検証には影響しない)
    _ = owner.nextGeneration()

    XCTAssertNil(owner.stream(id: id), "資源テーブルの stream を破棄すること")
    XCTAssertNil(owner.frameRate(id: id), "frameRates を破棄すること")
    XCTAssertFalse(owner.isRunning(id: id), "動作中から外れること")
    XCTAssertNil(owner.snapshot.activeCapturerID, "active を解除すること")
  }

  // MARK: - 実 instance (カメラがある環境のみ)

  /// front capturer が同一 instance を返すことを確認する
  func testFrontCapturerIsSingleton() throws {
    try XCTSkipIf(
      CameraVideoCapturer.device(for: .front) == nil, "前面カメラが無いため capturer を生成できません")
    let owner = makeOwner()

    let first = try XCTUnwrap(owner.frontCapturer(), "front capturer を生成できること")
    let second = try XCTUnwrap(owner.frontCapturer(), "front capturer を再取得できること")

    XCTAssertTrue(first === second, "front は同一 instance を返すこと")
  }

  /// back capturer が同一 instance を返すことを確認する
  func testBackCapturerIsSingleton() throws {
    try XCTSkipIf(
      CameraVideoCapturer.device(for: .back) == nil, "背面カメラが無いため capturer を生成できません")
    let owner = makeOwner()

    let first = try XCTUnwrap(owner.backCapturer(), "back capturer を生成できること")
    let second = try XCTUnwrap(owner.backCapturer(), "back capturer を再取得できること")

    XCTAssertTrue(first === second, "back は同一 instance を返すこと")
  }

  /// front capturer を同時に取得しても同一 instance になることを確認する
  ///
  /// `setFrontIfAbsent` は生成に負けた instance を保持しないため、同時アクセスでも
  /// 同じ position に 1 つの instance だけが存在する。
  func testFrontCapturerIsSingletonUnderConcurrency() throws {
    try XCTSkipIf(
      CameraVideoCapturer.device(for: .front) == nil, "前面カメラが無いため capturer を生成できません")
    let owner = makeOwner()
    let iterations = 8
    let collector = CapturerCollector()

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      guard let capturer = owner.frontCapturer() else {
        return
      }
      collector.append(capturer)
    }

    let capturers = collector.snapshot()
    let first = try XCTUnwrap(capturers.first, "front capturer を取得できること")
    XCTAssertEqual(capturers.count, iterations, "同時アクセスでもすべて取得できること")
    XCTAssertTrue(capturers.allSatisfy { $0 === first }, "同時アクセスでも同一 instance であること")
  }

  /// pin 中は instance が生存し、unpin で解放されることを確認する
  func testPinKeepsInstanceAliveUntilUnpin() throws {
    try XCTSkipIf(
      CameraVideoCapturer.devices.isEmpty, "実カメラが無いため capturer を生成できません")
    let owner = makeOwner()
    let device = try XCTUnwrap(CameraVideoCapturer.devices.first)
    var capturer: CameraVideoCapturer? = CameraVideoCapturer(device: device)
    let id = try XCTUnwrap(capturer?.id)
    weak let weakCapturer = capturer

    owner.pin(id: id, instance: try XCTUnwrap(capturer))
    capturer = nil

    XCTAssertNotNil(weakCapturer, "pin 中は instance が生存すること")

    owner.unpin(id: id)

    XCTAssertNil(weakCapturer, "unpin 後は instance が解放されること")
  }

  /// 同じ ID を 2 回 pin した場合、1 回の unpin では解放されないことを確認する
  ///
  /// 別の lease が同じ capturer を保持していても、先の unpin で生存保証が消えない。
  func testPinIsReferenceCounted() throws {
    try XCTSkipIf(
      CameraVideoCapturer.devices.isEmpty, "実カメラが無いため capturer を生成できません")
    let owner = makeOwner()
    let device = try XCTUnwrap(CameraVideoCapturer.devices.first)
    var capturer: CameraVideoCapturer? = CameraVideoCapturer(device: device)
    let id = try XCTUnwrap(capturer?.id)
    weak let weakCapturer = capturer

    // 同じ ID を 2 回 pin する (別の lease が同じ capturer を保持する状況)。
    // instance を保持するローカル変数を残すと解放を検証できないため、都度 unwrap して渡す。
    owner.pin(id: id, instance: try XCTUnwrap(capturer))
    owner.pin(id: id, instance: try XCTUnwrap(capturer))
    capturer = nil

    owner.unpin(id: id)

    XCTAssertNotNil(weakCapturer, "保持者が残っている間は instance が生存すること")

    owner.unpin(id: id)

    XCTAssertNil(weakCapturer, "すべての保持者が解除されたら解放されること")
  }

  /// ID から instance を解決できることを確認する
  func testCurrentCapturerResolvesRegisteredInstance() throws {
    try XCTSkipIf(
      CameraVideoCapturer.devices.isEmpty, "実カメラが無いため capturer を生成できません")
    let owner = makeOwner()
    let device = try XCTUnwrap(CameraVideoCapturer.devices.first)
    let capturer = CameraVideoCapturer(device: device)
    // CameraVideoCapturer は生成時に process-wide な shared へ登録するため、
    // テストローカルの owner へ改めて登録して解決を検証する
    owner.register(id: capturer.id, instance: capturer)
    // 実カメラを起動せず、state の遷移だけで active を確定させる
    _ = owner.handle(.startRequested(id: capturer.id, generation: 1))
    _ = owner.handle(.startCompleted(id: capturer.id, generation: 1, success: true))

    XCTAssertTrue(owner.capturer(id: capturer.id) === capturer, "ID から instance を解決できること")
    XCTAssertTrue(owner.currentCapturer === capturer, "active capturer を解決できること")
  }
}
