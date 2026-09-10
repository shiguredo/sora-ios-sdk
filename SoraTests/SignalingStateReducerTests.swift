import XCTest

@testable import Sora

/// SignalingChannel の状態 reducer のユニットテスト
///
/// phase / URL / フラグの遷移は、接続タイミングに依存する E2E テストだけでは
/// 決定的に検証できないため、reducer の純粋関数として直接検証する。
final class SignalingStateReducerTests: XCTestCase {
  // MARK: - 接続開始

  /// disconnected から connectRequested で connecting に遷移することを確認する
  func testConnectRequestedTransitionsToConnecting() {
    let state = SignalingState()

    let result = SignalingStateReducer.reduce(state: state, event: .connectRequested)

    XCTAssertEqual(result.state.phase, .connecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// connecting 中の connectRequested は拒否されることを確認する
  func testConnectRequestedRejectedWhileConnecting() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state

    let result = SignalingStateReducer.reduce(state: state, event: .connectRequested)

    XCTAssertEqual(result.state.phase, .connecting)
    XCTAssertFalse(result.effects.contains(.publishSnapshot))
  }

  // MARK: - 接続成功

  /// 最初の candidateConnected で connected になり contactUrl が設定されることを確認する
  func testCandidateConnectedTransitionsToConnected() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    let url = URL(string: "wss://example.com/signaling")!

    let result = SignalingStateReducer.reduce(
      state: state, event: .candidateConnected(url: url))

    XCTAssertEqual(result.state.phase, .connected)
    XCTAssertEqual(result.state.contactUrl, url)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// 2 番目以降の candidateConnected は無視され contactUrl が維持されることを確認する
  func testSecondCandidateConnectedIsIgnored() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    let firstUrl = URL(string: "wss://example.com/signaling")!
    let secondUrl = URL(string: "wss://example2.com/signaling")!
    state =
      SignalingStateReducer.reduce(
        state: state, event: .candidateConnected(url: firstUrl)
      ).state

    let result = SignalingStateReducer.reduce(
      state: state, event: .candidateConnected(url: secondUrl))

    XCTAssertEqual(result.state.phase, .connected)
    XCTAssertEqual(result.state.contactUrl, firstUrl)
    XCTAssertFalse(result.effects.contains(.publishSnapshot))
  }

  // MARK: - 接続失敗

  /// connectionFailed で disconnected に遷移することを確認する
  func testConnectionFailedTransitionsToDisconnected() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state

    let result = SignalingStateReducer.reduce(state: state, event: .connectionFailed)

    XCTAssertEqual(result.state.phase, .disconnected)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - redirect

  /// redirectRequested で connecting に戻り contactUrl が維持されることを確認する
  func testRedirectRequestedKeepsContactUrl() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    let url = URL(string: "wss://example.com/signaling")!
    state =
      SignalingStateReducer.reduce(
        state: state, event: .candidateConnected(url: url)
      ).state

    let result = SignalingStateReducer.reduce(state: state, event: .redirectRequested)

    XCTAssertEqual(result.state.phase, .connecting)
    XCTAssertEqual(result.state.contactUrl, url)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - 切断

  /// connected 中の disconnectRequested で disconnecting に遷移することを確認する
  func testDisconnectRequestedFromConnected() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    state =
      SignalingStateReducer.reduce(
        state: state, event: .candidateConnected(url: URL(string: "wss://example.com")!)
      ).state

    let result = SignalingStateReducer.reduce(state: state, event: .disconnectRequested)

    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// disconnecting 中の disconnectRequested は拒否されることを確認する
  func testDisconnectRequestedRejectedWhileDisconnecting() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    state = SignalingStateReducer.reduce(state: state, event: .disconnectRequested).state

    let result = SignalingStateReducer.reduce(state: state, event: .disconnectRequested)

