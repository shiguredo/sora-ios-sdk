import XCTest

@testable @preconcurrency import Sora

/// simulcast ダミー映像テスト
final class SimulcastE2ETests: E2ETestBase {
  /// simulcast の sendonly 1 台 + recvonly 3 台 (r0 / r1 / r2) で、3 レイヤーの送信と
  /// 各レイヤーの受信を確認する
  func testSimulcastDummyVideo() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)。
    // CI の Sora サーバーは channelId の prefix / suffix で接続を許可するため、
    // 環境変数 TEST_CHANNEL_ID_PREFIX / TEST_CHANNEL_ID_SUFFIX も組み合わせる
    let channelId = buildChannelId(unique: true)

    // 接続失敗フラグ。失敗時は後続ステップをスキップして早期に終了する
    var connectFailed = false

    // 接続完了を待つ expectation (各接続ごとに wait を分けて直列に実行する)
    let sendonlyExpectation = self.expectation(description: "sendonly の接続が完了すること")
    let recvonlyR0Expectation = self.expectation(description: "recvonly (r0) の接続が完了すること")
    let recvonlyR1Expectation = self.expectation(description: "recvonly (r1) の接続が完了すること")
    let recvonlyR2Expectation = self.expectation(description: "recvonly (r2) の接続が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var sendonlyChannel: MediaChannel?
    var recvonlyR0Channel: MediaChannel?
    var recvonlyR1Channel: MediaChannel?
    var recvonlyR2Channel: MediaChannel?
    var capturer: DummyVideoCapturer?

    // sendonly / recvonly 用の Configuration
    // (simulcast は WrapperVideoEncoderFactory.shared.simulcastEnabled を共有するため、
    // すべてのチャンネルで simulcastEnabled = true で統一する)
    var sendonlyConfig = try buildConfiguration(role: .sendonly)
    sendonlyConfig.channelId = channelId
    sendonlyConfig.simulcastEnabled = true
    sendonlyConfig.videoEnabled = true
    sendonlyConfig.audioEnabled = false
    sendonlyConfig.videoCodec = .vp8
    // simulcast では帯域制御がレイヤーごとにビットレートを割り当てるため、無指定だと
    // 高解像度レイヤー (r2) に 0 が割り当てられエンコードされない (r2 の bytesSent が
    // 0 のままになる事象を確認済み)。ビットレートは Sora ドキュメントの simulcast の
    // 解像度とビットレートの表 (960x540 で 3 ストリームに必要な 1200 kbps) に従う
    sendonlyConfig.videoBitRate = 1200
    sendonlyConfig.initialCameraEnabled = false

    // recvonly は各レイヤー (r0 / r1 / r2) に購読者を 1 台ずつ配置する (js-sdk と同構成)。
    // 購読者のいないレイヤーは Sora サーバーがエンコードを維持しない可能性があるため
    let makeRecvonlyConfig: (SimulcastRequestRid) throws -> Configuration = { rid in
      var config = try self.buildConfiguration(role: .recvonly)
      config.channelId = channelId
      config.simulcastEnabled = true
      config.simulcastRequestRid = rid
      config.videoEnabled = true
      config.audioEnabled = false
      config.videoCodec = .vp8
      return config
    }
    let recvonlyR0Config = try makeRecvonlyConfig(.r0)
    let recvonlyR1Config = try makeRecvonlyConfig(.r1)
    let recvonlyR2Config = try makeRecvonlyConfig(.r2)

    // sendonly を接続し、接続完了後に recvonly を r0 → r1 → r2 の順で接続する (直列)
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
        // 高解像度レイヤー (r2) がエンコードから外れないよう、frameRate を 15 に下げる。
        // 送信元解像度は r2 (スケールダウンなし) の解像度になるため、js-sdk と同じ 960×540 にする
        let currentCapturer = DummyVideoCapturer(width: 960, height: 540, frameRate: 15)
        currentCapturer.stream = stream
        currentCapturer.start()
        capturer = currentCapturer
        sendonlyExpectation.fulfill()

        // recvonly (r0) を接続する (送信しないため senderStream の確認は不要)
        _ = self.sora?.connect(configuration: recvonlyR0Config) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            if let error2 {
              XCTFail("recvonly (r0) の接続に失敗した : \(error2)")
              connectFailed = true
              recvonlyR0Expectation.fulfill()
              return
            }
            guard let channel2 = mediaChannel2 else {
              XCTFail("recvonly (r0) のメディアチャネルが nil")
              connectFailed = true
              recvonlyR0Expectation.fulfill()
              return
            }
            recvonlyR0Channel = channel2
            recvonlyR0Expectation.fulfill()

            // recvonly (r1) を接続する
            _ = self.sora?.connect(configuration: recvonlyR1Config) { mediaChannel3, error3 in
              DispatchQueue.main.async {
                if let error3 {
                  XCTFail("recvonly (r1) の接続に失敗した : \(error3)")
                  connectFailed = true
                  recvonlyR1Expectation.fulfill()
                  return
                }
                guard let channel3 = mediaChannel3 else {
                  XCTFail("recvonly (r1) のメディアチャネルが nil")
                  connectFailed = true
                  recvonlyR1Expectation.fulfill()
                  return
                }
                recvonlyR1Channel = channel3
                recvonlyR1Expectation.fulfill()

                // recvonly (r2) を接続する
                _ = self.sora?.connect(configuration: recvonlyR2Config) { mediaChannel4, error4 in
                  DispatchQueue.main.async {
                    if let error4 {
                      XCTFail("recvonly (r2) の接続に失敗した : \(error4)")
                      connectFailed = true
                      recvonlyR2Expectation.fulfill()
                      return
                    }
                    guard let channel4 = mediaChannel4 else {
                      XCTFail("recvonly (r2) のメディアチャネルが nil")
                      connectFailed = true
                      recvonlyR2Expectation.fulfill()
                      return
                    }
                    recvonlyR2Channel = channel4
                    recvonlyR2Expectation.fulfill()
                  }
                }
              }
            }
          }
        }
      }
    }

    // 後始末: 起動済みの capturer を停止する (未起動でも Optional で安全)
    let stopCapturers: () -> Void = {
      capturer?.stop()
    }

    // 接続失敗時に、未 fulfill の recvonly expectation を fulfill して
    // テスト終了時の unwaited expectation 報告を防ぐ (再 fulfill は無害)
    let fulfillPendingRecvonlyExpectations: () -> Void = {
      for expectation in [recvonlyR0Expectation, recvonlyR1Expectation, recvonlyR2Expectation] {
        expectation.fulfill()
      }
    }

    // sendonly の接続完了を待つ
    // ConnectionTimer (Configuration.connectionTimeout = 30 秒) の発火を wait 内で処理し、
    // テスト終了後に遅延コールバックが残らないよう、wait のタイムアウトを 35 秒とする
    wait(for: [sendonlyExpectation], timeout: 35)
    guard !connectFailed, let sendonlyChannel else {
      // 後始末: capturer 停止 + 接続済みチャンネルの切断
      stopCapturers()
      disconnectAll(channels: [
        sendonlyChannel, recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel,
      ])
      fulfillPendingRecvonlyExpectations()
      return
    }
    // recvonly (r0) の接続完了を待つ
    wait(for: [recvonlyR0Expectation], timeout: 35)
    guard !connectFailed, let recvonlyR0Channel else {
      stopCapturers()
      disconnectAll(channels: [
        sendonlyChannel, recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel,
      ])
      fulfillPendingRecvonlyExpectations()
      return
    }
    // recvonly (r1) の接続完了を待つ
    wait(for: [recvonlyR1Expectation], timeout: 35)
    guard !connectFailed, let recvonlyR1Channel else {
      stopCapturers()
      disconnectAll(channels: [
        sendonlyChannel, recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel,
      ])
      fulfillPendingRecvonlyExpectations()
      return
    }
    // recvonly (r2) の接続完了を待つ
    wait(for: [recvonlyR2Expectation], timeout: 35)
    guard !connectFailed, let recvonlyR2Channel, let capturer else {
      stopCapturers()
      disconnectAll(channels: [
        sendonlyChannel, recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel,
      ])
      return
    }

    // 5 秒待機後に getStats を取得し、simulcast の video stats を確認する
    // (受信は keyframe 供給に依存し、高解像度レイヤーのエンコード開始は CPU 負荷の影響を
    // 受けるため、リトライ付きで確認する)
    let statsExpectation = self.expectation(description: "simulcast の video stats を確認できること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      self.verifySimulcastStats(
        sendonlyChannel: sendonlyChannel,
        recvonlyChannels: [recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel],
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
    for channel in [sendonlyChannel, recvonlyR0Channel, recvonlyR1Channel, recvonlyR2Channel] {
      disconnectAndVerify(channel: channel)
    }
  }

  // MARK: - 検証ヘルパー

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
  /// sendonly 側は outbound-rtp を rid (r0 / r1 / r2) ごとに、recvonly 側は各レイヤーの
  /// 購読チャンネルの inbound-rtp を確認する。すべて確認できた時点で打ち切り、
  /// codec / scalabilityMode の検証を行う。
  ///
  /// このヘルパーは main queue 上で実行される。複数の getStats コールバックは実行キューが
  /// 固定されていないため、completedCount / sendonlyStats / recvonlyStats / statsFailures の
  /// 更新は main queue に束ねてデータ競合を防ぐ。
  private func verifySimulcastStats(
    sendonlyChannel: MediaChannel,
    recvonlyChannels: [MediaChannel],
    attempt: Int,
    maxAttempts: Int,
    expectation: XCTestExpectation
  ) {
    var completedCount = 0
    var sendonlyStats: Statistics?
    var recvonlyStats: [Statistics?] = Array(repeating: nil, count: recvonlyChannels.count)
    // getStats の失敗理由を保持する (一時的な failure は次のリトライで回復し得るため、
    // 上限到達時にこの内容を診断メッセージとして出力する)
    var statsFailures: [String] = []

    // 全チャンネルの getStats の完了を待ち合わせる (カウンタ方式)
    let check: () -> Void = {
      completedCount += 1
      guard completedCount == 1 + recvonlyChannels.count else { return }

      // 全チャンネルの getStats が成功し、sendonly の 3 レイヤー送信と recvonly の
      // 全レイヤー受信が確認できた場合は成功
      if statsFailures.isEmpty, let sendonlyStats {
        let sendonlyOK = self.hasSimulcastOutboundVideo(stats: sendonlyStats)
        let recvonlyOK = recvonlyStats.allSatisfy { stats in
          guard let stats else { return false }
          return self.hasInboundVideo(stats: stats)
        }
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
          let recvonlyCounts = recvonlyStats.map { self.inboundVideoByteCounts(stats: $0) }
          XCTFail(
            "\(maxAttempts) 回試行しても simulcast の video stats を確認できなかった"
              + " (sendonly: \(sendonlyCounts.map { "\($0.rid)=\($0.bytesSent)/\($0.packetsSent)" }.joined(separator: "、"))、"
              + "recvonly: \(recvonlyCounts.map { "\($0.bytesReceived) bytes / \($0.packetsReceived) packets" }.joined(separator: "、")))"
          )
        }
        expectation.fulfill()
      } else {
        // keyframe 到着を待つため、5 秒後に再試行する
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self.verifySimulcastStats(
            sendonlyChannel: sendonlyChannel,
            recvonlyChannels: recvonlyChannels,
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
    for (index, channel) in recvonlyChannels.enumerated() {
      channel.getStats { result in
        DispatchQueue.main.async {
          switch result {
          case .success(let stats):
            recvonlyStats[index] = stats
            check()
          case .failure(let error):
            statsFailures.append("recvonly (r\(index)) の getStats に失敗した (\(error))")
            check()
          }
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
