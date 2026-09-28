import XCTest

@testable import Sora

/// 非 Sendable な `PeerChannel` を `@Sendable` closure へ直接 capture せずに渡す、用途限定の box です。
///
/// `PeerChannel` は Sendable ではないため、`DispatchQueue.concurrentPerform` の closure が
/// 直接 capture すると `-swift-version 6` の型検査で `#SendableClosureCaptures` の warning が出ます。
/// この box は不変の参照を保持するだけで、各スレッドから実 `PeerChannel` の同じ入口を呼び出します。
/// `@unchecked Sendable` を認める根拠は、box 自身が可変状態を持たず、複数スレッドから触る
/// `PeerChannel` の排他を `PeerChannel` 側の `connectHandlerLock` が担うことです。
private final class PeerChannelEntryBox: @unchecked Sendable {
  let peerChannel: PeerChannel

  init(_ peerChannel: PeerChannel) {
    self.peerChannel = peerChannel
  }
}

/// 並行実行した接続終端と状態読み出しの結果を集約する accumulator です。
///
/// 並行実行中の closure から `XCTAssert*` を呼ばず、結果を並行実行の終了後にまとめて検証するため、
/// 結果はこの型へ lock 付きで集めます (`StringCollector` と同じ方針)。
/// 可変状態をこの型に閉じ込めることで、`@Sendable` closure が直接 capture できるようにします。
private final class ConnectTerminationAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var invocationCount = 0
  private var states: [PeerChannelConnectionState] = []

  /// 接続完了 callback の呼び出し回数を 1 増やします。
  func incrementInvocationCount() {
    lock.lock()
    defer { lock.unlock() }
    invocationCount += 1
  }

  /// `state` の読み出し結果を記録します。
  func record(state: PeerChannelConnectionState) {
    lock.lock()
    defer { lock.unlock() }
    states.append(state)
  }

  /// 集約した接続完了 callback の呼び出し回数を返します。
  var callbackInvocationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return invocationCount
  }

  /// 集約した `state` の読み出し結果を返します。
  func observedStates() -> [PeerChannelConnectionState] {
    lock.lock()
    defer { lock.unlock() }
    return states
  }
}

