import XCTest

@testable import Sora

/// ConnectionStateOwner の接続ライフサイクルの排他に関するユニットテスト
///
/// 旧 `PeerChannel.Lock` から移した分岐 (接続開始の初期ロック、signaling 開始区間の
/// 扱い、非同期処理数の増減、遅延させる切断要求、猶予タイマー由来の取り消し) を、
/// モックやスタブを使わず実 `ConnectionStateOwner` の同期 API だけで検証する。
/// 実 `PeerChannel` を介した経路は `PeerChannelConnectCompletionTests` が担当する。
final class ConnectionStateOwnerTests: XCTestCase {
  /// テストごとに独立した owner を生成する
  ///
  /// 切断クリーンアップのタイムアウトを検証するテストでは 1 秒など短い値を渡す。
  private func makeOwner(disconnectCleanupTimeout: Int = 30) -> ConnectionStateOwner {
    ConnectionStateOwner(
      snapshotStorage: ConnectionSnapshotStorage(),
      disconnectCleanupTimeout: disconnectCleanupTimeout)
  }

  /// 猶予タイマー由来の切断要求を取り消すかの判定
  ///
  /// `PeerChannel.shouldCancelDisconnectTimerBasedDisconnect` と同じ判定を、
  /// 接続状態を引数で与えて再現する。`.disconnected` のままなら切断を継続し、
  /// 接続が回復していれば取り消す。テストから両方の結果を作るために使う。
  private func isCancelledByRecovery(
    reason: DisconnectReason,
    connectionState: PeerChannelConnectionState
  ) -> Bool {
    reason == .peerConnectionStateDisconnected
      && connectionState != .disconnected
      && connectionState != .failed
  }

  // MARK: - 接続開始の初期ロック

