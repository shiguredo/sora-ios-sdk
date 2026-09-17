import XCTest

@testable import Sora

/// カメラ状態 reducer のユニットテスト
///
/// カメラの状態遷移は実カメラと接続タイミングに依存するため、E2E テストだけでは
/// 決定的に検証できない。reducer を純粋関数として直接検証し、phase の遷移と
/// 返される effect の内容、generation の照合を確認する。
/// 実カメラが必要な native 操作の検証は実機で行う。
final class CameraStateReducerTests: XCTestCase {
  // MARK: - ヘルパ

  /// テスト用の capturer ID を返す
  private func makeID() -> CameraCapturerID {
    CameraCapturerID()
  }

  /// 指定した capturer が動作中の状態を生成する
  private func makeRunningState(id: CameraCapturerID, generation: UInt64 = 1) -> CameraState {
    var state = CameraState()
    state.phase = .running
    state.activeCapturerID = id
    state.runningCapturers.insert(id)
    state.operationGeneration = generation
    return state
  }

  /// request 系 event を世代だけ変えて列挙する
  private func makeRequestEvents(
    id: CameraCapturerID, target: CameraCapturerID, generation: UInt64
  ) -> [CameraEvent] {
    [
      .startRequested(id: id, generation: generation),
      .stopRequested(id: id, generation: generation),
      .restartRequested(id: id, generation: generation),
      .changeRequested(id: id, generation: generation),
      .flipRequested(sourceID: id, targetID: target, generation: generation),
    ]
  }

  // MARK: - 開始

  /// 開始要求で phase が starting になり、 active は開始成功まで設定されないことを確認する
  func testStartRequestedMovesToStarting() {
    let id = makeID()

    let result = CameraStateReducer.reduce(
      state: CameraState(),
      event: .startRequested(id: id, generation: 1))

    XCTAssertEqual(result.state.phase, .starting, "開始要求で phase が starting になること")
    XCTAssertNil(
      result.state.activeCapturerID,
      "開始要求では active を設定しないこと (開始に失敗した camera を current にしない)")
    XCTAssertEqual(result.state.operationGeneration, 1, "開始要求で世代が記録されること")
    XCTAssertEqual(result.effects, [.publishSnapshot], "snapshot を publish すること")
  }

  /// format 解決でフレームレートが記録されることを確認する
  func testFormatResolvedRecordsFrameRate() {
    let id = makeID()
    let state = CameraStateReducer.reduce(
      state: CameraState(),
      event: .startRequested(id: id, generation: 1)
    ).state

    let result = CameraStateReducer.reduce(
      state: state,
      event: .formatResolved(id: id, frameRate: 30, generation: 1))

    XCTAssertEqual(result.state.frameRates[id], 30, "フレームレートが記録されること")
    XCTAssertEqual(result.effects, [.publishSnapshot], "snapshot を publish すること")
  }

  /// 古い generation の format 解決が破棄されることを確認する
  func testStaleFormatResolvedIsIgnored() {
    let id = makeID()
    let state = CameraStateReducer.reduce(
      state: CameraState(),
      event: .startRequested(id: id, generation: 2)
    ).state

    let result = CameraStateReducer.reduce(
      state: state,
      event: .formatResolved(id: id, frameRate: 30, generation: 1))

    XCTAssertTrue(result.state.frameRates.isEmpty, "古い世代の format は記録されないこと")
    XCTAssertTrue(result.effects.isEmpty, "古い世代のイベントは effect を返さないこと")
  }

  /// request 系 event が等値の世代を受け付けることを確認する
  ///
  /// 本番は `CameraStateOwner.nextGeneration()` が state の世代を先に進めてから
  /// その値で request を適用するため、等値の世代が唯一の正常経路になる。
  func testRequestEventsAcceptEqualGeneration() {
    let id = makeID()
    let target = makeID()

    for event in makeRequestEvents(id: id, target: target, generation: 5) {
      let state = makeRunningState(id: id, generation: 5)

      let result = CameraStateReducer.reduce(state: state, event: event)

      XCTAssertEqual(result.state.operationGeneration, 5, "等値の世代を受け付けること")
      XCTAssertNotEqual(result.state.phase, .running, "等値の世代で phase が進むこと")
      XCTAssertEqual(result.effects, [.publishSnapshot], "snapshot を publish すること")
    }
  }

