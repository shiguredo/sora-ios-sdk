@preconcurrency import Sora
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

  /// `role` を指定して E2E 用の Configuration を構築する
  private func buildConfiguration(role: Role) throws -> Configuration {
    var config = try buildConfiguration()
    config.role = role
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

      XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
      connectedChannel = channel
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

  // MARK: - sendonly ダミー映像テスト

  /// sendonly で DummyVideoCapturer を使ってダミー映像を送信できることを確認する
  func testSendonlyDummyVideo() throws {
    var config = try buildConfiguration(role: .sendonly)
    // 接続時の物理カメラ自動起動を抑止し、senderStream 生成後にダミー映像を流す
    config.initialCameraEnabled = false
    // この E2E はダミー映像送信の確認に限定し、音声初期化による不安定要因を避ける
    config.audioEnabled = false
    let expectation = self.expectation(description: "sendonly でダミー映像を送信できること")
    var capturer: DummyVideoCapturer?

    _ = sora.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      guard let channel = mediaChannel, let stream = channel.senderStream else {
        XCTFail("senderStream が nil")
        expectation.fulfill()
        return
      }
      let currentCapturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
      currentCapturer.stream = stream
      currentCapturer.start()
      capturer = currentCapturer
      // connect コールバックの実行スレッドに依存させず、main RunLoop 上で 2 秒待機してから
      // ダミー映像送信の継続と WebRTC 統計情報を確認する
      DispatchQueue.main.async { [channel, currentCapturer, expectation] in
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
          channel.getStats { result in
            defer { expectation.fulfill() }
            XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
            XCTAssertNotNil(channel.senderStream, "senderStream が維持されていること")
            XCTAssertTrue(currentCapturer.isRunning, "DummyVideoCapturer が動作中であること")
            XCTAssertGreaterThan(currentCapturer.frameCount, 0, "ダミー映像フレームが送信されていること")

            guard case .success(let stats) = result else {
              XCTFail("getStats に失敗した")
              return
            }

            let videoOutbound = stats.entries.first {
              $0.type == "outbound-rtp"
                && ($0.values["kind"] as? NSString) == "video"
            }
            XCTAssertNotNil(videoOutbound, "outbound video stats が存在すること")
            let bytesSent = videoOutbound?.values["bytesSent"] as? NSNumber
            let packetsSent = videoOutbound?.values["packetsSent"] as? NSNumber
            XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
            XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
            XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が増加していること")
            XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が増加していること")
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }

    wait(for: [expectation], timeout: 90)
    capturer?.stop()
    // 切断
    if let channel = sora.mediaChannels.first {
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
