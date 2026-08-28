import XCTest

@testable @preconcurrency import Sora

/// PeerChannel の接続完了ハンドラーの終端保証に関する E2E テスト
///
/// 実際の Sora サーバーへ接続し、「接続成功 callback 内から同期的に disconnect() を呼ぶ」
/// ケースで、接続 callback と切断 callback がそれぞれ 1 回だけ発火し、
/// 接続が正しく終端されることを検証する。
final class PeerChannelConnectCompletionE2ETests: E2ETestBase {
  /// 接続成功 callback 内から同期的に disconnect() しても callback は 1 回だけ呼ばれ、
  /// 切断が完了することを確認する
  ///
  /// 接続成功 callback 内で同期的に disconnect() を呼ぶと、旧実装では
  /// Lock.waitDisconnect が接続試行中と判断して basicDisconnect() を実行し、
  /// 同じ onConnect が残っているため接続 callback が 2 回呼ばれていた。
  /// take-and-clear により 1 回だけ呼ばれることを実経路で検証する。
  func testConnectCallbackDisconnectRunsOnceAndTerminates() throws {
    var config = try buildConfiguration(role: .sendonly)
    // 接続時の物理カメラ自動起動を抑止する (接続終端の検証に限定し、カメラを不要にする)
    config.initialCameraEnabled = false
    config.audioEnabled = false

    let connectExpectation = self.expectation(description: "接続 callback が 1 回だけ呼ばれること")
    let disconnectExpectation = self.expectation(description: "切断が完了すること")
    var connectCallbackCount = 0

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        connectExpectation.fulfill()
        return
      }
      guard let channel = mediaChannel else {
        XCTFail("mediaChannel が nil")
        connectExpectation.fulfill()
        return
      }

      // onDisconnect を先に設定してから切断する
      // (disconnect() は同期で onDisconnect が発火するため)
      channel.handlers.onDisconnect = { _ in
        DispatchQueue.main.async {
          XCTAssertTrue(
            channel.state.isDisconnected,
            "切断後は MediaChannel の state が disconnected であること")
          disconnectExpectation.fulfill()
        }
      }

      // 接続成功 callback 内から同期的に切断する
      // (旧実装ではこれが callback の二重実行を引き起こしていた)
      channel.disconnect(error: nil)

      connectCallbackCount += 1
      connectExpectation.fulfill()
    }

    wait(for: [connectExpectation, disconnectExpectation], timeout: 30)
    XCTAssertEqual(connectCallbackCount, 1, "接続 callback は 1 回だけ呼ばれること")
  }

  /// 接続成功後に切断しても、接続 callback が 2 回呼ばれないことを確認する
  ///
  /// 接続成功 callback 内から同期的に disconnect() せず、後から切断するケースでも
  /// take-and-clear により接続 callback が 1 回だけ呼ばれることを確認する。
  func testConnectAndDisconnectRunsConnectOnce() throws {
    var config = try buildConfiguration(role: .sendonly)
    config.initialCameraEnabled = false
    config.audioEnabled = false

    let connectExpectation = self.expectation(description: "接続 callback が 1 回だけ呼ばれること")
    let disconnectExpectation = self.expectation(description: "切断が完了すること")
    var connectCallbackCount = 0
    var connectedChannel: MediaChannel?

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        connectExpectation.fulfill()
        return
      }
      guard let channel = mediaChannel else {
        XCTFail("mediaChannel が nil")
        connectExpectation.fulfill()
        return
      }
      DispatchQueue.main.async {
        connectedChannel = channel
        channel.handlers.onDisconnect = { _ in
          DispatchQueue.main.async {
            disconnectExpectation.fulfill()
          }
        }
        connectCallbackCount += 1
        connectExpectation.fulfill()
      }
    }

    wait(for: [connectExpectation], timeout: 30)
    XCTAssertEqual(connectCallbackCount, 1, "接続 callback は 1 回だけ呼ばれること")

    // 切断を実行し、切断完了を待つ
    connectedChannel?.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: 10)
    XCTAssertEqual(connectCallbackCount, 1, "切断後も接続 callback は 1 回だけであること")
  }
}
