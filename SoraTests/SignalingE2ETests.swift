import AVFoundation
import XCTest

@testable @preconcurrency import Sora

/// iOS E2E テスト
///
/// 環境変数 SORA_SIGNALING_URL と TEST_SECRET_KEY が未設定の場合はスキップされる。
///
/// 必要な環境変数:
/// - SORA_SIGNALING_URL: Sora シグナリング接続先 URL
/// - TEST_SECRET_KEY: metadata.access_token に設定する認証トークン
/// - TEST_CHANNEL_ID_PREFIX: channelId の prefix (省略可、デフォルト "")
/// - TEST_CHANNEL_ID_SUFFIX: channelId の suffix (省略可、デフォルト "")
/// main queue に束ねた処理からテストメソッドの状態へ安全にアクセスするため、
/// テストクラスは @MainActor で隔離する
@MainActor
final class E2ETests: XCTestCase {
  private var sora: Sora?
  private var originalLogLevel: LogLevel?
  private var originalAudioCategory: AVAudioSession.Category?
  private var originalAudioMode: AVAudioSession.Mode?
  private var originalAudioOptions: AVAudioSession.CategoryOptions?
  // テストが AVAudioSession を変更したかどうか (ダミー音声テストのみ true になる)。
  // tearDown で「このテストが変更した場合のみ」カテゴリ設定を復元するためのフラグ。
  // AVAudioSession に触れない他の E2E テストに影響しないよう、フラグで限定する
  private var audioSessionActivatedByTest = false
  private struct InvalidURLError: Error {}

  override func setUp() {
    super.setUp()
    originalLogLevel = Logger.shared.level
    Logger.shared.level = .warn
    // ダミー音声テストが AVAudioSession を変更するため、tearDown で復元できるように保存する
    let session = AVAudioSession.sharedInstance()
    originalAudioCategory = session.category
    originalAudioMode = session.mode
    originalAudioOptions = session.categoryOptions
    audioSessionActivatedByTest = false
    sora = Sora()
  }

  override func tearDown() {
    for channel in sora?.mediaChannels ?? [] {
      channel.disconnect(error: nil)
    }
    sora = nil
    Logger.shared.level = originalLogLevel ?? .info
    // テストが AVAudioSession を変更した場合のみ、カテゴリ設定を復元する。
    // active 状態は取得 API がないため復元できない。setActive(false) を呼ぶと、
    // テスト開始時点で active だった場合に非 active へ落としてしまうため、呼ばない
    if audioSessionActivatedByTest {
      if let category = originalAudioCategory {
        try? AVAudioSession.sharedInstance().setCategory(
          category,
          mode: originalAudioMode ?? .default,
          options: originalAudioOptions ?? [])
      }
    }
    super.tearDown()
  }

  // MARK: - ヘルパー

  /// E2E テスト用のチャンネル ID を構築する
  ///
  /// TEST_CHANNEL_ID_PREFIX / TEST_CHANNEL_ID_SUFFIX 環境変数を組み合わせる。
  /// unique が true の場合は残留接続と混在しない一意な ID にする
  private func buildChannelId(unique: Bool = false) -> String {
    let prefix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_PREFIX"] ?? ""
    let suffix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_SUFFIX"] ?? ""
    let middle = unique ? "e2e-test-\(UUID().uuidString)" : "e2e-test"
    return "\(prefix)\(middle)\(suffix)"
  }

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

    let channelId = buildChannelId()

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

