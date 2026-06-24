import Sora
import XCTest

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
  private var originalLogLevel: LogLevel!
  private struct InvalidURLError: Error {}

  override func setUp() {
    super.setUp()
    originalLogLevel = Logger.shared.level
    Logger.shared.level = .warn
    sora = Sora()
  }

  override func tearDown() {
    for channel in sora?.mediaChannels ?? [] {
      channel.disconnect(error: nil)
    }
    sora = nil
    Logger.shared.level = originalLogLevel
    super.tearDown()
  }

  // MARK: - ヘルパー

  /// E2E 用の Configuration を構築する
  ///
  /// 環境変数が未設定の場合は XCTSkip でテストをスキップする
  private func buildConfiguration() throws -> Configuration {
    guard
      let urlString = ProcessInfo.processInfo.environment["SORA_SIGNALING_URL"],
      !urlString.isEmpty
    else {
      throw XCTSkip("SORA_SIGNALING_URL が未設定のためスキップします")
    }
    guard let url = URL(string: urlString) else {
      XCTFail("SORA_SIGNALING_URL が不正な値です: \(urlString)")
      throw InvalidURLError()
    }

    guard
      let accessToken = ProcessInfo.processInfo.environment["TEST_SECRET_KEY"],
      !accessToken.isEmpty
    else {
      throw XCTSkip("TEST_SECRET_KEY が未設定のためスキップします")
    }

    let prefix: String? = {
      if let v = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_PREFIX"], !v.isEmpty {
        return v
      }
      return nil
    }()
    let suffix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_SUFFIX"] ?? ""
    let channelId = "\(prefix ?? "")e2e-test\(suffix)"

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

    if let channel = connectedChannel {
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { event in
        if case .ok(let code, _) = event {
          XCTAssertEqual(code, 1000, "正常切断コードであること")
        } else {
          XCTFail("予期しない切断: \(event)")
        }
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

    // 切断を実行し、onDisconnect が正常切断コードで呼ばれることを確認する
    let disconnectExpectation = self.expectation(description: "切断が成功すること")
    channel.handlers.onDisconnect = { event in
      if case .ok(let code, _) = event {
        XCTAssertEqual(code, 1000, "正常切断コードであること")
      } else {
        XCTFail("予期しない切断: \(event)")
      }
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

      // onConnect が呼ばれた時点では connectionState がまだ .connected に
      // 遷移していない可能性があるため、最大 5 秒間ポーリングで待つ
      let deadline = Date().addingTimeInterval(5)
      func poll() {
        if channel.native?.connectionState == .connected {
          connectedChannel = channel
          expectation.fulfill()
        } else if Date() > deadline {
          let state = channel.native?.connectionState
          XCTFail("接続状態が connected に遷移しなかった: \(String(describing: state))")
          expectation.fulfill()
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            poll()
          }
        }
      }
      poll()
    }

    wait(for: [expectation], timeout: 30)

    if let channel = connectedChannel {
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { event in
        if case .ok(let code, _) = event {
          XCTAssertEqual(code, 1000, "正常切断コードであること")
        } else {
          XCTFail("予期しない切断: \(event)")
        }
        disconnectExpectation.fulfill()
      }
      channel.disconnect(error: nil)
      wait(for: [disconnectExpectation], timeout: 10)
    }
  }
}