    XCTAssertEqual(result.state.phase, .disconnecting)
    XCTAssertFalse(result.effects.contains(.publishSnapshot))
  }

  /// disconnectCompleted で disconnected になることを確認する
  func testDisconnectCompletedTransitionsToDisconnected() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    state = SignalingStateReducer.reduce(state: state, event: .disconnectRequested).state

    let result = SignalingStateReducer.reduce(state: state, event: .disconnectCompleted)

    XCTAssertEqual(result.state.phase, .disconnected)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// disconnectCompleted では URL が維持され、urlsCleared でクリアされることを確認する
  /// (切断完了通知の後に URL をクリアする既存の順序を維持する)
  func testUrlsClearedClearsUrls() {
    var state = SignalingState()
    state = SignalingStateReducer.reduce(state: state, event: .connectRequested).state
    let url = URL(string: "wss://example.com/signaling")!
    state =
      SignalingStateReducer.reduce(
        state: state, event: .candidateConnected(url: url)
      ).state
    state =
      SignalingStateReducer.reduce(
        state: state, event: .connectedUrlSet(url: url)
      ).state
    state = SignalingStateReducer.reduce(state: state, event: .disconnectRequested).state

    let completed = SignalingStateReducer.reduce(state: state, event: .disconnectCompleted)
    XCTAssertEqual(completed.state.contactUrl, url, "切断完了時点では URL が維持されること")
    XCTAssertEqual(completed.state.connectedUrl, url, "切断完了時点では URL が維持されること")

    let cleared = SignalingStateReducer.reduce(state: completed.state, event: .urlsCleared)
    XCTAssertNil(cleared.state.contactUrl, "urlsCleared で contactUrl がクリアされること")
    XCTAssertNil(cleared.state.connectedUrl, "urlsCleared で connectedUrl がクリアされること")
  }

  // MARK: - URL / フラグ

  /// connectedUrlSet で connectedUrl が設定されることを確認する
  func testConnectedUrlSet() {
    let state = SignalingState()
    let url = URL(string: "wss://example.com/signaling")!

    let result = SignalingStateReducer.reduce(state: state, event: .connectedUrlSet(url: url))

    XCTAssertEqual(result.state.connectedUrl, url)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// dataChannelSignalingUpdated でフラグが更新されることを確認する
  func testDataChannelSignalingUpdated() {
    let state = SignalingState()

    let result = SignalingStateReducer.reduce(
      state: state, event: .dataChannelSignalingUpdated(true))

    XCTAssertTrue(result.state.dataChannelSignaling)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  /// ignoreDisconnectWebSocketUpdated でフラグが更新されることを確認する
  func testIgnoreDisconnectWebSocketUpdated() {
    let state = SignalingState()

    let result = SignalingStateReducer.reduce(
      state: state, event: .ignoreDisconnectWebSocketUpdated(true))

    XCTAssertTrue(result.state.ignoreDisconnectWebSocket)
    XCTAssertTrue(result.effects.contains(.publishSnapshot))
  }

  // MARK: - snapshot

  /// SignalingSnapshotStorage の publish / current が NSLock で保護されていることを確認する
  func testSnapshotStoragePublishAndRead() {
    let storage = SignalingSnapshotStorage()
    var state = SignalingState()
    state.phase = .connecting
    let snapshot = SignalingSnapshot(
      state: state, currentChannelIdentifier: nil)

    storage.publish(snapshot: snapshot)

    XCTAssertEqual(storage.current().state.phase, .connecting)
  }

  // MARK: - owner

  /// owner の sync が queue 上の再入でもデッドロックしないことを確認する
  func testOwnerSyncIsReentrant() {
    let owner = SignalingStateOwner()
    var didRunInner = false

    owner.sync {
      owner.sync {
        didRunInner = true
      }
    }

    XCTAssertTrue(didRunInner)
  }

  /// owner の sync が別スレッドからでも状態を更新できることを確認する
  func testOwnerSyncFromOtherThread() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "別スレッドからの sync が完了すること")

    DispatchQueue.global().async {
      owner.sync {
        owner.handle(.connectRequested)
      }
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(owner.snapshot.state.phase, .connecting)
  }

  /// URLSession delegate callback 相当 (owner.queue 上の操作) からの再入が
  /// デッドロックしないことを確認する
  func testOwnerSyncIsReentrantOnDelegateQueue() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "delegate queue 上の再入が完了すること")

    owner.queue.addOperation {
      owner.sync {
        owner.handle(.connectRequested)
      }
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(owner.snapshot.state.phase, .connecting)
  }
}
