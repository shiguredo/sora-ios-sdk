import XCTest

@testable import Sora

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
  private func makePeerChannel(config: Configuration) -> PeerChannel {
    let signalingChannel = SignalingChannel(configuration: config)
    let nativeFactory = NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      configuration: config,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
  }

  /// 接続完了 callback が 2 回呼ばれても 1 回目だけ実行されることを確認する
  ///
  /// take-and-clear により、1 回目の呼び出しで onConnect が nil へクリアされるため、
  /// 2 回目の呼び出しでは callback が実行されない。
  func testInvokeConnectHandlerRunsOnce() {
    let config = makeConfiguration()
    let peerChannel = makePeerChannel(config: config)
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
  func testInvokeConnectHandlerReentrantDisconnectRunsOnce() {
    let config = makeConfiguration()
    let peerChannel = makePeerChannel(config: config)
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
  func testInvokeConnectHandlerWithErrorRunsOnce() {
    let config = makeConfiguration()
    let peerChannel = makePeerChannel(config: config)
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
  func testConnectFailureReachesHandlerOnce() {
    let config = makeConnectionRefusedConfiguration()
    let peerChannel = makePeerChannel(config: config)
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
}