  /// request 系 event が新しい世代を受け付け、世代を進めることを確認する
  func testRequestEventsAcceptNewerGeneration() {
    let id = makeID()
    let target = makeID()

    for event in makeRequestEvents(id: id, target: target, generation: 6) {
      let state = makeRunningState(id: id, generation: 5)

      let result = CameraStateReducer.reduce(state: state, event: event)

      XCTAssertEqual(result.state.operationGeneration, 6, "新しい世代で世代が進むこと")
      XCTAssertNotEqual(result.state.phase, .running, "新しい世代で phase が進むこと")
    }
  }

  /// request 系 event が古い世代を破棄し、隔離を解除しないことを確認する
  func testRequestEventsIgnoreStaleGeneration() {
    let id = makeID()
    let target = makeID()

    for event in makeRequestEvents(id: id, target: target, generation: 5) {
      var state = CameraState()
      state.phase = .quarantined
      state.activeCapturerID = id
      state.runningCapturers.insert(id)
      state.operationGeneration = 6

      let result = CameraStateReducer.reduce(state: state, event: event)

      XCTAssertEqual(result.state.phase, .quarantined, "古い世代の要求で隔離を解除しないこと")
      XCTAssertEqual(result.state.operationGeneration, 6, "古い世代の要求で世代を巻き戻さないこと")
      XCTAssertTrue(result.effects.isEmpty, "古い世代のイベントは effect を返さないこと")
    }
  }

  /// 開始成功で phase が running になり、 active と動作状態が確定することを確認する
  func testStartCompletedSuccessMovesToRunning() {
    let id = makeID()
    let state = CameraStateReducer.reduce(
      state: CameraState(),
      event: .startRequested(id: id, generation: 1)
    ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .startCompleted(id: id, generation: 1, success: true))

    XCTAssertEqual(result.state.phase, .running, "開始成功で phase が running になること")
    XCTAssertEqual(result.state.activeCapturerID, id, "開始成功で active が設定されること")
    XCTAssertTrue(result.state.runningCapturers.contains(id), "動作中に記録されること")
  }