  /// 初期ロックの取得で非同期処理数が増え、2 重取得と切断後の取得が拒否されることを確認する
  func testBeginConnectionStartAcquiresAndReleasesInitialLock() {
    let owner = makeOwner()

    XCTAssertTrue(owner.beginConnectionStart(), "初期ロックを取得できること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 1, "初期ロックが数えられること")
    XCTAssertTrue(owner.stateForTesting().isStartingConnection, "開始区間へ入ること")
    XCTAssertFalse(owner.beginConnectionStart(), "開始区間中の 2 重取得は拒否されること")

    // endAsyncOperation は保存された切断要求だけを返す。要求が無いここでは nil になる
    XCTAssertNil(
      owner.endAsyncOperation { _ in false },
      "初期ロックの終了では切断要求を取り出さないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "初期ロックが解放されること")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理は開始されないこと")
  }

  /// 非同期処理の開始と終了で残高が増減することを確認する
  func testBeginAndEndAsyncOperationAdjustsCount() {
    let owner = makeOwner()

    XCTAssertTrue(owner.beginAsyncOperation(), "非同期処理を開始できること")
    XCTAssertTrue(owner.beginAsyncOperation(), "重ねて開始できること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 2, "残高が 2 になること")

    // 保存された切断要求は無いため、1 件目と 2 件目のどちらの終了でも nil が返る
    XCTAssertNil(
      owner.endAsyncOperation { _ in false },
      "1 件目の終了では切断要求を取り出さないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 1, "1 件目の終了で 1 になること")

    XCTAssertNil(
      owner.endAsyncOperation { _ in false },
      "2 件目の終了では切断要求を取り出さないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "2 件目の終了で 0 になること")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "終了だけでは切断処理を開始しないこと")
  }

  /// 切断処理の開始後は新しい非同期処理を開始できないことを確認する
  func testBeginAsyncOperationIsRejectedAfterDisconnectAccepted() {
    let owner = makeOwner()

    XCTAssertNotNil(
      owner.requestDisconnect(
        error: nil,
        reason: .user,
        shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
        isConnectHandlerHeld: { false }),
      "非同期処理が無い場合は即時実行の要求を返すこと")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")

    XCTAssertFalse(owner.beginAsyncOperation(), "切断処理の開始後は開始できないこと")
    XCTAssertFalse(owner.beginConnectionStart(), "切断処理の開始後は初期ロックも取得できないこと")
  }

  /// 接続状態フラグを変えるイベントだけが snapshot を publish することを確認する
  ///
  /// 接続試行状態 (asyncOperationCount / isDisconnecting / isStartingConnection) を
  /// 読む同期 getter は無いため、接続ライフサイクルのイベントは snapshot を更新しない。
  func testLifecycleEventsDoNotPublishSnapshot() {
    let storage = ConnectionSnapshotStorage()
    let owner = ConnectionStateOwner(snapshotStorage: storage, disconnectCleanupTimeout: 30)

    owner.beginConnectionStart()
    owner.beginAsyncOperation()
    XCTAssertEqual(
      storage.current().asyncOperationCount,
      0,
      "接続ライフサイクルのイベントでは snapshot を更新しないこと")

    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    XCTAssertFalse(storage.current().isDisconnecting, "切断受理でも snapshot を更新しないこと")

    owner.handle(.disconnectTimerScheduled)
    XCTAssertTrue(
      storage.current().disconnectTimerScheduled,
      "接続状態フラグのイベントは snapshot を更新すること")

    let generationBefore = storage.current().disconnectCleanupTimerGeneration
    owner.handle(.disconnectCleanupTimerGenerationAdvanced)
    XCTAssertEqual(
      storage.current().disconnectCleanupTimerGeneration,
      generationBefore,
      "切断クリーンアップタイマーの世代は snapshot を更新しないこと")
  }

  // MARK: - signaling 開始区間

  /// 切断要求が保存されていない場合は signaling の開始を許可することを確認する
  func testPrepareSignalingStartAllowsStartWithoutPendingDisconnect() {
    let owner = makeOwner()
    owner.beginConnectionStart()

    let decision = owner.prepareSignalingStart { _ in false }

    guard case .start = decision else {
      XCTFail("保存された切断要求が無い場合は開始を許可すること")
      return
    }
  }

  /// 切断処理が開始済みの場合は何もしないことを確認する
  func testPrepareSignalingStartIsIgnoredAfterDisconnectAccepted() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    // 開始区間を閉じたうえで、接続開始の初期ロックのみが残っている状態にする。
    _ = owner.finishSignalingStart { _ in false }
    // 接続完了 callback を保持しているため、初期ロックが強制解放されて切断処理が開始される。
    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { true })
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されていること")

    let decision = owner.prepareSignalingStart { _ in false }

    guard case .ignored = decision else {
      XCTFail("切断処理の開始後は開始を許可しないこと")
      return
    }
  }

  /// 開始前の切断要求が接続の回復で取り消された場合は開始を許可することを確認する
  func testPrepareSignalingStartCancelsRecoveredPendingDisconnect() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    _ = owner.requestDisconnect(
      error: nil,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    let decision = owner.prepareSignalingStart {
      self.isCancelledByRecovery(reason: $0, connectionState: .connected)
    }

    guard case .start = decision else {
      XCTFail("接続が回復している場合は開始を許可すること")
      return
    }
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理は開始されないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 1, "初期ロックは保持されること")
  }

  /// 開始前の切断要求を実行する場合は初期ロックを解放して要求を返すことを確認する
  func testPrepareSignalingStartRunsPendingDisconnect() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    let error = SoraError.connectionCancelled
    _ = owner.requestDisconnect(
      error: error,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    let decision = owner.prepareSignalingStart {
      self.isCancelledByRecovery(reason: $0, connectionState: .disconnected)
    }

    guard case .disconnect(let pending) = decision else {
      XCTFail("接続が回復していない場合は切断要求を実行すること")
      return
    }
    XCTAssertEqual(pending.reason, .peerConnectionStateDisconnected, "理由が引き継がれること")
    XCTAssertEqual(
      (pending.error as? SoraError)?.localizedDescription,
      error.localizedDescription,
      "エラーが引き継がれること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "初期ロックが解放されること")
    XCTAssertFalse(owner.stateForTesting().isStartingConnection, "開始区間が閉じること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")
  }

  /// 開始区間の終了が常に反映され、保存された切断要求を返すことを確認する
  func testFinishSignalingStartClosesIntervalAndReturnsPendingDisconnect() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    let error = SoraError.connectionCancelled
    _ = owner.requestDisconnect(
      error: error,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    XCTAssertTrue(owner.stateForTesting().isStartingConnection, "開始区間が開いていること")

    let pending = owner.finishSignalingStart { _ in false }

    XCTAssertEqual(pending?.reason, .signalingFailure, "保存された切断要求を返すこと")
    XCTAssertFalse(owner.stateForTesting().isStartingConnection, "開始区間が閉じること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "初期ロックが解放されること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")
  }

  /// 開始区間の終了は、切断処理が開始済みでも反映されることを確認する
  func testFinishSignalingStartIsReflectedAfterDisconnectAccepted() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    // 開始区間を閉じたうえで、接続開始の初期ロックのみが残っている状態にする。
    _ = owner.finishSignalingStart { _ in false }
    // 接続完了 callback を保持しているため、初期ロックが強制解放されて切断処理が開始される。
    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { true })
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されていること")

    let pending = owner.finishSignalingStart { _ in false }

    XCTAssertNil(pending, "切断処理の開始後は何も返さないこと")
    XCTAssertFalse(owner.stateForTesting().isStartingConnection, "開始区間は閉じること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理の開始は変わらないこと")
  }

  // MARK: - 切断要求の受理

  /// 非同期処理が進行中の切断要求を保存し、その終了時に実行することを確認する
  func testRequestDisconnectDefersUntilOperationEnds() {
    let owner = makeOwner()
    owner.beginAsyncOperation()

    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    XCTAssertNil(immediate, "進行中の非同期処理がある間は実行しないこと")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理はまだ開始されないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 1, "残高は変わらないこと")

    let pending = owner.endAsyncOperation { _ in false }

    XCTAssertEqual(pending?.reason, .user, "非同期処理の終了時に関数を返すこと")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")
  }

