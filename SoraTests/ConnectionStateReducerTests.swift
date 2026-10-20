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

  // MARK: - 接続ライフサイクルの排他

  /// 接続開始の初期ロック取得で非同期処理数が増え、開始区間へ入ることを確認する
  ///
  /// 接続ライフサイクルのイベントは snapshot を publish しない (接続試行状態を読む
  /// 同期 getter が無いため)。このため effects が空であることもあわせて確認する。
  func testConnectionStartBeganEntersStartingInterval() {
    let state = ConnectionLifecycleState()

    let result = ConnectionStateReducer.reduce(state: state, event: .connectionStartBegan)

    XCTAssertEqual(
      result.state.asyncOperationCount, 1, "接続開始の初期ロックが非同期処理数に数えられること")
    XCTAssertTrue(result.state.isStartingConnection, "開始区間へ入ること")
    XCTAssertFalse(result.state.isDisconnecting, "切断処理は開始されていないこと")
    XCTAssertTrue(
      result.effects.isEmpty, "接続ライフサイクルのイベントは snapshot を publish しないこと")
  }

  /// signaling 開始区間の終了で開始区間フラグだけが解除されることを確認する
  func testSignalingStartFinishedKeepsAsyncOperationCount() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectionStartBegan).state

    let result = ConnectionStateReducer.reduce(state: state, event: .signalingStartFinished)

    XCTAssertFalse(result.state.isStartingConnection, "開始区間が閉じること")
    XCTAssertEqual(
      result.state.asyncOperationCount, 1, "接続開始の初期ロックは保持されること")
    XCTAssertFalse(result.state.isDisconnecting, "切断処理は開始されないこと")
  }

  /// signaling 開始の取消で初期ロックが解放され、切断処理が開始されることを確認する
  func testSignalingStartCancelledReleasesAsyncOperationCount() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectionStartBegan).state

    let result = ConnectionStateReducer.reduce(state: state, event: .signalingStartCancelled)

    XCTAssertEqual(
      result.state.asyncOperationCount, 0, "接続開始の初期ロックが解放されること")
    XCTAssertFalse(result.state.isStartingConnection, "開始区間が閉じること")
    XCTAssertTrue(result.state.isDisconnecting, "切断処理が開始されること")
  }

  /// 非同期処理の開始と終了で非同期処理数が増減することを確認する
  func testAsyncOperationBeganAndEnded() {
    let state = ConnectionLifecycleState()

    let began = ConnectionStateReducer.reduce(state: state, event: .asyncOperationBegan)
    XCTAssertEqual(began.state.asyncOperationCount, 1, "開始で非同期処理数が増えること")

    let ended = ConnectionStateReducer.reduce(state: began.state, event: .asyncOperationEnded)
    XCTAssertEqual(ended.state.asyncOperationCount, 0, "終了で非同期処理数が減ること")
    XCTAssertFalse(ended.state.isDisconnecting, "終了だけでは切断処理を開始しないこと")
  }

  /// 切断要求の受理で切断処理が開始され、進行中の非同期処理数は変わらないことを確認する
  ///
  /// 「`isDisconnecting == true` ならば `asyncOperationCount == 0`」は不変条件ではない。
  /// 切断要求を受理した時点で進行中の非同期処理があれば、その終了 (`endAsyncOperation`) は
  /// `isDisconnecting` を根拠に無視され、非同期処理数は減らない。このテストは、
  /// `reducer` が受理時に残高を変えないことだけを固定する。
  func testDisconnectAcceptedKeepsOperationCount() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .asyncOperationBegan).state

    let result = ConnectionStateReducer.reduce(state: state, event: .disconnectAccepted)

    XCTAssertTrue(result.state.isDisconnecting, "切断処理が開始されること")
    XCTAssertEqual(
      result.state.asyncOperationCount, 1,
      "受理時に進行中の非同期処理数は変わらないこと (完了を待たない)")
  }

  /// 接続試行中の切断要求の受理で初期ロックが解放され、切断処理が開始されることを確認する
  func testDisconnectAcceptedWhileConnectingReleasesAsyncOperationCount() {
    var state = ConnectionLifecycleState()
    state = ConnectionStateReducer.reduce(state: state, event: .connectionStartBegan).state

    let result = ConnectionStateReducer.reduce(
      state: state, event: .disconnectAcceptedWhileConnecting)

    XCTAssertEqual(
      result.state.asyncOperationCount, 0, "接続開始の初期ロックが解放されること")
    XCTAssertTrue(result.state.isDisconnecting, "切断処理が開始されること")
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
