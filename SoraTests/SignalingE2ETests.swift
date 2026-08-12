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
              XCTFail("getStats に失敗した")
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
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)
    let channelId = "e2e-test-\(UUID().uuidString)"

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
          XCTFail("sendrecv1 の接続に失敗した: \(error)")
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
              XCTFail("sendrecv2 の接続に失敗した: \(error2)")
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
    DispatchQueue.main.async {
      let timer = Timer(timeInterval: 5, repeats: false) { _ in
        self.verifyVideoStats(
          channel1: channel1,
          channel2: channel2,
          attempt: 1,
          maxAttempts: 3,
          expectation: statsExpectation)
      }
      RunLoop.main.add(timer, forMode: .common)
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
          XCTFail("getStats に失敗した: \(statsFailures.joined(separator: "、"))")
        } else {
          // 最後に観測した受信量を出力し、原因切り分けに役立てる
          let inbound1 = self.inboundVideoByteCounts(stats: stats1)
          let inbound2 = self.inboundVideoByteCounts(stats: stats2)
          XCTFail(
            "\(maxAttempts) 回試行しても両チャンネルの inbound video を確認できなかった"
              + " (sendrecv1: \(inbound1.bytesReceived) bytes / \(inbound1.packetsReceived) packets、"
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
}
