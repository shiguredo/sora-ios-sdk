import XCTest

@testable import Sora

/// ConnectionTask の状態遷移に関するユニットテスト
///
/// ConnectionTask の状態遷移とキャンセル要求の保持は、接続タイミングに依存する
/// E2E テストだけでは決定的に検証できないため、状態遷移を直接検証する。
/// PeerChannel への attach とキャンセルの競合は実 PeerChannel を使う E2E テスト
/// (ConnectionTaskCancelE2ETests) で検証する。
final class ConnectionTaskTests: XCTestCase {
  /// 接続試行中の cancel() が公開 state では canceled として観測されることを確認する
  ///
  /// 内部状態では cancelRequested (キャンセル処理中) を経由するが、公開 State は
  /// 3 状態 (connecting / completed / canceled) のみであり、キャンセル要求を
  /// 受領した時点で canceled として観測される。
  /// cancel 要求の保持と attach による確定は、後続のテストで検証する。
  func testCancelShowsCanceledOnPublicState() {
    let task = ConnectionTask()
    XCTAssertEqual(task.state, .connecting)

    task.cancel()
    XCTAssertEqual(task.state, .canceled)
  }

  /// キャンセル要求の保持が attach の結果に反映されることを確認する
  ///
  /// peerChannel が未設定の場合は cancel 要求は内部では cancelRequested として
  /// 保持され、attach が呼ばれると false を返す。呼び出し元が markCanceled() を
  /// 呼ぶことで最終的に確定する (公開 state はどちらも canceled)。
  func testCancelRequestHeldUntilAttach() {
    let task = ConnectionTask()
    task.cancel()

    // キャンセル要求が保持されているため、接続を開始できない
    XCTAssertFalse(task.attach(peerChannel: makeTestPeerChannel()))
    task.markCanceled()
    XCTAssertEqual(task.state, .canceled)
  }

  /// キャンセル済みの ConnectionTask に attach すると false が返ることを確認する
  func testAttachAfterCancelReturnsFalse() {
    let task = ConnectionTask()
    task.cancel()
    task.markCanceled()

    // キャンセル済みのため、接続を開始できない
    XCTAssertFalse(task.attach(peerChannel: makeTestPeerChannel()))
  }

  /// 接続中の complete() は completed へ遷移することを確認する
  func testCompleteTransitionsToCompleted() {
    let task = ConnectionTask()
    task.complete()
    XCTAssertEqual(task.state, .completed)
  }

  /// キャンセル要求後の complete() は completed へ上書きしないことを確認する
  ///
  /// .canceled が .completed に上書きされる問題の回帰テスト。
  func testCompleteDoesNotOverwriteCanceled() {
    let task = ConnectionTask()
    task.cancel()
    task.markCanceled()
    XCTAssertEqual(task.state, .canceled)

    task.complete()
    XCTAssertEqual(task.state, .canceled, "canceled は completed に上書きされないこと")
  }

  /// 接続完了後の cancel() は何もしないことを確認する
  func testCancelAfterCompletedDoesNothing() {
    let task = ConnectionTask()
    task.complete()
    XCTAssertEqual(task.state, .completed)

    task.cancel()
    XCTAssertEqual(task.state, .completed, "completed は canceled に上書きされないこと")
  }

  /// attach 中にキャンセルが競合しても、終端状態が一意になることを確認する
  ///
  /// 接続開始 (attach) とキャンセルのどちらが先に実行されても、最終状態は
  /// canceled (キャンセル先行) または completed (接続完了先行) のどちらかになる。
  func testAttachAndCancelRaceEndsInTerminalState() {
    // 動作は thread に依存するため、両方のオーダーを順番に実行して確認する
    let task1 = ConnectionTask()
    task1.cancel()
    task1.markCanceled()
    XCTAssertEqual(task1.state, .canceled)
    XCTAssertFalse(task1.attach(peerChannel: makeTestPeerChannel()))

    let task2 = ConnectionTask()
    XCTAssertTrue(task2.attach(peerChannel: makeTestPeerChannel()))
    task2.cancel()
    task2.markCanceled()
    XCTAssertEqual(task2.state, .canceled)
  }

  /// テスト用の PeerChannel を構築する
  ///
  /// ConnectionTask.attach は PeerChannel の参照を保持するだけで状態には触れないため、
  /// テスト用のダミー構成で検証可能である
  private func makeTestPeerChannel() -> PeerChannel {
    let config = Configuration(
      urlCandidates: [URL(fileURLWithPath: "/tmp")],
      channelId: "test",
      role: .sendonly)
    let signalingChannel = SignalingChannel(configuration: config)
    let nativeFactory = NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      configuration: config,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
  }
}
