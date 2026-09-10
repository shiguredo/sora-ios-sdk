import XCTest

@testable @preconcurrency import Sora

/// sendrecv ダミー映像テスト
final class SendrecvE2ETests: E2ETestBase {
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

    // sendrecv1 の接続完了を待つ
    // ConnectionTimer (Configuration.connectionTimeout = 30 秒) の発火を wait 内で処理し、
    // テスト終了後に遅延コールバックが残らないよう、wait のタイムアウトを 35 秒とする
    wait(for: [connect1Expectation], timeout: 35)
    guard !connectFailed, let channel1 else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断
      stopCapturers()
      disconnectAll(channels: [channel1, channel2])
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
      disconnectAll(channels: [channel1, channel2])
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

  // MARK: - 検証ヘルパー

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
