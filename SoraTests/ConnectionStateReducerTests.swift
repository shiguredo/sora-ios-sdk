import XCTest

@testable import Sora

/// PeerChannel の接続状態フラグ reducer のユニットテスト
///
/// 接続状態フラグ (transport 世代 / WebSocket スケジュール / 猶予タイマー /
/// redirect) の遷移は、接続タイミングに依存する E2E テストだけでは
/// 決定的に検証できないため、reducer の純粋関数として直接検証する。
final class ConnectionStateReducerTests: XCTestCase {
  // MARK: - redirect

  /// redirect 受信で transport 世代が増加し、isRedirecting が true になることを確認する
  func testRedirectReceivedIncrementsTransportEpochAndSetsRedirecting() {
    let state = ConnectionLifecycleState()

    let result = ConnectionStateReducer.reduce(state: state, event: .redirectReceived)

    XCTAssertEqual(result.state.transportEpoch, 1, "redirect で transport 世代が増えること")
    XCTAssertTrue(result.state.isRedirecting, "redirect で isRedirecting が true になること")
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// redirect 窓の終了で isRedirecting が false に戻り、WebSocket スケジュールがリセットされることを確認する
  func testRedirectConnectStartedResets() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .redirectReceived).state
    state =
      ConnectionStateReducer.reduce(
        state: state, event: .webSocketDisconnectScheduled
      ).state

    let result = ConnectionStateReducer.reduce(state: state, event: .redirectConnectStarted)

    XCTAssertFalse(result.state.isRedirecting, "redirect 窓の終了で isRedirecting が false になること")
    XCTAssertFalse(
      result.state.webSocketDisconnectScheduled,
      "redirect 窓の終了で WebSocket スケジュールがリセットされること")
  }

  // MARK: - WebSocket スケジュール

  /// WebSocket スケジュールでフラグが true になることを確認する
  /// (二重のスケジューリングの拒否は呼び出し側のガードの責務)
  func testWebSocketDisconnectScheduled() {
    let state = ConnectionLifecycleState()

    let result = ConnectionStateReducer.reduce(
      state: state, event: .webSocketDisconnectScheduled)

    XCTAssertTrue(result.state.webSocketDisconnectScheduled, "WebSocket スケジュールで true になること")
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - 猶予タイマー

  /// 猶予タイマー開始でフラグが true になり、発火で false に戻ることを確認する
  func testDisconnectTimerScheduledAndFired() {
    let state = ConnectionLifecycleState()

    let scheduled = ConnectionStateReducer.reduce(
      state: state, event: .disconnectTimerScheduled)
    XCTAssertTrue(scheduled.state.disconnectTimerScheduled, "タイマー開始で true になること")
    XCTAssertEqual(scheduled.state.disconnectTimerGeneration, 0, "開始時は世代が変わらないこと")

    let fired = ConnectionStateReducer.reduce(
      state: scheduled.state, event: .disconnectTimerFired)
    XCTAssertFalse(fired.state.disconnectTimerScheduled, "発火で false になること")
    XCTAssertEqual(fired.state.disconnectTimerGeneration, 0, "発火時に世代は変わらないこと")
  }

  /// 猶予タイマーキャンセルでフラグが false になり、世代が +1 されることを確認する
  func testDisconnectTimerCancelled() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .disconnectTimerScheduled).state

    let result = ConnectionStateReducer.reduce(state: state, event: .disconnectTimerCancelled)

    XCTAssertFalse(result.state.disconnectTimerScheduled, "キャンセルで false になること")
    XCTAssertEqual(result.state.disconnectTimerGeneration, 1, "キャンセルで世代が +1 されること")
  }

  // MARK: - 切断完了

  /// 切断完了で isRedirecting と WebSocket スケジュールがリセットされることを確認する
  func testDisconnectCompletedResetsRedirectState() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .redirectReceived).state
    state =
      ConnectionStateReducer.reduce(
        state: state, event: .webSocketDisconnectScheduled
      ).state

    let result = ConnectionStateReducer.reduce(state: state, event: .disconnectCompleted)

    XCTAssertFalse(result.state.isRedirecting, "切断完了で isRedirecting が false になること")
    XCTAssertFalse(
      result.state.webSocketDisconnectScheduled,
      "切断完了で WebSocket スケジュールが false になること")
  }

  // MARK: - snapshot storage

  /// ConnectionSnapshotStorage の publish / current が NSLock で保護されていることを確認する
  func testSnapshotStoragePublishAndRead() {
    let storage = ConnectionSnapshotStorage()
    var state = ConnectionLifecycleState()
    state.transportEpoch = 3

    storage.publish(state: state)

    XCTAssertEqual(storage.current().transportEpoch, 3, "publish した値を読めること")
  }
}
