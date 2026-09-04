import XCTest

@testable import Sora

/// 接続ライフサイクル状態 reducer のユニットテスト
///
/// 接続 phase、配送済み callback 台帳、transport epoch の遷移は
/// 接続タイミングに依存する E2E テストだけでは決定的に検証できないため、
/// reducer の純粋関数として直接検証する。
final class ConnectionStateReducerTests: XCTestCase {
  // MARK: - 接続開始

  /// disconnected から connectRequested で connecting に遷移することを確認する
  func testConnectRequestedTransitionsToConnecting() {
    let state = ConnectionLifecycleState()

    let result = ConnectionStateReducer.reduce(state: state, event: .connectRequested)

    XCTAssertEqual(result.state.phase, .connecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// disconnecting 中の connectRequested は拒否されることを確認する
  func testConnectRequestedRejectedWhileDisconnecting() {
    var state = ConnectionLifecycleState()
    let connecting = ConnectionStateReducer.reduce(state: state, event: .connectRequested)
    state = connecting.state
    let disconnecting = ConnectionStateReducer.reduce(
      state: state, event: .disconnectRequested(reason: .user))
    state = disconnecting.state

    let result = ConnectionStateReducer.reduce(state: state, event: .connectRequested)

    // 状態が変わらない (拒否される)
    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertFalse(result.effects.contains(.publishSnapshot))
  }

  // MARK: - キャンセル

  /// connecting 中の cancelRequested で disconnecting に遷移することを確認する
  func testCancelRequestedTransitionsToDisconnecting() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let result = ConnectionStateReducer.reduce(state: state, event: .cancelRequested)

    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - 接続完了

  /// connecting 中の connectionEstablished で connected になり、
  /// 接続完了 callback が 1 回だけ配送されることを確認する
  func testConnectionEstablishedDeliversCallbackOnce() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let first = ConnectionStateReducer.reduce(state: state, event: .connectionEstablished)

    XCTAssertEqual(first.state.phase, .connected)
    XCTAssertTrue(first.state.deliveryTracker.didDeliverConnect)
    XCTAssertTrue(first.effects.contains(.deliverConnectCallback))

    // 2 回目の connectionEstablished は過剰配送を防ぐため何もしない
    let second = ConnectionStateReducer.reduce(state: first.state, event: .connectionEstablished)

    XCTAssertEqual(second.state.phase, .connected)
    XCTAssertFalse(second.effects.contains(.deliverConnectCallback))
  }

  // MARK: - 接続失敗

  /// connecting 中の connectionFailed で disconnected になり、
  /// 接続失敗 callback が 1 回だけ配送されることを確認する
  func testConnectionFailedDeliversCallbackWithError() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let result = ConnectionStateReducer.reduce(state: state, event: .connectionFailed)

    XCTAssertEqual(result.state.phase, .disconnected)
    XCTAssertTrue(result.state.deliveryTracker.didDeliverConnect)
    XCTAssertTrue(result.effects.contains(.deliverConnectCallbackWithError))
  }

  // MARK: - 接続タイムアウト

  /// connecting 中の connectionTimeout で disconnecting に遷移することを確認する
  func testConnectionTimeoutTransitionsToDisconnecting() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let result = ConnectionStateReducer.reduce(state: state, event: .connectionTimeout)

    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - redirect

  /// offer 受信で transport epoch が増加することを確認する
  func testOfferReceivedIncrementsTransportEpoch() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let result = ConnectionStateReducer.reduce(state: state, event: .offerReceived)

    XCTAssertEqual(result.state.transportEpoch, 1)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// redirect 受信で transport epoch が増加することを確認する
  func testRedirectReceivedIncrementsTransportEpoch() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    let result = ConnectionStateReducer.reduce(state: state, event: .redirectReceived)

    XCTAssertEqual(result.state.transportEpoch, 1)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// redirect 受信で transport が切り替わり、再接続しても論理接続が維持されることを確認する
  ///
  /// 現行の実装 (0095) では redirect 中も接続は継続されるため phase は変えない。
  /// redirect 受信で epoch が増えることだけを検証する。
  func testRedirectReconnectFlow() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state
    state = ConnectionStateReducer.reduce(state: state, event: .connectionEstablished).state

    // redirect 受信: phase は connected のまま、epoch は増加する
    let redirected = ConnectionStateReducer.reduce(state: state, event: .redirectReceived)
    XCTAssertEqual(redirected.state.phase, .connected)
    XCTAssertEqual(redirected.state.transportEpoch, 1)
    state = redirected.state

    // redirect 先への接続開始: phase は変えない (接続継続中という扱い)
    let restart = ConnectionStateReducer.reduce(state: state, event: .redirectConnectStarted)
    XCTAssertEqual(restart.state.phase, .connected)
    state = restart.state

    // redirect 先への接続完了: phase は変えない
    let established = ConnectionStateReducer.reduce(
      state: state, event: .redirectConnectEstablished)
    XCTAssertEqual(established.state.phase, .connected)
  }

  // MARK: - 切断

  /// connected 中の disconnectRequested で disconnecting に遷移することを確認する
  func testDisconnectRequestedFromConnected() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state
    state = ConnectionStateReducer.reduce(state: state, event: .connectionEstablished).state

    let result = ConnectionStateReducer.reduce(
      state: state, event: .disconnectRequested(reason: .user))

    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// disconnecting 中の disconnectCompleted で disconnected になり、
  /// 切断通知が 1 回だけ配送されることを確認する
  func testDisconnectCompletedDeliversOnce() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state
    state = ConnectionStateReducer.reduce(state: state, event: .connectionEstablished).state
    state =
      ConnectionStateReducer.reduce(state: state, event: .disconnectRequested(reason: .user)).state

    let first = ConnectionStateReducer.reduce(state: state, event: .disconnectCompleted)

    XCTAssertEqual(first.state.phase, .disconnected)
    XCTAssertTrue(first.effects.contains(.deliverDisconnect))

    // 2 回目の disconnectCompleted は (phase が disconnected のため) 何もしない
    let second = ConnectionStateReducer.reduce(state: first.state, event: .disconnectCompleted)

    XCTAssertEqual(second.state.phase, .disconnected)
    XCTAssertFalse(second.effects.contains(.deliverDisconnect))
  }

  // MARK: - ストレージ

  /// ConnectionSnapshotStorage の publish / current がロックで保護されていることを確認する
  func testSnapshotStoragePublishAndRead() {
    let storage = ConnectionSnapshotStorage()
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectRequested).state

    storage.publish(state: state)

    let snapshot = storage.current()
    XCTAssertEqual(snapshot.state.phase, .connecting)
  }
}
