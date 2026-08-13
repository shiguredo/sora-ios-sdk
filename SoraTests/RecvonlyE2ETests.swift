import XCTest

@testable @preconcurrency import Sora

/// recvonly 接続テスト
final class RecvonlyE2ETests: E2ETestBase {
  /// Sora に recvonly で接続できることを確認する
  func testConnectRecvonly() throws {
    let config = try buildConfiguration()

    let expectation = self.expectation(description: "recvonly 接続が成功すること")
    var connectedChannel: MediaChannel?

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      connectedChannel = mediaChannel
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 30)

    if let channel = connectedChannel {
      disconnectAndVerify(channel: channel)
    }
  }

  /// 接続後に明示的切断ができることを確認する
  func testDisconnectRecvonly() throws {
    let config = try buildConfiguration()

    let connectExpectation = self.expectation(description: "recvonly 接続が成功すること")
    var mediaChannel: MediaChannel?

    _ = sora?.connect(configuration: config) { channel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        connectExpectation.fulfill()
        return
      }
      mediaChannel = channel
      connectExpectation.fulfill()
    }

    wait(for: [connectExpectation], timeout: 30)

    guard let channel = mediaChannel else {
      XCTFail("メディアチャネルが nil")
      return
    }

    // 切断を実行し、onDisconnect が正常切断コードで呼ばれることを確認する
    disconnectAndVerify(channel: channel)
  }

  /// recvonly で offer / answer が完了し、接続状態が connected になることを確認する
  func testOfferAnswerCompleted() throws {
    let config = try buildConfiguration()

    let expectation = self.expectation(description: "recvonly で offer/answer が完了すること")
    var connectedChannel: MediaChannel?

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      guard let channel = mediaChannel else {
        XCTFail("メディアチャネルが nil")
        expectation.fulfill()
        return
      }

      XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
      connectedChannel = channel
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 30)

    if let channel = connectedChannel {
      disconnectAndVerify(channel: channel)
    }
  }
}