/// PeerChannel の接続完了ハンドラーの終端保証に関するユニットテスト
///
/// 接続完了ハンドラー (onConnect) は、接続成功 (finishConnecting)、
/// 接続失敗 (sendConnectMessage(error:))、接続完了後の切断 (basicDisconnect) の
/// どの経路から呼ばれても 1 回だけ呼ばれることを保証する必要がある。
/// callback 内から同期的に disconnect() された場合でも、二重実行されないことを
/// take-and-clear で検証する。
final class PeerChannelConnectCompletionTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("failed to create test URL")
    }
    return url
  }

  // 実際の接続失敗が発生する URL を返す
  // (127.0.0.1:1 は接続が即時失敗するため、モックなしで接続失敗経路を実走できる)
  private func makeConnectionRefusedURL() -> URL {
    guard let url = URL(string: "wss://127.0.0.1:1") else {
      fatalError("failed to create test URL")
    }
    return url
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    let url = makeTestURL()
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
  }

  // 接続失敗する URL を持つ Configuration を構築する
  private func makeConnectionRefusedConfiguration() -> Configuration {
    Configuration(
      urlCandidates: [makeConnectionRefusedURL()],
      channelId: "test",
      role: .sendonly)
  }

  // PeerChannel を実際に構築する
  private func makePeerChannel(config: Configuration) throws -> PeerChannel {
    let snapshot = try ConnectionConfigurationSnapshot(configuration: config)
    let signalingChannel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: config.webSocketChannelHandlers)
    let nativeFactory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
  }

  /// 接続完了 callback が 2 回呼ばれても 1 回目だけ実行されることを確認する
  ///
  /// take-and-clear により、1 回目の呼び出しで onConnect が nil へクリアされるため、
  /// 2 回目の呼び出しでは callback が実行されない。
  func testInvokeConnectHandlerRunsOnce() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    var callCount = 0

    peerChannel.onConnect = { _ in
      callCount += 1
    }

    // 接続成功後の切断と二重終端が競合した場合を模擬する。
    // (実際には finishConnecting / sendConnectMessage / basicDisconnect の
    // いずれか 1 つの経路だけが callback を取り出す)
    peerChannel.invokeConnectHandler(nil)
    peerChannel.invokeConnectHandler(nil)

    XCTAssertEqual(callCount, 1, "接続完了 callback は 1 回だけ呼ばれること")
  }

  /// callback 内から同期的に disconnect() しても callback は 2 回呼ばれないことを確認する
  ///
  /// take-and-clear により、callback 実行前に onConnect が nil へクリアされるため、
  /// callback 内から disconnect() → basicDisconnect() が再入しても同じ callback は
  /// 再実行されない。
  func testInvokeConnectHandlerReentrantDisconnectRunsOnce() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    var callCount = 0

    peerChannel.onConnect = { _ in
      callCount += 1
      // 接続成功 callback 内から同期的に切断処理へ再入する
      peerChannel.disconnect(error: nil, reason: .user)
    }

    peerChannel.invokeConnectHandler(nil)

    XCTAssertEqual(callCount, 1, "接続完了 callback 内からの再入でも callback は 1 回だけ呼ばれること")
  }

  /// 接続失敗 (Error あり) でも callback が 1 回だけ呼ばれることを確認する
  func testInvokeConnectHandlerWithErrorRunsOnce() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    var callCount = 0
    var receivedError: Error?

    peerChannel.onConnect = { error in
      callCount += 1
      receivedError = error
    }

    let testError = SoraError.peerChannelError(reason: "test error")
    peerChannel.invokeConnectHandler(testError)

    XCTAssertEqual(callCount, 1, "接続失敗 callback は 1 回だけ呼ばれること")
    XCTAssertNotNil(receivedError, "接続失敗のエラーが伝播されること")
  }

  /// 実際の接続失敗経路で callback が 1 回だけ呼ばれることを確認する
  ///
  /// connect(handler:) → SignalingChannel 接続失敗 (127.0.0.1:1) →
  /// sendConnectMessage(error:) → basicDisconnect → invokeConnectHandler の
  /// 実経路を検証する。モックやスタブは使用しない。
  func testConnectFailureReachesHandlerOnce() throws {
    let config = makeConnectionRefusedConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    var callCount = 0
    var receivedError: Error?

    let expectation = self.expectation(description: "接続失敗 callback が 1 回だけ呼ばれること")
    peerChannel.connect { error in
      callCount += 1
      receivedError = error
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5)

    XCTAssertEqual(callCount, 1, "接続失敗 callback は 1 回だけ呼ばれること")
    XCTAssertNotNil(receivedError, "接続失敗のエラーが伝播されること")
  }

  /// 複数スレッドから同時に終端しても callback が 2 回以上実行されないことを確認する
  ///
  /// 1 回保証の論理的な根拠は、取り出しとクリアを単一の排他区間で行う `takeConnectHandler()` の
  /// 実装 (コードの単一排他区間) である。このテストはそれが並行実行で破れていないことを
  /// `XCTestExpectation` の `assertForOverFulfill` で確認し、主に Thread Sanitizer を
  /// 有効にした実行での回帰検出を担う。`assertForOverFulfill` 自体を 1 回保証の根拠とはしない。
  /// データ競合そのものの検出も Thread Sanitizer を有効にした実行の担当である。
  func testInvokeConnectHandlerConcurrentCallsRunsOnce() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    let box = PeerChannelEntryBox(peerChannel)

    let expectation = self.expectation(description: "接続完了 callback が 1 回だけ呼ばれること")
    // callback が 2 回以上実行された場合を失敗として検出する
    expectation.assertForOverFulfill = true
    peerChannel.onConnect = { _ in
      expectation.fulfill()
    }

    // 8 スレッドから同時に終端経路を走らせ、take-and-clear の 1 回保証を確認する
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      box.peerChannel.invokeConnectHandler(nil)
    }

    wait(for: [expectation], timeout: 5)
  }

  /// 接続終端と接続試行中の判定を並行実行しても callback が 1 回だけ呼ばれることを確認する
  ///
  /// 元の競合対は、`invokeConnectHandler` の take-and-clear (`onConnect` の読みと nil の書き) と、
  /// `state` の `onConnect != nil` の読みである。この 2 つを `DispatchQueue.concurrentPerform` で
  /// 同時に駆動する。排他を外した旧実装では 2 スレッドが同じ callback を取り出して 2 回
  /// 実行され得るため、呼び出し回数を lock 付き accumulator で集計し、並行実行の外で
  /// 1 回であることを検証する。`state` の読み出し結果も値域を集計して外で検証する。
  ///
  /// 並行実行中の closure から `XCTAssert*` を呼ばないため、検証はすべて実行後に行う。
  /// データ競合そのものの検出は Thread Sanitizer を有効にした実行の担当である。
  func testConcurrentInvokeConnectHandlerAndStateReadRunsOnce() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    let box = PeerChannelEntryBox(peerChannel)
    let accumulator = ConnectTerminationAccumulator()

    peerChannel.onConnect = { _ in
      accumulator.incrementInvocationCount()
    }

    // 偶数 index が終端経路 (take-and-clear)、奇数 index が接続試行中の判定 (state) を回す
    DispatchQueue.concurrentPerform(iterations: 64) { index in
      if index.isMultiple(of: 2) {
        box.peerChannel.invokeConnectHandler(nil)
      } else {
        accumulator.record(state: box.peerChannel.state)
      }
    }

    XCTAssertEqual(
      accumulator.callbackInvocationCount, 1,
      "終端と接続試行中の判定を並行実行しても接続完了 callback は 1 回だけ呼ばれること")
    // onConnect を保持している間は .connecting、終端後は RTCPeerConnection が未生成のため .new になる
    XCTAssertTrue(
      accumulator.observedStates().allSatisfy { $0 == .connecting || $0 == .new },
      "接続試行中の判定が接続状態の値域 (.connecting / .new) に収まること")
  }

  /// 切断処理を開始済みの PeerChannel では signaling を開始せず接続を終端することを確認する
  func testConnectAfterDisconnectDoesNotStartSignaling() throws {
    let config = makeConfiguration()
    let peerChannel = try makePeerChannel(config: config)
    var callCount = 0
    var receivedError: Error?

    peerChannel.disconnect(error: nil, reason: .user)
    peerChannel.connect { error in
      callCount += 1
      receivedError = error
    }

    XCTAssertEqual(callCount, 1, "接続完了 callback は 1 回だけ呼ばれること")
    XCTAssertNotNil(receivedError, "切断済み PeerChannel への接続はエラーになること")
    XCTAssertEqual(peerChannel.signalingChannel.state, .disconnected)
  }

  /// 初期ロック取得後に切断された場合は signaling の開始前に接続を中止することを確認する
  func testDisconnectBeforeSignalingStartPreventsStart() async throws {
    let peerChannel = try makePeerChannel(config: makeConfiguration())
    let disconnectError = SoraError.connectionCancelled
    let callbacksExpectation = expectation(description: "カメラ停止後に切断 callback が届くこと")
    callbacksExpectation.expectedFulfillmentCount = 2
    var didStartSignaling = false
    var connectCallbackCount = 0
    var disconnectCallbackCount = 0
    var receivedError: Error?

    XCTAssertTrue(peerChannel.lock.beginConnectionStart())
    peerChannel.onConnect = { error in
      connectCallbackCount += 1
      receivedError = error
      callbacksExpectation.fulfill()
    }
    peerChannel.internalHandlers.onDisconnect = { _, _ in
      disconnectCallbackCount += 1
      callbacksExpectation.fulfill()
    }

    // connect() が初期ロックを取得した直後の順序を、実際の Lock と PeerChannel で再現する。
    peerChannel.disconnect(error: disconnectError, reason: .user)
    peerChannel.lock.startConnection {
      didStartSignaling = true
    }

    XCTAssertFalse(didStartSignaling, "切断要求後は signaling を開始しないこと")
    await fulfillment(of: [callbacksExpectation], timeout: 3)
    XCTAssertEqual(connectCallbackCount, 1)
    XCTAssertEqual(disconnectCallbackCount, 1)
    XCTAssertEqual(receivedError?.localizedDescription, disconnectError.localizedDescription)
    XCTAssertEqual(peerChannel.signalingChannel.state, .disconnected)
  }

  /// signaling 開始処理中の切断要求を、開始処理の復帰後に実行することを確認する
  func testDisconnectDuringSignalingStartFinishesAfterOperation() async throws {
    let peerChannel = try makePeerChannel(config: makeConfiguration())
    let disconnectError = SoraError.connectionCancelled
    let callbacksExpectation = expectation(description: "開始処理後に切断 callback が届くこと")
    callbacksExpectation.expectedFulfillmentCount = 2
    var didRunOperation = false
    var didFinishOperation = false
    var connectCallbackCount = 0
    var disconnectCallbackCount = 0

    XCTAssertTrue(peerChannel.lock.beginConnectionStart())
    peerChannel.onConnect = { error in
      XCTAssertTrue(didFinishOperation, "開始処理の復帰後に接続 callback を終端すること")
      XCTAssertEqual(error?.localizedDescription, disconnectError.localizedDescription)
      connectCallbackCount += 1
      callbacksExpectation.fulfill()
    }
    peerChannel.internalHandlers.onDisconnect = { _, _ in
      XCTAssertTrue(didFinishOperation, "開始処理の復帰後に切断 callback を通知すること")
      disconnectCallbackCount += 1
      callbacksExpectation.fulfill()
    }

    peerChannel.lock.startConnection {
      didRunOperation = true
      peerChannel.disconnect(error: disconnectError, reason: .user)
      XCTAssertEqual(connectCallbackCount, 0)
      XCTAssertEqual(disconnectCallbackCount, 0)
      didFinishOperation = true
    }

    XCTAssertTrue(didRunOperation)
    XCTAssertTrue(didFinishOperation)
    await fulfillment(of: [callbacksExpectation], timeout: 3)
    XCTAssertEqual(connectCallbackCount, 1)
    XCTAssertEqual(disconnectCallbackCount, 1)
    XCTAssertEqual(peerChannel.signalingChannel.state, .disconnected)
  }
}