  /// 保存済みの切断要求が後から届いた要求で上書きされることを確認する
  func testRequestDisconnectOverwritesDeferredRequest() {
    let owner = makeOwner()
    // 接続開始の初期ロックと非同期処理 1 件の 2 件を進行中にする。
    // 開始区間を閉じておかないと、切断要求が保存されず開始前の要求として扱われる。
    owner.beginConnectionStart()
    _ = owner.finishSignalingStart { _ in false }
    owner.beginAsyncOperation()

    _ = owner.requestDisconnect(
      error: SoraError.connectionCancelled,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let overwritingError = SoraError.peerChannelError(reason: "overwriting")
    _ = owner.requestDisconnect(
      error: overwritingError,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    // 1 件目の終了で残高が 1 になり、保存された要求が実行対象として取り出される。
    let pending = owner.endAsyncOperation { _ in false }

    XCTAssertEqual(pending?.reason, .signalingFailure, "最後の切断要求が実行されること")
    XCTAssertEqual(
      (pending?.error as? SoraError)?.localizedDescription,
      overwritingError.localizedDescription,
      "最後の切断要求のエラーが実行されること")
  }

  /// 接続試行中の切断要求が初期ロックを解放して即時実行されることを確認する
  func testRequestDisconnectWhileConnectingReleasesInitialLock() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    // 開始区間を閉じる。閉じたままだと、切断要求は開始前の要求として保存される。
    _ = owner.finishSignalingStart { _ in false }

    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { true })

    XCTAssertEqual(immediate?.reason, .signalingFailure, "接続試行中は即時実行すること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "初期ロックが解放されること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")
  }

  /// 接続完了 callback を保持していなければ接続試行中と見なさないことを確認する
  func testRequestDisconnectWhileConnectingRequiresConnectHandler() {
    let owner = makeOwner()
    owner.beginConnectionStart()
    // 開始区間を閉じる。接続完了 callback を保持していない場合は保存されることを確認する。
    _ = owner.finishSignalingStart { _ in false }

    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    XCTAssertNil(immediate, "接続完了 callback が無い場合は保存すること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 1, "初期ロックは保持されること")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理は開始されないこと")
  }

  /// 猶予タイマー由来の切断要求が接続の回復で取り消されることを確認する
  func testRequestDisconnectCancelsRecoveredTimerDisconnect() {
    let owner = makeOwner()

    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: {
        self.isCancelledByRecovery(reason: $0, connectionState: .connected)
      },
      isConnectHandlerHeld: { false })

    XCTAssertNil(immediate, "接続が回復している場合は切断しないこと")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理は開始されないこと")
  }