  /// チャンネルを切断し、正常切断コード (1000) が onDisconnect で通知されることを確認する
  ///
  /// 切断済みのチャンネルでは onDisconnect が発火しない (MediaChannel.internalDisconnect は
  /// .disconnecting / .disconnected 状態では何もせずに戻る) ため、その場合は何もせずに戻る
  private func disconnectAndVerify(channel: MediaChannel, timeout: TimeInterval = 10) {
    guard !channel.state.isDisconnected else {
      return
    }
    let disconnectExpectation = self.expectation(description: "切断が完了すること")
    channel.handlers.onDisconnect = { event in
      if case .ok(let code, _) = event {
        XCTAssertEqual(code, 1000, "正常切断コードであること")
      } else {
        XCTFail("予期しない切断: \(event)")
      }
      disconnectExpectation.fulfill()
    }
    // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
    // onDisconnect が発火済みのため、wait せずに戻る
    guard !channel.state.isDisconnected else {
      return
    }
    channel.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: timeout)
  }

  // MARK: - recvonly 接続テスト

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

    _ = sora?.connect(configuration: config) { mediaChannel, error in
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
      DispatchQueue.main.async {
        [channel, currentCapturer, expectation] in
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
          channel.getStats { result in
            defer { expectation.fulfill() }
            XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
            XCTAssertNotNil(channel.senderStream, "senderStream が維持されていること")
            XCTAssertTrue(currentCapturer.isRunning, "DummyVideoCapturer が動作中であること")
            XCTAssertGreaterThan(currentCapturer.frameCount, 0, "ダミー映像フレームが送信されていること")

            guard case .success(let stats) = result else {
              // getStats の failure は接続状態の遷移 (切断・チャンネル再生成等) が原因のため、
              // エラー詳細を含めて出力する
              if case .failure(let error) = result {
                XCTFail("getStats に失敗した : \(error)")
              } else {
                XCTFail("getStats に失敗した")
              }
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
            XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が 0 より大きいこと")
            XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が 0 より大きいこと")
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }

    wait(for: [expectation], timeout: 90)
    capturer?.stop()
    // 切断
    if let channel = sora?.mediaChannels.first {
      disconnectAndVerify(channel: channel)
    }
  }

  // MARK: - sendonly ダミー音声テスト

  /// sendonly で DummyAudioDevice を使ってダミー音声を送信できることを確認する
  func testSendonlyDummyAudio() throws {
    var config = try buildConfiguration(role: .sendonly)
    // この E2E はダミー音声送信の確認に限定し、映像は無効にする
    config.videoEnabled = false
    config.audioEnabled = true
    // 440Hz 正弦波を生成するダミー音声デバイスを注入する
    let sineWaveGenerator = SineWaveGenerator(frequency: 440)
    config.audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true,
      pcmGenerator: { data, frameCount, sampleRate in
        sineWaveGenerator.generate(data: data, frameCount: frameCount, sampleRate: sampleRate)
      })
    // DummyAudioDevice.initialize(with:) が接続試行時に AVAudioSession を有効化するため、
    // tearDown での復元対象とする
    audioSessionActivatedByTest = true
    let expectation = self.expectation(description: "sendonly でダミー音声を送信できること")

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
      // connect コールバックの実行スレッドに依存させず、main RunLoop 上で 2 秒待機してから
      // ダミー音声送信の継続と WebRTC 統計情報を確認する
      DispatchQueue.main.async { [channel, expectation] in
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
          channel.getStats { result in
            defer { expectation.fulfill() }
            XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")

            guard case .success(let stats) = result else {
              // getStats の failure は接続状態の遷移 (切断・チャンネル再生成等) が原因のため、
              // エラー詳細を含めて出力する
              if case .failure(let error) = result {
                XCTFail("getStats に失敗した : \(error)")
              } else {
                XCTFail("getStats に失敗した")
              }
              return
            }

            // 音声コーデック (OPUS) が確定していることを確認する (sora-js-sdk の E2E と同様)
            let audioCodec = stats.entries.first {
              $0.type == "codec"
                && ($0.values["mimeType"] as? NSString) == "audio/opus"
            }
            XCTAssertNotNil(audioCodec, "audio codec stats が存在すること")

            let audioOutbound = stats.entries.first {
              $0.type == "outbound-rtp"
                && ($0.values["kind"] as? NSString) == "audio"
            }
            XCTAssertNotNil(audioOutbound, "outbound audio stats が存在すること")
            let bytesSent = audioOutbound?.values["bytesSent"] as? NSNumber
            let packetsSent = audioOutbound?.values["packetsSent"] as? NSNumber
            XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
            XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
            XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が 0 より大きいこと")
            XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が 0 より大きいこと")
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }

    wait(for: [expectation], timeout: 90)
    // 切断
    if let channel = sora?.mediaChannels.first {
      disconnectAndVerify(channel: channel)
    }
  }

  // MARK: - sendrecv ダミー映像テスト

  /// sendrecv 2 台が同一チャンネルに接続し、互いの映像を送受信できることを確認する
  func testSendrecvDummyVideo() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)。
    // CI の Sora サーバーは channelId の prefix / suffix で接続を許可するため、
    // 環境変数 TEST_CHANNEL_ID_PREFIX / TEST_CHANNEL_ID_SUFFIX も組み合わせる
    let channelId = buildChannelId(unique: true)

    // 接続失敗フラグ。失敗時は後続ステップをスキップして早期に終了する
    var connectFailed = false

    // 接続完了を待つ expectation (各接続ごとに wait を分けて直列に実行する)
    let connect1Expectation = self.expectation(description: "sendrecv1 の接続が完了すること")
    let connect2Expectation = self.expectation(description: "sendrecv2 の接続が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel1: MediaChannel?
    var channel2: MediaChannel?
    var capturer1: DummyVideoCapturer?
    var capturer2: DummyVideoCapturer?

    // sendrecv1 / sendrecv2 用の Configuration
    var config1 = try buildConfiguration(role: .sendrecv)
    config1.channelId = channelId
    config1.videoEnabled = true
    config1.audioEnabled = false
    config1.videoCodec = .vp8
    config1.initialCameraEnabled = false

    var config2 = try buildConfiguration(role: .sendrecv)
    config2.channelId = channelId
    config2.videoEnabled = true
    config2.audioEnabled = false
    config2.videoCodec = .vp8
    config2.initialCameraEnabled = false

    // sendrecv1 を接続し、接続完了後に sendrecv2 を接続する (直列)
    // connect コールバックは実行キューが固定されていないため、connectFailed の更新と
    // 後続処理 (capturer 開始・sendrecv2 接続) は main queue に束ねる
    _ = sora?.connect(configuration: config1) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("sendrecv1 の接続に失敗した : \(error)")
          connectFailed = true
          connect1Expectation.fulfill()
          return
        }
        guard let channel = mediaChannel, let stream = channel.senderStream else {
          XCTFail("sendrecv1 の senderStream が nil")
          connectFailed = true
          connect1Expectation.fulfill()
          return
        }
        channel1 = channel
        let currentCapturer1 = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
        currentCapturer1.stream = stream
        currentCapturer1.start()
        capturer1 = currentCapturer1
        connect1Expectation.fulfill()

        // sendrecv2 を接続する
        _ = self.sora?.connect(configuration: config2) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            if let error2 {
              XCTFail("sendrecv2 の接続に失敗した : \(error2)")
              connectFailed = true
              connect2Expectation.fulfill()
              return
            }
            guard let channel2Unwrapped = mediaChannel2,
              let stream2 = channel2Unwrapped.senderStream
            else {
              XCTFail("sendrecv2 の senderStream が nil")
              connectFailed = true
              connect2Expectation.fulfill()
              return
            }
            channel2 = channel2Unwrapped
            let currentCapturer2 = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
            currentCapturer2.stream = stream2
            currentCapturer2.start()
            capturer2 = currentCapturer2
            connect2Expectation.fulfill()
          }
        }
      }
    }

    // 後始末: 起動済みの capturer を停止する (未起動でも Optional で安全)
    let stopCapturers: () -> Void = {
      capturer1?.stop()
      capturer2?.stop()
    }

    // 後始末: 接続済みチャンネルの切断を完了まで待つ
    // (切断が完了する前にテストが終了して、残留チャンネルの onDisconnect が次のテストに
    // 発火しないようにする)
    let disconnectAll: () -> Void = {
      for channel in [channel1, channel2] {
        guard let channel else { continue }
        // 切断済みのチャンネルでは onDisconnect が発火しないため、待たずにスキップする
        guard !channel.state.isDisconnected else { continue }
        let disconnectExpectation = self.expectation(description: "切断が完了すること")
        channel.handlers.onDisconnect = { _ in
          disconnectExpectation.fulfill()
        }
        // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
        // onDisconnect が発火済みのため、待たずにスキップする
        guard !channel.state.isDisconnected else { continue }
        channel.disconnect(error: nil)
        self.wait(for: [disconnectExpectation], timeout: 10)
      }
    }

    // sendrecv1 の接続完了を待つ
    // ConnectionTimer (Configuration.connectionTimeout = 30 秒) の発火を wait 内で処理し、
    // テスト終了後に遅延コールバックが残らないよう、wait のタイムアウトを 35 秒とする
    wait(for: [connect1Expectation], timeout: 35)
    guard !connectFailed, let channel1 else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断
      stopCapturers()
      disconnectAll()
      // sendrecv2 は接続を開始していないため、未 fulfill の expectation が残って
      // テスト終了時に unwaited expectation として報告されるのを防ぐ
      connect2Expectation.fulfill()
      return
    }
    // sendrecv2 の接続完了を待つ
    wait(for: [connect2Expectation], timeout: 35)
    guard !connectFailed, let channel2, let capturer1, let capturer2 else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断 (channel2 が接続済みなら切断する)
      stopCapturers()
      disconnectAll()
      return
    }

    // 5 秒待機後に getStats を取得し、両チャンネルの video stats を確認する
    // (受信は keyframe 供給に依存するため、リトライ付きで確認する)
    let statsExpectation = self.expectation(description: "video stats を確認できること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      self.verifyVideoStats(
        channel1: channel1,
        channel2: channel2,
        attempt: 1,
        maxAttempts: 3,
        expectation: statsExpectation)
    }
    wait(for: [statsExpectation], timeout: 30)

    // capturer がバッファ確保の連続失敗で自動停止していないかを直接確認する
    // (stats 検証の成否に関わらず実行し、失敗時の原因切り分けに役立てる)
    XCTAssertTrue(capturer1.isRunning, "DummyVideoCapturer が動作中であること")
    XCTAssertGreaterThan(capturer1.frameCount, 0, "ダミー映像フレームが送信されていること")
    XCTAssertTrue(capturer2.isRunning, "DummyVideoCapturer が動作中であること")
    XCTAssertGreaterThan(capturer2.frameCount, 0, "ダミー映像フレームが送信されていること")

    // 切断 (capturer を停止してから切断する)
    stopCapturers()
    for channel in [channel1, channel2] {
      disconnectAndVerify(channel: channel)
    }
  }

  // MARK: - simulcast ダミー映像テスト

  /// simulcast の sendonly 1 台 + recvonly 1 台で、3 レイヤー (r0 / r1 / r2) の送信と
  /// recvonly 側の受信を確認する
  func testSimulcastDummyVideo() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)。
    // CI の Sora サーバーは channelId の prefix / suffix で接続を許可するため、
    // 環境変数 TEST_CHANNEL_ID_PREFIX / TEST_CHANNEL_ID_SUFFIX も組み合わせる
    let channelId = buildChannelId(unique: true)

    // 接続失敗フラグ。失敗時は後続ステップをスキップして早期に終了する
    var connectFailed = false

    // 接続完了を待つ expectation (各接続ごとに wait を分けて直列に実行する)
    let sendonlyExpectation = self.expectation(description: "sendonly の接続が完了すること")
    let recvonlyExpectation = self.expectation(description: "recvonly の接続が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var sendonlyChannel: MediaChannel?
    var recvonlyChannel: MediaChannel?
    var capturer: DummyVideoCapturer?

    // sendonly / recvonly 用の Configuration
    // (simulcast は WrapperVideoEncoderFactory.shared.simulcastEnabled を共有するため、
    // 両チャンネルとも simulcastEnabled = true で統一する)
    var sendonlyConfig = try buildConfiguration(role: .sendonly)
    sendonlyConfig.channelId = channelId
    sendonlyConfig.simulcastEnabled = true
    sendonlyConfig.videoEnabled = true
    sendonlyConfig.audioEnabled = false
    sendonlyConfig.videoCodec = .vp8
    sendonlyConfig.initialCameraEnabled = false

    var recvonlyConfig = try buildConfiguration(role: .recvonly)
    recvonlyConfig.channelId = channelId
    recvonlyConfig.simulcastEnabled = true
    // 受信するレイヤーは r0 のみに限定する (inbound-rtp に rid がなく「レイヤー選択の動作確認」には
    // ならないため、到達の確実性が高い r0 を選択する)
    recvonlyConfig.simulcastRequestRid = .r0
    recvonlyConfig.videoEnabled = true
    recvonlyConfig.audioEnabled = false
    recvonlyConfig.videoCodec = .vp8

    // sendonly を接続し、接続完了後に recvonly を接続する (直列)
    // connect コールバックは実行キューが固定されていないため、connectFailed の更新と
    // 後続処理 (capturer 開始・recvonly 接続) は main queue に束ねる
    _ = sora?.connect(configuration: sendonlyConfig) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("sendonly の接続に失敗した : \(error)")
          connectFailed = true
          sendonlyExpectation.fulfill()
          return
        }
        guard let channel = mediaChannel, let stream = channel.senderStream else {
          XCTFail("sendonly の senderStream が nil")
          connectFailed = true
          sendonlyExpectation.fulfill()
          return
        }
        sendonlyChannel = channel
        // simulcast は 3 レイヤーを同時エンコードするため、Simulator の CPU 負荷を抑えて
        // 高解像度レイヤー (r2) がエンコードから外れないよう、frameRate を 15 に下げる
        let currentCapturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 15)
        currentCapturer.stream = stream
        currentCapturer.start()
        capturer = currentCapturer
        sendonlyExpectation.fulfill()

        // recvonly を接続する (送信しないため senderStream の確認は不要)
        _ = self.sora?.connect(configuration: recvonlyConfig) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            if let error2 {
              XCTFail("recvonly の接続に失敗した : \(error2)")
              connectFailed = true
              recvonlyExpectation.fulfill()
              return
            }
            guard let channel2 = mediaChannel2 else {
              XCTFail("recvonly のメディアチャネルが nil")
              connectFailed = true
              recvonlyExpectation.fulfill()
              return
            }
            recvonlyChannel = channel2
            recvonlyExpectation.fulfill()
          }
        }
      }
    }

    // 後始末: 起動済みの capturer を停止する (未起動でも Optional で安全)
    let stopCapturers: () -> Void = {
      capturer?.stop()
    }

    // 後始末: 接続済みチャンネルの切断を完了まで待つ
    // (切断が完了する前にテストが終了して、残留チャンネルの onDisconnect が次のテストに
    // 発火しないようにする)
    let disconnectAll: () -> Void = {
      for channel in [sendonlyChannel, recvonlyChannel] {
        guard let channel else { continue }
        // 切断済みのチャンネルでは onDisconnect が発火しないため、待たずにスキップする
        guard !channel.state.isDisconnected else { continue }
        let disconnectExpectation = self.expectation(description: "切断が完了すること")
        channel.handlers.onDisconnect = { _ in
          disconnectExpectation.fulfill()
        }
        // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
        // onDisconnect が発火済みのため、待たずにスキップする
        guard !channel.state.isDisconnected else { continue }
        channel.disconnect(error: nil)
        self.wait(for: [disconnectExpectation], timeout: 10)
      }
    }

    // sendonly の接続完了を待つ
    // ConnectionTimer (Configuration.connectionTimeout = 30 秒) の発火を wait 内で処理し、
    // テスト終了後に遅延コールバックが残らないよう、wait のタイムアウトを 35 秒とする
    wait(for: [sendonlyExpectation], timeout: 35)
    guard !connectFailed, let sendonlyChannel else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断
      stopCapturers()
      disconnectAll()
      // recvonly は接続を開始していないため、未 fulfill の expectation が残って
      // テスト終了時に unwaited expectation として報告されるのを防ぐ
      recvonlyExpectation.fulfill()
      return
    }
    // recvonly の接続完了を待つ
    wait(for: [recvonlyExpectation], timeout: 35)
    guard !connectFailed, let recvonlyChannel, let capturer else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断
      stopCapturers()
      disconnectAll()
      return
    }

    // 5 秒待機後に getStats を取得し、simulcast の video stats を確認する
    // (受信は keyframe 供給に依存し、高解像度レイヤーのエンコード開始は CPU 負荷の影響を
    // 受けるため、リトライ付きで確認する)
    let statsExpectation = self.expectation(description: "simulcast の video stats を確認できること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      self.verifySimulcastStats(
        sendonlyChannel: sendonlyChannel,
        recvonlyChannel: recvonlyChannel,
        attempt: 1,
        maxAttempts: 5,
        expectation: statsExpectation)
    }
    wait(for: [statsExpectation], timeout: 30)

    // capturer がバッファ確保の連続失敗で自動停止していないかを直接確認する
    // (stats 検証の成否に関わらず実行し、失敗時の原因切り分けに役立てる)
    XCTAssertTrue(capturer.isRunning, "DummyVideoCapturer が動作中であること")
    XCTAssertGreaterThan(capturer.frameCount, 0, "ダミー映像フレームが送信されていること")

    // 切断 (capturer を停止してから切断する)
    stopCapturers()
    for channel in [sendonlyChannel, recvonlyChannel] {
      disconnectAndVerify(channel: channel)
    }
  }

  /// 両チャンネルの video stats を検証する (5 秒間隔で最大 maxAttempts 回リトライする)
  ///
  /// 映像の受信は送信側エンコーダが最初の keyframe を送出するまで受信パケットが存在しないため、
  /// 両チャンネルの inbound-rtp で bytesReceived / packetsReceived が 0 より大きいことを確認できた
  /// 時点で打ち切り、codec / outbound の検証を行う。
  ///
  /// このヘルパーは main queue 上で実行される。2 本の getStats コールバックは実行キューが固定されて
  /// いないため、completedCount / stats1 / stats2 / statsFailures の更新は main queue に束ねて
  /// データ競合を防ぐ。
  private func verifyVideoStats(
    channel1: MediaChannel,
    channel2: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    expectation: XCTestExpectation
  ) {
    var completedCount = 0
    var stats1: Statistics?
    var stats2: Statistics?
    // getStats の失敗理由を保持する (一時的な failure は次のリトライで回復し得るため、
    // 上限到達時にこの内容を診断メッセージとして出力する)
    var statsFailures: [String] = []

    // 両チャンネルの getStats の完了を待ち合わせる (カウンタ方式)
    let check: () -> Void = {
      completedCount += 1
      guard completedCount == 2 else { return }

      // 両チャンネルの getStats が成功し、両方の inbound が確認できた場合は成功
      if statsFailures.isEmpty, let stats1, let stats2 {
        let inboundOK1 = self.hasInboundVideo(stats: stats1)
        let inboundOK2 = self.hasInboundVideo(stats: stats2)
        if inboundOK1 && inboundOK2 {
          // リトライ成功時に codec / outbound の検証を一度だけ行う
          self.verifyVideoCodecAndOutbound(stats: stats1, channel: channel1)
          self.verifyVideoCodecAndOutbound(stats: stats2, channel: channel2)
          expectation.fulfill()
          return
        }
      }

      // getStats の failure は getStats 実行中の接続状態の遷移 (切断・チャンネル再生成等) が
      // 原因で発生し得るため、inbound 未達と同様にリトライする。上限に達した場合は失敗とする
      if attempt >= maxAttempts {
        if !statsFailures.isEmpty {
          XCTFail("getStats に失敗した : \(statsFailures.joined(separator: "、"))")
        } else {
          // 最後に観測した受信量を出力し、原因切り分けに役立てる
          let inbound1 = self.inboundVideoByteCounts(stats: stats1)
          let inbound2 = self.inboundVideoByteCounts(stats: stats2)
          XCTFail(
            "\(maxAttempts) 回試行しても両チャンネルの inbound video を確認できなかった"
              + " (sendrecv1: \(inbound1.bytesReceived) bytes / \(inbound1.packetsReceived) packets 、"
              + "sendrecv2: \(inbound2.bytesReceived) bytes / \(inbound2.packetsReceived) packets)")
        }
        expectation.fulfill()
      } else {
        // keyframe 到着を待つため、5 秒後に再試行する
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self.verifyVideoStats(
            channel1: channel1,
            channel2: channel2,
            attempt: attempt + 1,
            maxAttempts: maxAttempts,
            expectation: expectation)
        }
      }
    }

    channel1.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          stats1 = stats
          check()
        case .failure(let error):
          statsFailures.append("sendrecv1 の getStats に失敗した (\(error))")
          check()
        }
      }
    }
    channel2.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          stats2 = stats
          check()
        case .failure(let error):
          statsFailures.append("sendrecv2 の getStats に失敗した (\(error))")
          check()
        }
      }
    }
  }

  /// inbound-rtp (video) の bytesReceived / packetsReceived を返す (存在しない場合は 0)
  private func inboundVideoByteCounts(stats: Statistics?) -> (
    bytesReceived: Int, packetsReceived: Int
  ) {
    let inbound = stats?.entries.first {
      $0.type == "inbound-rtp"
        && ($0.values["kind"] as? NSString) == "video"
    }
    return (
      bytesReceived: (inbound?.values["bytesReceived"] as? NSNumber)?.intValue ?? 0,
      packetsReceived: (inbound?.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
    )
  }

  /// inbound-rtp (video) の bytesReceived / packetsReceived が 0 より大きいかを確認する
  private func hasInboundVideo(stats: Statistics) -> Bool {
    let counts = inboundVideoByteCounts(stats: stats)
    return counts.bytesReceived > 0 && counts.packetsReceived > 0
  }

  /// video codec stats (VP8) と outbound-rtp (video) の stats を検証する
  private func verifyVideoCodecAndOutbound(stats: Statistics, channel: MediaChannel) {
    XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")

    let codec = stats.entries.first {
      $0.type == "codec"
        && ($0.values["mimeType"] as? NSString) == "video/VP8"
    }
    XCTAssertNotNil(codec, "video codec stats (VP8) が存在すること")

    let outbound = stats.entries.first {
      $0.type == "outbound-rtp"
        && ($0.values["kind"] as? NSString) == "video"
    }
    XCTAssertNotNil(outbound, "outbound video stats が存在すること")
    let bytesSent = outbound?.values["bytesSent"] as? NSNumber
    let packetsSent = outbound?.values["packetsSent"] as? NSNumber
    XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
    XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
    XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が 0 より大きいこと")
    XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が 0 より大きいこと")
  }

  // MARK: - simulcast 検証ヘルパー

  /// outbound-rtp (video) の rid ごとの送信量と scalabilityMode を返す
  private func simulcastOutboundVideoStats(stats: Statistics) -> [(
    rid: String, bytesSent: Int, packetsSent: Int, scalabilityMode: String
  )] {
    stats.entries.compactMap { entry in
      guard entry.type == "outbound-rtp",
        (entry.values["kind"] as? NSString) == "video",
        let rid = entry.values["rid"] as? String
      else {
        return nil
      }
      return (
        rid: rid,
        bytesSent: (entry.values["bytesSent"] as? NSNumber)?.intValue ?? 0,
        packetsSent: (entry.values["packetsSent"] as? NSNumber)?.intValue ?? 0,
        scalabilityMode: (entry.values["scalabilityMode"] as? String) ?? ""
      )
    }
  }

  /// 3 レイヤー (r0 / r1 / r2) の outbound-rtp がすべて存在し、送信量が 0 より大きいかを確認する
  private func hasSimulcastOutboundVideo(stats: Statistics) -> Bool {
    let outbounds = simulcastOutboundVideoStats(stats: stats)
    let rids = Set(outbounds.map(\.rid))
    return rids == Set(["r0", "r1", "r2"])
      && outbounds.allSatisfy { $0.bytesSent > 0 && $0.packetsSent > 0 }
  }

  /// simulcast の video stats を検証する (5 秒間隔で最大 maxAttempts 回リトライする)
  ///
  /// sendonly 側は outbound-rtp を rid (r0 / r1 / r2) ごとに、recvonly 側は inbound-rtp の
  /// 受信量を確認する。両方確認できた時点で打ち切り、codec / scalabilityMode の検証を行う。
  ///
  /// このヘルパーは main queue 上で実行される。2 本の getStats コールバックは実行キューが
  /// 固定されていないため、completedCount / sendonlyStats / recvonlyStats / statsFailures の
  /// 更新は main queue に束ねてデータ競合を防ぐ。
  private func verifySimulcastStats(
    sendonlyChannel: MediaChannel,
    recvonlyChannel: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    expectation: XCTestExpectation
  ) {
    var completedCount = 0
    var sendonlyStats: Statistics?
    var recvonlyStats: Statistics?
    // getStats の失敗理由を保持する (一時的な failure は次のリトライで回復し得るため、
    // 上限到達時にこの内容を診断メッセージとして出力する)
    var statsFailures: [String] = []

    // 両チャンネルの getStats の完了を待ち合わせる (カウンタ方式)
    let check: () -> Void = {
      completedCount += 1
      guard completedCount == 2 else { return }

      // 両チャンネルの getStats が成功し、sendonly の 3 レイヤー送信と recvonly の
      // 受信が確認できた場合は成功
      if statsFailures.isEmpty, let sendonlyStats, let recvonlyStats {
        let sendonlyOK = self.hasSimulcastOutboundVideo(stats: sendonlyStats)
        let recvonlyOK = self.hasInboundVideo(stats: recvonlyStats)
        if sendonlyOK && recvonlyOK {
          // リトライ成功時に codec / scalabilityMode の検証を一度だけ行う
          self.verifySimulcastCodecAndOutbound(stats: sendonlyStats)
          expectation.fulfill()
          return
        }
      }

      // getStats の failure は getStats 実行中の接続状態の遷移 (切断・チャンネル再生成等) が
      // 原因で発生し得るため、検証未達と同様にリトライする。上限に達した場合は失敗とする
      if attempt >= maxAttempts {
        if !statsFailures.isEmpty {
          XCTFail("getStats に失敗した : \(statsFailures.joined(separator: "、"))")
        } else {
          // 最後に観測した送受信量を出力し、原因切り分けに役立てる
          let sendonlyCounts =
            sendonlyStats.map { self.simulcastOutboundVideoStats(stats: $0) } ?? []
          let recvonlyCounts = self.inboundVideoByteCounts(stats: recvonlyStats)
          XCTFail(
            "\(maxAttempts) 回試行しても simulcast の video stats を確認できなかった"
              + " (sendonly: \(sendonlyCounts.map { "\($0.rid)=\($0.bytesSent)/\($0.packetsSent)" }.joined(separator: "、"))、"
              + "recvonly: \(recvonlyCounts.bytesReceived) bytes / \(recvonlyCounts.packetsReceived) packets)"
          )
        }
        expectation.fulfill()
      } else {
        // keyframe 到着を待つため、5 秒後に再試行する
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self.verifySimulcastStats(
            sendonlyChannel: sendonlyChannel,
            recvonlyChannel: recvonlyChannel,
            attempt: attempt + 1,
            maxAttempts: maxAttempts,
            expectation: expectation)
        }
      }
    }

    sendonlyChannel.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          sendonlyStats = stats
          check()
        case .failure(let error):
          statsFailures.append("sendonly の getStats に失敗した (\(error))")
          check()
        }
      }
    }
    recvonlyChannel.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          recvonlyStats = stats
          check()
        case .failure(let error):
          statsFailures.append("recvonly の getStats に失敗した (\(error))")
          check()
        }
      }
    }
  }

  /// simulcast の codec stats (VP8) と各レイヤーの scalabilityMode を検証する
  private func verifySimulcastCodecAndOutbound(stats: Statistics) {
    let codec = stats.entries.first {
      $0.type == "codec"
        && ($0.values["mimeType"] as? NSString) == "video/VP8"
    }
    XCTAssertNotNil(codec, "video codec stats (VP8) が存在すること")

    for outbound in simulcastOutboundVideoStats(stats: stats) {
      XCTAssertEqual(
        outbound.scalabilityMode, "L1T1",
        "\(outbound.rid) の scalabilityMode が L1T1 であること")
    }
  }
}