  /// 開始失敗で phase が idle に戻り、 active が設定されないことを確認する
  func testStartCompletedFailureReturnsToIdle() {
    let id = makeID()
    let state = CameraStateReducer.reduce(
      state: CameraState(),
      event: .startRequested(id: id, generation: 1)
    ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .startCompleted(id: id, generation: 1, success: false))

    XCTAssertEqual(result.state.phase, .idle, "開始失敗で phase が idle になること")
    XCTAssertNil(result.state.activeCapturerID, "開始失敗で active が設定されないこと")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "動作中に残らないこと")
  }

  // MARK: - 停止

  /// 停止要求で phase が stopping になり、 active は停止完了まで維持されることを確認する
  func testStopRequestedMovesToStopping() {
    let id = makeID()
    let state = makeRunningState(id: id)

    let result = CameraStateReducer.reduce(
      state: state, event: .stopRequested(id: id, generation: 2))

    XCTAssertEqual(result.state.phase, .stopping, "停止要求で phase が stopping になること")
    XCTAssertEqual(
      result.state.activeCapturerID, id, "停止要求では active を解除しないこと (停止完了で解除する)")
    XCTAssertEqual(result.state.operationGeneration, 2, "停止要求で世代が記録されること")
  }

  /// 停止完了で phase が idle に戻り、 active が解除されることを確認する
  func testStopCompletedReturnsToIdle() {
    let id = makeID()
    var state = makeRunningState(id: id)
    state.phase = .stopping
    state.operationGeneration = 2

    let result = CameraStateReducer.reduce(
      state: state, event: .stopCompleted(id: id, generation: 2))

    XCTAssertEqual(result.state.phase, .idle, "停止完了で phase が idle になること")
    XCTAssertNil(result.state.activeCapturerID, "停止完了で active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "動作中から外れること")
  }

  // MARK: - 再起動 / 設定変更

  /// 再起動の要求では内部 stop の完了まで active を維持することを確認する
  func testRestartRequestedKeepsRunningUntilInternalStop() {
    let id = makeID()
    let state = makeRunningState(id: id)

    let result = CameraStateReducer.reduce(
      state: state, event: .restartRequested(id: id, generation: 3))

    XCTAssertEqual(result.state.phase, .stopping, "再起動要求で phase が stopping になること")
    XCTAssertEqual(
      result.state.activeCapturerID, id, "内部 stop の完了までは active を維持すること")
    XCTAssertTrue(
      result.state.runningCapturers.contains(id), "内部 stop の完了までは動作中であること")
  }

  /// 再起動の内部 stop 完了で active と動作状態が解除されることを確認する
  func testStopCompletedDuringRestartReleasesCapturer() {
    let id = makeID()
    var state = makeRunningState(id: id)
    state =
      CameraStateReducer.reduce(
        state: state, event: .restartRequested(id: id, generation: 3)
      ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .stopCompleted(id: id, generation: 3))

    XCTAssertEqual(result.state.phase, .idle, "内部 stop 完了で phase が idle になること")
    XCTAssertNil(result.state.activeCapturerID, "内部 stop 完了で active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "動作中から外れること")
  }

  /// 停止済みの状態からの再起動成功で active が復元されることを確認する
  ///
  /// ハードミュート解除の経路では、停止済み (active が nil) の capturer を restart する。
  /// 成功時に active を復元しないと isRunning と current が食い違い、以降の停止や
  /// 所有判定が失敗する。
  func testRestartCompletedSuccessRestoresActiveCapturer() {
    let id = makeID()
    var state = CameraState()
    state.phase = .idle
    state.operationGeneration = 3

    let result = CameraStateReducer.reduce(
      state: state, event: .restartCompleted(id: id, generation: 3, success: true))

    XCTAssertEqual(result.state.phase, .running, "再起動成功で running になること")
    XCTAssertEqual(result.state.activeCapturerID, id, "停止済みからの再起動成功で active が復元されること")
    XCTAssertTrue(result.state.runningCapturers.contains(id), "動作中に記録されること")
  }

  /// 再起動の内部 stop 成功後に start が失敗すると idle に落ちることを確認する
  func testRestartCompletedFailureReturnsToIdle() {
    let id = makeID()
    var state = makeRunningState(id: id)
    state =
      CameraStateReducer.reduce(
        state: state, event: .restartRequested(id: id, generation: 3)
      ).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: id, generation: 3)
      ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .restartCompleted(id: id, generation: 3, success: false))

    XCTAssertEqual(result.state.phase, .idle, "再起動失敗で phase が idle になること")
    XCTAssertNil(result.state.activeCapturerID, "active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "動作中から外れること")
  }

  /// 設定変更の要求では内部 stop の完了まで active を維持することを確認する
  func testChangeRequestedKeepsRunningUntilInternalStop() {
    let id = makeID()
    let state = makeRunningState(id: id)

    let result = CameraStateReducer.reduce(
      state: state, event: .changeRequested(id: id, generation: 4))

    XCTAssertEqual(result.state.phase, .stopping, "設定変更要求で phase が stopping になること")
    XCTAssertEqual(
      result.state.activeCapturerID, id, "内部 stop の完了までは active を維持すること")
  }

  /// 設定変更成功で active が設定されることを確認する
  func testChangeCompletedSuccessSetsActiveCapturer() {
    let id = makeID()
    var state = makeRunningState(id: id)
    state =
      CameraStateReducer.reduce(
        state: state, event: .changeRequested(id: id, generation: 4)
      ).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: id, generation: 4)
      ).state
    XCTAssertNil(state.activeCapturerID, "設定変更の内部 stop で active が解除されること")

    let result = CameraStateReducer.reduce(
      state: state, event: .changeCompleted(id: id, generation: 4, success: true))

    XCTAssertEqual(result.state.phase, .running, "設定変更成功で running になること")
    XCTAssertEqual(result.state.activeCapturerID, id, "設定変更成功で active が設定されること")
    XCTAssertTrue(result.state.runningCapturers.contains(id), "動作中に記録されること")
  }

  /// 設定変更の内部 stop 成功後に start が失敗すると idle に落ちることを確認する
  func testChangeCompletedFailureReturnsToIdle() {
    let id = makeID()
    var state = makeRunningState(id: id)
    state =
      CameraStateReducer.reduce(
        state: state, event: .changeRequested(id: id, generation: 4)
      ).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: id, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .changeCompleted(id: id, generation: 4, success: false))

    XCTAssertEqual(result.state.phase, .idle, "設定変更失敗で phase が idle になること")
    XCTAssertNil(result.state.activeCapturerID, "active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "動作中から外れること")
    XCTAssertEqual(result.effects, [.publishSnapshot], "snapshot を publish すること")
  }

  // MARK: - 切り替え

  /// 切り替え要求で flip 中フラグが立ち、内部 stop の完了まで active を維持することを確認する
  func testFlipRequestedSetsFlippingFlag() {
    let source = makeID()
    let target = makeID()
    let state = makeRunningState(id: source)

    let result = CameraStateReducer.reduce(
      state: state,
      event: .flipRequested(sourceID: source, targetID: target, generation: 4))

    XCTAssertEqual(result.state.phase, .flipping, "切り替え要求で phase が flipping になること")
    XCTAssertTrue(result.state.isFlipping, "切り替え中フラグが立つこと")
    XCTAssertEqual(
      result.state.activeCapturerID, source, "内部 stop の完了までは切り替え元が active であること")
  }

  /// 切り替えの内部 stop 完了で切り替え元が解除されることを確認する
  func testStopCompletedDuringFlipReleasesSource() {
    let source = makeID()
    let target = makeID()
    var state = makeRunningState(id: source)
    state =
      CameraStateReducer.reduce(
        state: state,
        event: .flipRequested(sourceID: source, targetID: target, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(
      state: state, event: .stopCompleted(id: source, generation: 4))

    XCTAssertNil(result.state.activeCapturerID, "内部 stop 完了で active が解除されること")
    XCTAssertFalse(
      result.state.runningCapturers.contains(source), "切り替え元が動作中から外れること")
    XCTAssertTrue(result.state.isFlipping, "切り替え中フラグは完了まで維持されること")
  }

  /// 切り替え成功で active が切り替え先へ移ることを確認する
  func testFlipCompletedSuccessMovesActiveToTarget() {
    let source = makeID()
    let target = makeID()
    var state = makeRunningState(id: source)
    state =
      CameraStateReducer.reduce(
        state: state,
        event: .flipRequested(sourceID: source, targetID: target, generation: 4)
      ).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: source, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(
      state: state,
      event: .flipCompleted(sourceID: source, targetID: target, generation: 4, success: true))

    XCTAssertEqual(result.state.activeCapturerID, target, "active が切り替え先へ移ること")
    XCTAssertTrue(result.state.runningCapturers.contains(target), "切り替え先が動作中になること")
    XCTAssertFalse(result.state.runningCapturers.contains(source), "切り替え元が動作中から外れること")
    XCTAssertEqual(result.state.phase, .running, "切り替え成功で running になること")
    XCTAssertFalse(result.state.isFlipping, "切り替え中フラグが解除されること")
  }

  /// 切り替え失敗で切り替え元も切り替え先も停止することを確認する
  func testFlipCompletedFailureLeavesCameraIdle() {
    let source = makeID()
    let target = makeID()
    var state = makeRunningState(id: source)
    state =
      CameraStateReducer.reduce(
        state: state,
        event: .flipRequested(sourceID: source, targetID: target, generation: 4)
      ).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: source, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(
      state: state,
      event: .flipCompleted(sourceID: source, targetID: target, generation: 4, success: false))

    XCTAssertEqual(result.state.phase, .idle, "切り替え失敗で idle になること")
    XCTAssertNil(result.state.activeCapturerID, "active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(source), "切り替え元が停止すること")
    XCTAssertFalse(result.state.runningCapturers.contains(target), "切り替え先が停止すること")
    XCTAssertFalse(result.state.isFlipping, "切り替え中フラグが解除されること")
  }

  /// 古い generation の切り替え完了が破棄されることを確認する
  func testStaleFlipCompletedIsIgnored() {
    let source = makeID()
    let target = makeID()
    var state = makeRunningState(id: source)
    state =
      CameraStateReducer.reduce(
        state: state,
        event: .flipRequested(sourceID: source, targetID: target, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(
      state: state,
      event: .flipCompleted(sourceID: source, targetID: target, generation: 3, success: true))

    XCTAssertEqual(result.state.activeCapturerID, source, "古い世代では active が変わらないこと")
    XCTAssertEqual(result.state.phase, .flipping, "古い世代では phase が変わらないこと")
    XCTAssertTrue(result.state.isFlipping, "古い世代では切り替え中フラグが変わらないこと")
    XCTAssertTrue(result.effects.isEmpty, "古い世代のイベントは effect を返さないこと")
  }

  // MARK: - 隔離

  /// 隔離で世代が進み、切り替え中フラグが解除されることを確認する
  func testQuarantinedAdvancesGenerationAndClearsFlipping() {
    let source = makeID()
    let target = makeID()
    var state = makeRunningState(id: source)
    state =
      CameraStateReducer.reduce(
        state: state,
        event: .flipRequested(sourceID: source, targetID: target, generation: 4)
      ).state

    let result = CameraStateReducer.reduce(state: state, event: .quarantined)

    XCTAssertEqual(result.state.phase, .quarantined, "隔離で phase が quarantined になること")
    XCTAssertEqual(result.state.operationGeneration, 5, "隔離で世代が進むこと")
    XCTAssertFalse(result.state.isFlipping, "隔離で切り替え中フラグが解除されること")
  }

  /// 隔離しても active と動作状態を解除しないことを確認する
  ///
  /// 隔離の解除は「停止成功を確認する」経路しかないため、`stop()` の
  /// `CameraVideoCapturer.current === self` が成立するよう active を残す必要がある。
  /// ここで active を消すと `isAvailable` が false のまま二度と停止できず、隔離が恒久化する。
  func testQuarantinedKeepsActiveCapturerUntilStopped() {
    let id = makeID()
    let state = makeRunningState(id: id, generation: 5)

    let result = CameraStateReducer.reduce(state: state, event: .quarantined)

    XCTAssertEqual(result.state.phase, .quarantined, "隔離で phase が quarantined になること")
    XCTAssertEqual(
      result.state.activeCapturerID, id, "隔離しても active を残すこと (停止による回復のため)")
    XCTAssertTrue(
      result.state.runningCapturers.contains(id), "隔離しても動作状態を残すこと (停止による回復のため)")
  }

  /// 隔離後に停止を行って idle へ戻れることを確認する
  ///
  /// 隔離を抜けるのは停止要求 (phase が `.stopping` になり `isAvailable` が真に戻る) であり、
  /// その後の停止完了がまま active / running を解除する。隔離中は coordinator が
  /// 直列化するため、停止要求の後に別の start が割り込むことはない。
  func testQuarantineRecoverySequence() {
    let id = makeID()
    var state = makeRunningState(id: id, generation: 5)
    // 隔離で世代が 5 から 6 に進む
    state = CameraStateReducer.reduce(state: state, event: .quarantined).state

    state =
      CameraStateReducer.reduce(
        state: state, event: .stopRequested(id: id, generation: 7)
      ).state
    XCTAssertEqual(state.phase, .stopping, "停止要求で隔離を抜けること")

    let result = CameraStateReducer.reduce(
      state: state, event: .stopCompleted(id: id, generation: 7))

    XCTAssertEqual(result.state.phase, .idle, "停止完了で idle に戻ること")
    XCTAssertNil(result.state.activeCapturerID, "停止完了で active が解除されること")
    XCTAssertFalse(result.state.runningCapturers.contains(id), "停止完了で動作中から外れること")
  }

  /// 隔離解除だけでは active / running が残ることを確認する
  ///
  /// 隔離中の遅延 callback が破棄されると停止完了が届かないため、`.quarantineCleared` で
  /// phase だけが idle に戻り、active は次の停止で解除される。
  func testQuarantineClearedAfterStaleStopKeepsActiveUntilNextStop() {
    let id = makeID()
    var state = makeRunningState(id: id, generation: 6)
    state.phase = .stopping
    // 隔離で世代が 6 から 7 に進み、停止完了 (世代 6) が破棄される
    state = CameraStateReducer.reduce(state: state, event: .quarantined).state
    state =
      CameraStateReducer.reduce(
        state: state, event: .stopCompleted(id: id, generation: 6)
      ).state

    state = CameraStateReducer.reduce(state: state, event: .quarantineCleared).state

    XCTAssertEqual(state.phase, .idle, "隔離解除で idle に戻ること")
    XCTAssertEqual(state.activeCapturerID, id, "停止前は active を残すこと")
    XCTAssertTrue(state.runningCapturers.contains(id), "停止前は動作状態を残すこと")

    let result = CameraStateReducer.reduce(
      state: state, event: .stopRequested(id: id, generation: 8))

    XCTAssertEqual(result.state.phase, .stopping, "改めて停止できること")
  }

  /// 未隔離で隔離解除イベントを受けても進行中の phase を壊さないことを確認する
  func testQuarantineClearedKeepsRunningPhase() {
    let id = makeID()
    let state = makeRunningState(id: id, generation: 5)

    let result = CameraStateReducer.reduce(state: state, event: .quarantineCleared)

    XCTAssertEqual(result.state.phase, .running, "未隔離では phase を変えないこと")
    XCTAssertEqual(result.state.activeCapturerID, id, "未隔離では active を変えないこと")
  }

  /// 隔離していない状態で隔離解除イベントを受けても進行中の phase を壊さないことを確認する
  ///
  /// `stop()` の完了通知は隔離の有無にかかわらず `.quarantineCleared` を送るため、
  /// 開始中 / 切り替え中の phase を `.idle` へ書き戻さないことが必要になる。
  func testQuarantineClearedKeepsInProgressPhases() {
    let id = makeID()
    let target = makeID()
    let events: [(String, CameraEvent)] = [
      ("開始中", .startRequested(id: id, generation: 5)),
      ("切り替え中", .flipRequested(sourceID: id, targetID: target, generation: 5)),
    ]

    for (name, request) in events {
      var state = makeRunningState(id: id, generation: 5)
      state = CameraStateReducer.reduce(state: state, event: request).state
      let phaseBeforeClear = state.phase

      let result = CameraStateReducer.reduce(state: state, event: .quarantineCleared)

      XCTAssertEqual(result.state.phase, phaseBeforeClear, "\(name)の phase を変えないこと")
    }
  }

  /// capturer の解放で対象 ID のフレームレートだけを破棄することを確認する
  ///
  /// 解放された instance が active / 動作中であることはない (owner の強参照が保つ) ため、
  /// 他の capturer の状態を壊さないことが要点になる。
  func testCapturerReleasedDiscardsOnlyTargetFrameRate() {
    let released = makeID()
    let other = makeID()
    var state = CameraState()
    state.phase = .running
    state.activeCapturerID = other
    state.runningCapturers.insert(other)
    state.frameRates[released] = 30
    state.frameRates[other] = 60

    let result = CameraStateReducer.reduce(state: state, event: .capturerReleased(id: released))

    XCTAssertNil(result.state.frameRates[released], "解放した capturer のフレームレートを破棄すること")
    XCTAssertEqual(result.state.frameRates[other], 60, "他の capturer の状態を壊さないこと")
    XCTAssertEqual(result.state.activeCapturerID, other, "active を変えないこと")
    XCTAssertEqual(result.state.phase, .running, "phase を変えないこと")
  }

  /// 停止済みの capturer の解放でフレームレートが破棄されることを確認する
  ///
  /// 停止後も `frameRates` は残るため、これが解放時に届く実際の状態になる。
  func testCapturerReleasedOnStoppedCapturerClearsFrameRate() {
    let id = makeID()
    var state = CameraState()
    state.frameRates[id] = 30

    let result = CameraStateReducer.reduce(state: state, event: .capturerReleased(id: id))

    XCTAssertNil(result.state.frameRates[id], "停止済みでもフレームレートを破棄すること")
    XCTAssertEqual(result.state.phase, .idle, "phase を変えないこと")
    XCTAssertTrue(result.state.runningCapturers.isEmpty, "動作中の capturer を作らないこと")
  }

  /// 隔離後に到着した古い停止完了が隔離を解除しないことを確認する
  ///
  /// 世代を進めない場合、隔離前に開始された停止の完了が guard を通過して
  /// phase を idle へ書き戻し、隔離が解除されてしまう。
  func testStaleStopCompletedAfterQuarantineIsIgnored() {
    let id = makeID()
    var state = makeRunningState(id: id, generation: 6)
    state.phase = .stopping

    // 停止の完了前に隔離が発生する
    let quarantined = CameraStateReducer.reduce(state: state, event: .quarantined).state

    XCTAssertEqual(quarantined.phase, .quarantined, "隔離で phase が quarantined になること")
    XCTAssertEqual(quarantined.operationGeneration, 7, "隔離で世代が進むこと")

    // 隔離前に開始された停止の完了が遅れて到着する
    let result = CameraStateReducer.reduce(
      state: quarantined, event: .stopCompleted(id: id, generation: 6))

    XCTAssertEqual(result.state.phase, .quarantined, "隔離後に古い停止完了が届いても隔離が維持されること")
    XCTAssertEqual(result.state.operationGeneration, 7, "古い完了では世代が変わらないこと")
    XCTAssertTrue(result.effects.isEmpty, "古い世代のイベントは effect を返さないこと")
  }

  /// 隔離の解除で idle に戻ることを確認する
  func testQuarantineClearedReturnsToIdle() {
    var state = CameraState()
    state.phase = .quarantined

    let result = CameraStateReducer.reduce(state: state, event: .quarantineCleared)

    XCTAssertEqual(result.state.phase, .idle, "隔離解除で idle に戻ること")
  }
}