  /// 猶予タイマー由来の切断要求が `.disconnected` のままなら実行されることを確認する
  func testRequestDisconnectRunsTimerDisconnectWhileDisconnected() {
    let owner = makeOwner()

    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: {
        self.isCancelledByRecovery(reason: $0, connectionState: .disconnected)
      },
      isConnectHandlerHeld: { false })

    XCTAssertEqual(immediate?.reason, .peerConnectionStateDisconnected, "切断を実行すること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されること")
  }

  /// 非同期処理の終了時に猶予タイマー由来の切断要求が取り消されることを確認する
  func testEndAsyncOperationCancelsRecoveredTimerDisconnect() {
    let owner = makeOwner()
    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: nil,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    let pending = owner.endAsyncOperation {
      self.isCancelledByRecovery(reason: $0, connectionState: .connected)
    }

    XCTAssertNil(pending, "回復している場合は実行しないこと")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理は開始されないこと")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "終了で残高が 0 になること")
    XCTAssertTrue(
      owner.beginConnectionStart(),
      "取り消しで残った切断処理の開始フラグが立たないこと")
  }

  /// 切断処理の開始後に完了した非同期処理の終了が無視されることを確認する
  ///
  /// `isDisconnecting` が真の間は、進行中の非同期処理が完了しても非同期処理数を
  /// 減らさず、遅延させた切断要求も実行しない。到達可能な状態でのみ検証する。
  func testEndAsyncOperationIsIgnoredAfterDisconnectAccepted() {
    let owner = makeOwner()
    // 切断処理が開始されていない状態で切断要求を受理させ、切断処理を開始する。
    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { true })
    XCTAssertNotNil(immediate, "非同期処理が無い場合は即時実行すること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理が開始されていること")
    // 接続開始の初期ロックを強制解放した後に届く遅延した終了を模擬する。
    // 切断処理の開始後は、対応する開始が残っていても終了を無視する。
    let pending = owner.endAsyncOperation { _ in false }

    XCTAssertNil(pending, "切断処理の開始後は何も返さないこと")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "切断処理の開始は変わらないこと")
  }

  // MARK: - 音声入力の初期化

  /// 音声入力の初期化完了イベントで初期化済みフラグが立ち、そのイベントだけでは snapshot を publish しないことを確認する
  ///
  /// `isAudioInputInitialized` は接続試行状態と同じく snapshot を publish する契機にしない値で
  /// あるため、所有者の同期 API から読み、接続試行状態の不変条件を変えないことを確認する。
  func testAudioInputInitializedIsOwnedByConnectionStateOwner() {
    let storage = ConnectionSnapshotStorage()
    let owner = ConnectionStateOwner(snapshotStorage: storage, disconnectCleanupTimeout: 30)

    XCTAssertFalse(owner.isAudioInputInitialized(), "初期状態は未初期化であること")
    XCTAssertFalse(
      storage.current().isAudioInputInitialized,
      "初期状態の snapshot は未初期化であること")

    owner.handle(.audioInputInitialized)

    XCTAssertTrue(owner.isAudioInputInitialized(), "イベントで初期化済みになること")
    XCTAssertFalse(
      storage.current().isAudioInputInitialized,
      "このイベントだけでは snapshot を publish しないこと")
    XCTAssertEqual(
      owner.stateForTesting().asyncOperationCount,
      0,
      "接続試行状態の非同期処理数を変えないこと")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "切断処理を開始しないこと")

    // snapshot を publish する別のイベントでは、state 全体の写しとしてこのフラグも現れる
    owner.handle(.redirectReceived)
    XCTAssertTrue(
      storage.current().isAudioInputInitialized,
      "snapshot を publish するイベントでは state 全体の写しとして現れること")
  }

  // MARK: - 切断クリーンアップのタイムアウト

  /// 遅延保存した切断要求がタイムアウトで取り出され、強制切断用の状態になることを確認する
  ///
  /// 保存時点でタイマーが開始され、`disconnectCleanupTimeout` 秒後に
  /// `onDisconnectCleanupTimedOut` へ要求が渡る。タイムアウト時は `isDisconnecting` が立ち、
  /// 非同期処理数が 0 にリセットされる。
  func testDisconnectCleanupTimeoutTakesPendingAndMarksDisconnecting() {
    let owner = makeOwner(disconnectCleanupTimeout: 1)
    let timedOut = expectation(description: "切断クリーンアップのタイムアウト")
    var received: PendingDisconnect?
    owner.onDisconnectCleanupTimedOut = { pending in
      received = pending
      timedOut.fulfill()
    }

    owner.beginAsyncOperation()
    let immediate = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    XCTAssertNil(immediate, "進行中の非同期処理がある間は保存すること")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "タイムアウト前は切断処理を開始しないこと")

    wait(for: [timedOut], timeout: 5)

    XCTAssertEqual(received?.reason, .user, "保存した要求が渡ること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "強制切断のため切断処理が開始されること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "非同期処理数が 0 にリセットされること")
  }

  /// タイマー発火時に接続が回復していれば、保存した要求を破棄して強制切断しないことを確認する
  ///
  /// 実時間には依存せず、`handleDisconnectCleanupTimedOut(generation:)` を直接呼んで
  /// 回復時の取り消しを検証する。
  func testDisconnectCleanupTimeoutCancelsWhenConnectionRecovered() {
    let owner = makeOwner(disconnectCleanupTimeout: 30)
    var received: PendingDisconnect?
    owner.onDisconnectCleanupTimedOut = { pending in
      received = pending
    }
    owner.shouldCancelPendingDisconnectOnCleanupTimeout = { reason in
      reason == .peerConnectionStateDisconnected
    }

    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: nil,
      reason: .peerConnectionStateDisconnected,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let generation = owner.stateForTesting().disconnectCleanupTimerGeneration

    owner.handleDisconnectCleanupTimedOut(generation: generation)

    XCTAssertNil(received, "回復時は強制切断しないこと")
    XCTAssertNil(
      owner.endAsyncOperation { _ in false },
      "回復時に保存した要求が破棄されていること")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "回復時は強制切断しないこと")
  }

  /// 保存した要求が通常の非同期処理の終了で解決された場合、タイマーがキャンセルされることを確認する
  func testDisconnectCleanupTimeoutCancelledByEndAsyncOperation() {
    let owner = makeOwner(disconnectCleanupTimeout: 1)
    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let generationBefore = owner.stateForTesting().disconnectCleanupTimerGeneration
    let pending = owner.endAsyncOperation { _ in false }

    XCTAssertEqual(pending?.reason, .user, "非同期処理の終了時に要求が取り出されること")
    XCTAssertEqual(
      owner.stateForTesting().disconnectCleanupTimerGeneration,
      generationBefore + 1,
      "解決時にタイマーがキャンセルされること (世代が進む)")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "通常の切断処理が開始されていること")
  }

  /// 保存済みの要求が上書きされた場合に、新しい世代のタイマーだけが発火することを確認する
  ///
  /// 実時間には依存せず、`handleDisconnectCleanupTimedOut(generation:)` を直接呼んで
  /// 旧世代では何もせず、現在の世代では最後に保存した要求が渡ることを検証する。
  func testDisconnectCleanupTimerRestartsOnOverwrite() {
    let owner = makeOwner(disconnectCleanupTimeout: 30)
    var received: PendingDisconnect?
    owner.onDisconnectCleanupTimedOut = { pending in
      received = pending
    }

    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: SoraError.connectionCancelled,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let firstGeneration = owner.stateForTesting().disconnectCleanupTimerGeneration

    _ = owner.requestDisconnect(
      error: nil,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let secondGeneration = owner.stateForTesting().disconnectCleanupTimerGeneration

    XCTAssertEqual(secondGeneration, firstGeneration + 1, "上書きでタイマーの世代が進むこと")

    // 旧世代のタイマーが遅れて発火しても、上書き後の要求を拾わない
    owner.handleDisconnectCleanupTimedOut(generation: firstGeneration)
    XCTAssertNil(received, "旧世代では強制切断しないこと")
    XCTAssertFalse(owner.stateForTesting().isDisconnecting, "状態を変えないこと")

    // 現在の世代では、最後に保存した要求が渡る
    owner.handleDisconnectCleanupTimedOut(generation: secondGeneration)
    XCTAssertEqual(received?.reason, .signalingFailure, "最後の切断要求が渡ること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "強制切断のため切断処理が開始されること")
  }

  /// `disconnectCleanupTimeout` が 0 以下の場合はタイマーを開始しないことを確認する
  func testDisconnectCleanupTimeoutNonPositiveDoesNotScheduleTimer() {
    for timeout in [0, -1] {
      let owner = makeOwner(disconnectCleanupTimeout: timeout)
      owner.beginAsyncOperation()
      _ = owner.requestDisconnect(
        error: nil,
        reason: .user,
        shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
        isConnectHandlerHeld: { false })

      XCTAssertEqual(
        owner.stateForTesting().disconnectCleanupTimerGeneration,
        0,
        "timeout \(timeout) ではタイマーを開始しないため世代も進まないこと")
    }
  }

  /// 開始区間中に保存した要求もタイマーで強制切断されることを確認する
  func testDisconnectCleanupTimeoutWhileStartingConnection() {
    let owner = makeOwner(disconnectCleanupTimeout: 1)
    let timedOut = expectation(description: "開始区間中の要求もタイムアウトする")
    var received: PendingDisconnect?
    owner.onDisconnectCleanupTimedOut = { pending in
      received = pending
      timedOut.fulfill()
    }

    XCTAssertTrue(owner.beginConnectionStart(), "開始区間へ入ること")
    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    wait(for: [timedOut], timeout: 5)

    XCTAssertEqual(received?.reason, .user, "開始区間中に保存した要求が渡ること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "強制切断のため切断処理が開始されること")
    XCTAssertFalse(owner.stateForTesting().isStartingConnection, "開始区間が閉じられること")
    XCTAssertEqual(owner.stateForTesting().asyncOperationCount, 0, "非同期処理数が 0 にリセットされること")
  }

  /// タイムアウト時に受け取り手が無い場合は、状態を変えず保存した要求を残すことを確認する
  func testDisconnectCleanupTimeoutWithoutHandlerKeepsPending() {
    let owner = makeOwner(disconnectCleanupTimeout: 30)
    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: nil,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })
    let generation = owner.stateForTesting().disconnectCleanupTimerGeneration

    owner.handleDisconnectCleanupTimedOut(generation: generation)

    XCTAssertFalse(
      owner.stateForTesting().isDisconnecting,
      "受け取り手が無い場合は切断処理を開始しないこと")
    let pending = owner.endAsyncOperation { _ in false }
    XCTAssertEqual(pending?.reason, .user, "保存した要求が残っていること")
  }

  /// 上書きで実タイマーが再アームされ、最後の保存からタイムアウトすることを確認する
  ///
  /// 直接呼び出しのテストと違い、`scheduleDisconnectCleanupTimerLocked` が上書き時に
  /// 新しい世代で `asyncAfter` を再発行することを実時間で検証する。
  func testDisconnectCleanupTimerRearmsOnOverwrite() {
    let owner = makeOwner(disconnectCleanupTimeout: 2)
    let timedOut = expectation(description: "上書き後のタイマーが発火する")
    timedOut.assertForOverFulfill = true
    var received: PendingDisconnect?
    owner.onDisconnectCleanupTimedOut = { pending in
      received = pending
      timedOut.fulfill()
    }

    owner.beginAsyncOperation()
    _ = owner.requestDisconnect(
      error: SoraError.connectionCancelled,
      reason: .user,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    // 旧タイマーの期限 (2 秒) より十分前に上書きする
    Thread.sleep(forTimeInterval: 0.5)
    _ = owner.requestDisconnect(
      error: nil,
      reason: .signalingFailure,
      shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
      isConnectHandlerHeld: { false })

    wait(for: [timedOut], timeout: 5)
    XCTAssertEqual(received?.reason, .signalingFailure, "最後の切断要求が渡ること")
    XCTAssertTrue(owner.stateForTesting().isDisconnecting, "強制切断のため切断処理が開始されること")
  }
}
