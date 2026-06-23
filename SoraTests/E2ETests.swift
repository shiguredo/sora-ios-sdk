import XCTest

@testable import Sora

/// iOS E2E テスト
///
/// 環境変数 SORA_SIGNALING_URL と TEST_SECRET_KEY が未設定の場合はスキップされる。
///
/// 必要な環境変数:
/// - SORA_SIGNALING_URL: Sora シグナリング接続先 URL
/// - TEST_SECRET_KEY: metadata.access_token に設定する認証トークン
/// - TEST_CHANNEL_ID_PREFIX: channelId の prefix (省略可、デフォルト "")
/// - TEST_CHANNEL_ID_SUFFIX: channelId の suffix (省略可、デフォルト "")
final class E2ETests: XCTestCase {
  private var sora: Sora!

  override func setUp() {
    super.setUp()
    // シークレットを含むログを抑制するため、ログレベルを warn に設定する
    Logger.shared.level = .warn
    sora = Sora()
  }

  override func tearDown() {
    sora = nil
    Logger.shared.level = .info
    super.tearDown()
  }

  // MARK: - ヘルパー

  /// E2E 用の Configuration を構築する
  ///
  /// 環境変数が未設定の場合は XCTSkip でテストをスキップする
  private func buildConfiguration() throws -> Configuration {
    guard
      let urlString = ProcessInfo.processInfo.environment["SORA_SIGNALING_URL"],
      !urlString.isEmpty,
      let url = URL(string: urlString)
    else {
      throw XCTSkip("SORA_SIGNALING_URL が未設定のためスキップします")
    }

    guard
      let accessToken = ProcessInfo.processInfo.environment["TEST_SECRET_KEY"],
      !accessToken.isEmpty
    else {
      throw XCTSkip("TEST_SECRET_KEY が未設定のためスキップします")
    }

    let prefix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_PREFIX"]
    let suffix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_SUFFIX"] ?? ""
    let channelId = "\(prefix ?? "")e2e-test\(suffix)"
    print("TEST_CHANNEL_ID_PREFIX: \(prefix != nil ? "set" : "not set")")

    // E2E テスト専用のメタデータ構造体
    struct E2EMetadata: Encodable {
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let access_token: String
    }

    var config = Configuration(
      urlCandidates: [url],
      channelId: channelId,
      role: .recvonly
    )
    config.signalingConnectMetadata = E2EMetadata(access_token: accessToken)
    // recvonly のため送信メディアは不要
    config.audioEnabled = false
    config.videoEnabled = false

    return config
  }

  // MARK: - recvonly 接続テスト

  /// Sora に recvonly で接続できることを確認する
  func testConnectRecvonly() throws {
    let config = try buildConfiguration()

    let expectation = self.expectation(description: "recvonly 接続が成功すること")
    var connectedChannel: MediaChannel?

    _ = sora.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      connectedChannel = mediaChannel
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 30)

    // テスト後に切断する
    if let channel = connectedChannel {
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { _ in
        disconnectExpectation.fulfill()
      }
      channel.disconnect(error: nil)
      wait(for: [disconnectExpectation], timeout: 10)
    }
  }

  /// 接続後に明示的切断ができることを確認する
  func testDisconnectRecvonly() throws {
    let config = try buildConfiguration()

    let connectExpectation = self.expectation(description: "recvonly 接続が成功すること")
    var mediaChannel: MediaChannel?

    _ = sora.connect(configuration: config) { channel, error in
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

    // 切断を実行し、onDisconnect が呼ばれることを確認する
    let disconnectExpectation = self.expectation(description: "切断が成功すること")
    channel.handlers.onDisconnect = { _ in
      disconnectExpectation.fulfill()
    }

    channel.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: 10)
  }

  /// recvonly で offer / answer が完了し、接続状態が connected になることを確認する
  func testOfferAnswerCompleted() throws {
    let config = try buildConfiguration()

    let expectation = self.expectation(description: "recvonly で offer/answer が完了すること")
    var connectedChannel: MediaChannel?

    _ = sora.connect(configuration: config) { mediaChannel, error in
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

      // 接続状態が connected であることを確認する
      if channel.native?.connectionState == .connected {
        connectedChannel = channel
        expectation.fulfill()
      } else {
        // 接続状態が connected になっていなくても、
        // onConnect が呼ばれた時点でタイミング差で未遷移の可能性があるため、
        // 少し待ってから再確認する
        let state = channel.native?.connectionState
        XCTFail("接続状態が connected ではない: \(String(describing: state))")
        expectation.fulfill()
      }
    }

    wait(for: [expectation], timeout: 30)

    // テスト後に切断する
    if let channel = connectedChannel {
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { _ in
        disconnectExpectation.fulfill()
      }
      channel.disconnect(error: nil)
      wait(for: [disconnectExpectation], timeout: 10)
    }
  }
}
