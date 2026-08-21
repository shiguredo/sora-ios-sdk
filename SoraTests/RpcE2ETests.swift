import XCTest

@testable @preconcurrency import Sora

/// RPC E2E テスト
final class RpcE2ETests: E2ETestBase {
  /// recvonly クライアントが RPC (RequestSimulcastRid) で受信 rid を切り替えられることを確認する
  func testRequestSimulcastRid() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)
    let channelId = buildChannelId(unique: true)

    // 接続完了・switched 受信・rpc ラベル OPEN・シナリオ完了を待つ expectation
    let sendonlyExpectation = self.expectation(description: "sendonly の接続が完了すること")
    let recvonlyExpectation = self.expectation(description: "recvonly の接続が完了すること")
    let switchedExpectation = self.expectation(description: "recvonly が switched を受信すること")
    let rpcOpenedExpectation = self.expectation(description: "recvonly の rpc ラベルが OPEN すること")
    let scenarioExpectation = self.expectation(description: "RPC の rid 切替シナリオが完了すること")

    // 接続済みチャンネルと capturer を保持する (後始末に使用する)
    var sendonlyChannel: MediaChannel?
    var recvonlyChannel: MediaChannel?
    var capturer: DummyVideoCapturer?

    // recvonly の offer に期待する要素が含まれるかを記録する
    var offerContainsRPCLabel = false
    var offerContainsRPCMethod = false
    var offerEnablesSimulcast = false

    // expectation の二重 fulfill を防ぐためのフラグ
    var switchedExpectationFulfilled = false
    var rpcOpenedExpectationFulfilled = false
    var scenarioExpectationFulfilled = false

    // 非同期シナリオの終了理由を保持する
    var skipReason: String?

    // 失敗・スキップ時の共通後始末: 接続済みチャンネルの切断と、expectation の drain。
    // (XCTWaiter.wait は fulfill 済みの expectation を即座に返すため、全 expectation を
    // 渡してよい。テスト終了時の unwaited expectation 報告を防ぐ)
    let cleanupChannels: () -> Void = {
      self.disconnectAll(channels: [sendonlyChannel, recvonlyChannel])
      _ = XCTWaiter.wait(
        for: [
          recvonlyExpectation, switchedExpectation, rpcOpenedExpectation, scenarioExpectation,
        ],
        timeout: 0)
    }

    var sendonlyConfig = try buildConfiguration(role: .sendonly)
    sendonlyConfig.channelId = channelId
    sendonlyConfig.simulcastEnabled = true
    sendonlyConfig.audioEnabled = false
    sendonlyConfig.videoCodec = .vp8
    sendonlyConfig.videoBitRate = 1200
    sendonlyConfig.initialCameraEnabled = false

    var recvonlyConfig = try buildConfiguration(role: .recvonly)
    recvonlyConfig.channelId = channelId
    recvonlyConfig.simulcastEnabled = true
    recvonlyConfig.simulcastRequestRid = .r2
    recvonlyConfig.dataChannelSignaling = true
    recvonlyConfig.ignoreDisconnectWebSocket = true
    recvonlyConfig.audioEnabled = false
    recvonlyConfig.videoCodec = .vp8

    struct RPCTestMetadata: Encodable {
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let access_token: String
    }
    let recvonlyAccessToken = try buildJWTAccessToken(
      channelId: channelId,
      privateClaims: [
        "rpc_methods": [RequestSimulcastRid.name],
        "simulcast": true,
        "simulcast_request_rid": "r2",
        "simulcast_rpc_rids": ["none", "r0", "r1", "r2"],
      ])
    recvonlyConfig.signalingConnectMetadata = RPCTestMetadata(access_token: recvonlyAccessToken)

    // ハンドラは connect 呼び出しより前に登録する。recvonly 側の offer / switched / rpc OPEN を監視する
    recvonlyConfig.mediaChannelHandlers.onReceiveSignalingJSON = { json in
      DispatchQueue.main.async {
        guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return
        }

        if dict["type"] as? String == "offer" {
          if let dataChannels = dict["data_channels"] as? [[String: Any]] {
            offerContainsRPCLabel = dataChannels.contains { ($0["label"] as? String) == "rpc" }
          }
          if let rpcMethods = dict["rpc_methods"] as? [String] {
            offerContainsRPCMethod = rpcMethods.contains(RequestSimulcastRid.name)
          }
          offerEnablesSimulcast = (dict["simulcast"] as? Bool) ?? false
        }

        if dict["type"] as? String == "switched", !switchedExpectationFulfilled {
          switchedExpectationFulfilled = true
          switchedExpectation.fulfill()
        }
      }
    }
    recvonlyConfig.mediaChannelHandlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        guard label == "rpc", !rpcOpenedExpectationFulfilled else { return }
        rpcOpenedExpectationFulfilled = true
        rpcOpenedExpectation.fulfill()
      }
    }

    // sendonly を接続し、接続完了後に recvonly を接続する (直列)
    _ = sora?.connect(configuration: sendonlyConfig) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("sendonly の接続に失敗した : \(error)")
          sendonlyExpectation.fulfill()
          return
        }
        guard let channel = mediaChannel, let stream = channel.senderStream else {
          XCTFail("sendonly の senderStream が nil")
          sendonlyExpectation.fulfill()
          return
        }
        sendonlyChannel = channel
        // simulcast の 3 レイヤーを安定して生成しやすいよう、既存 simulcast E2E と同じ条件で
        // ダミー映像を作成する。RPC 準備が整うまでは start しない
        let currentCapturer = DummyVideoCapturer(width: 960, height: 540, frameRate: 15)
        currentCapturer.stream = stream
        capturer = currentCapturer
        sendonlyExpectation.fulfill()

        _ = self.sora?.connect(configuration: recvonlyConfig) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            if let error2 {
              XCTFail("recvonly の接続に失敗した : \(error2)")
              recvonlyExpectation.fulfill()
              return
            }
            guard let channel2 = mediaChannel2 else {
              XCTFail("recvonly のメディアチャネルが nil")
              recvonlyExpectation.fulfill()
              return
            }
            recvonlyChannel = channel2
            recvonlyExpectation.fulfill()
          }
        }
      }
    }

    // 接続完了を待つ
    wait(for: [sendonlyExpectation], timeout: 35)
    guard let sendonlyChannel else {
      cleanupChannels()
      return
    }
    wait(for: [recvonlyExpectation], timeout: 35)
    guard let recvonlyChannel, let capturer else {
      cleanupChannels()
      return
    }

    // switched 受信を待ち、offer の rpc / simulcast 判定結果を確認する。
    // offer と switched は同じ直列キュー (SignalingChannel.queue) から main queue に
    // エンキューされるため FIFO 順序が保証され、switched の処理完了時点で offer の
    // フラグ書き込みも完了している (テストハンドラは main queue に束ねられている)
    let switchedResult = XCTWaiter.wait(for: [switchedExpectation], timeout: 10)
    guard switchedResult == .completed else {
      XCTFail("switched メッセージを受信できなかった")
      cleanupChannels()
      return
    }
    guard offerContainsRPCLabel, offerContainsRPCMethod, offerEnablesSimulcast else {
      cleanupChannels()
      if !offerContainsRPCLabel {
        throw XCTSkip("Sora サーバーが rpc ラベルの DataChannel を払い出さないためスキップします")
      }
      if !offerContainsRPCMethod {
        throw XCTSkip("Sora サーバーが RequestSimulcastRid を rpc_methods に含めないためスキップします")
      }
      throw XCTSkip("Sora サーバーが simulcast を有効にしないためスキップします")
    }

    // rpc() が rpcUnavailable にならないよう、rpc ラベルの OPEN を待つ
    let rpcOpenedResult = XCTWaiter.wait(for: [rpcOpenedExpectation], timeout: 10)
    guard rpcOpenedResult == .completed else {
      XCTFail("rpc ラベルの DataChannel が OPEN しなかった")
      cleanupChannels()
      return
    }

    // RPC / stats 検証のシナリオを開始する。以後の非同期分岐は finishScenario から収束させる
    let finishScenario: (_ failureMessage: String?, _ reasonToSkip: String?) -> Void = {
      failureMessage, reasonToSkip in
      guard !scenarioExpectationFulfilled else { return }
      scenarioExpectationFulfilled = true
      if let failureMessage {
        XCTFail(failureMessage)
      }
      skipReason = reasonToSkip
      scenarioExpectation.fulfill()
    }

    capturer.start()
    waitForOutboundR0AndR2(
      channel: sendonlyChannel,
      attempt: 1,
      maxAttempts: 5
    ) { outboundResult in
      switch outboundResult {
      case .failure(let message):
        finishScenario(message, nil)
      case .skipped(let reason):
        finishScenario(nil, reason)
      case .success:
        self.waitForStableInboundFrameSize(
          channel: recvonlyChannel,
          attempt: 1,
          maxAttempts: 10
        ) { stableResult in
          switch stableResult {
          case .failure(let message):
            finishScenario(message, nil)
          case .success(let initialSize):
            self.callRequestSimulcastRid(channel: recvonlyChannel, rid: .r0) { rpcResult in
              switch rpcResult {
              case .failure(let error):
                finishScenario("r0 への RPC 呼び出しに失敗した : \(error)", nil)
              case .success(let result):
                XCTAssertEqual(result.rid, .r0, "RPC 応答の rid が r0 であること")
                self.waitForInboundFrameSize(
                  channel: recvonlyChannel,
                  attempt: 1,
                  maxAttempts: 10,
                  condition: InboundFrameSizeCondition(
                    predicate: { size in
                      size.width > 0 && size.height > 0
                        && size.width < initialSize.width && size.height < initialSize.height
                    },
                    failureDescription: { lastSize in
                      "r0 切替後も frameWidth / frameHeight が初期解像度より小さくならなかった"
                        + " (initial: \(initialSize.width)x\(initialSize.height)、"
                        + "last: \(lastSize.width)x\(lastSize.height)、"
                        + "bytesReceived: \(lastSize.bytesReceived))"
                    }
                  )
                ) { r0Result in
                  switch r0Result {
                  case .failure(let message):
                    finishScenario(message, nil)
                  case .success(let r0Size):
                    // r0 の解像度が初期解像度 (r2) より小さいことは predicate で保証済み
                    self.callRequestSimulcastRid(channel: recvonlyChannel, rid: .r2) { rpcResult2 in
                      switch rpcResult2 {
                      case .failure(let error):
                        finishScenario("r2 への RPC 呼び出しに失敗した : \(error)", nil)
                      case .success(let result2):
                        XCTAssertEqual(result2.rid, .r2, "RPC 応答の rid が r2 であること")
                        self.waitForInboundFrameSize(
                          channel: recvonlyChannel,
                          attempt: 1,
                          maxAttempts: 10,
                          condition: InboundFrameSizeCondition(
                            predicate: { size in
                              size.width > 0 && size.height > 0
                                && size.width > r0Size.width && size.height > r0Size.height
                            },
                            failureDescription: { lastSize in
                              "r2 復帰後も frameWidth / frameHeight が r0 より大きくならなかった"
                                + " (r0: \(r0Size.width)x\(r0Size.height)、"
                                + "last: \(lastSize.width)x\(lastSize.height)、"
                                + "bytesReceived: \(lastSize.bytesReceived))"
                            }
                          )
                        ) { r2Result in
                          switch r2Result {
                          case .failure(let message):
                            finishScenario(message, nil)
                          case .success:
                            // r2 の解像度が r0 より大きいことは predicate で保証済み
                            finishScenario(nil, nil)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    // シナリオの最悪系所要時間 (ポーリング等の合計約 120〜150 秒) を吸収できるよう、
    // タイムアウトは 150 秒とする
    wait(for: [scenarioExpectation], timeout: 150)

    // 後始末
    capturer.stop()
    for channel in [sendonlyChannel, recvonlyChannel] {
      disconnectAndVerify(channel: channel)
    }

    if let skipReason {
      throw XCTSkip(skipReason)
    }
  }

  // MARK: - RPC

  /// RequestSimulcastRid を呼び出し、結果を main queue に返す
  private func callRequestSimulcastRid(
    channel: MediaChannel,
    rid: Rid,
    completion: @escaping (Result<RequestSimulcastRidResult, Error>) -> Void
  ) {
    Task {
      do {
        guard
          let response = try await channel.rpc(
            method: RequestSimulcastRid.self,
            params: RequestSimulcastRidParams(rid: rid))
        else {
          throw SoraError.rpcDecodingError(reason: "RPC レスポンスが nil")
        }
        DispatchQueue.main.async {
          completion(.success(response.result))
        }
      } catch {
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }
  }

  // MARK: - Stats ヘルパー

  /// inbound-rtp (video) の解像度と受信量
  private struct InboundVideoFrameSize {
    let width: Int
    let height: Int
    let bytesReceived: Int
    let packetsReceived: Int
  }

  /// inbound-rtp の解像度待機条件 (判定と失敗メッセージを対で保持する)
  private struct InboundFrameSizeCondition {
    let predicate: (InboundVideoFrameSize) -> Bool
    let failureDescription: (InboundVideoFrameSize) -> String
  }

  /// sendonly の outbound-rtp で r0 / r2 が立ち上がるまで待つ
  private func waitForOutboundR0AndR2(
    channel: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    getStatsFailures: [String] = [],
    completion: @escaping (OutboundRidCheckResult) -> Void
  ) {
    channel.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .failure(let error):
          // getStats の failure は getStats 実行中の接続状態の遷移 (切断・チャンネル再生成等) が
          // 原因で発生し得るため、即失敗とせずにリトライする (SimulcastE2ETests と同じ方針)。
          // 上限到達時に failure が残っていた場合のみ失敗とする
          var failures = getStatsFailures
          failures.append("sendonly の getStats に失敗した : \(error)")
          if attempt >= maxAttempts {
            completion(.failure(failures.joined(separator: "、")))
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.waitForOutboundR0AndR2(
              channel: channel,
              attempt: attempt + 1,
              maxAttempts: maxAttempts,
              getStatsFailures: failures,
              completion: completion)
          }
        case .success(let stats):
          let outbounds = self.simulcastOutboundVideoStats(stats: stats)
          let r0Active = outbounds.contains { $0.rid == "r0" && $0.bytesSent > 0 }
          let r2Active = outbounds.contains { $0.rid == "r2" && $0.bytesSent > 0 }
          if r0Active && r2Active {
            completion(.success)
            return
          }
          if attempt >= maxAttempts {
            // getStats の failure が記録されていた場合は失敗、なければ rid 未立ち上がりとして
            // スキップする
            if !getStatsFailures.isEmpty {
              completion(.failure(getStatsFailures.joined(separator: "、")))
              return
            }
            // outbounds が空 (outbound-rtp の video エントリが取得できない) 場合は、
            // 診断情報が失われないよう空文字ではなく明示する
            let details =
              outbounds.isEmpty
              ? "outbound-rtp の video エントリが取得できなかった"
              : outbounds.map { "\($0.rid)=\($0.bytesSent)/\($0.packetsSent)" }.joined(
                separator: "、")
            completion(
              .skipped("r0 / r2 の両方が立ち上がらなかったためスキップします (\(details))"))
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.waitForOutboundR0AndR2(
              channel: channel,
              attempt: attempt + 1,
              maxAttempts: maxAttempts,
              getStatsFailures: getStatsFailures,
              completion: completion)
          }
        }
      }
    }
  }

  /// inbound-rtp (video) の frameWidth / frameHeight が安定して取得できるまで待つ
  private func waitForStableInboundFrameSize(
    channel: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    completion: @escaping (InboundFrameSizeResult) -> Void
  ) {
    fetchInboundVideoFrameSize(channel: channel) { firstResult in
      switch firstResult {
      case .failure(let message):
        completion(.failure(message))
      case .success(let firstSize):
        guard firstSize.width > 0, firstSize.height > 0 else {
          if attempt >= maxAttempts {
            completion(
              .failure(
                "inbound-rtp の frameWidth / frameHeight が取得できなかった"
                  + " (bytesReceived: \(firstSize.bytesReceived)、"
                  + "packetsReceived: \(firstSize.packetsReceived))"))
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForStableInboundFrameSize(
              channel: channel,
              attempt: attempt + 1,
              maxAttempts: maxAttempts,
              completion: completion)
          }
          return
        }

        // 初回観測が一時的なフォールバック解像度でないことを確認するため、3 秒後に再サンプルする
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
          self.fetchInboundVideoFrameSize(channel: channel) { secondResult in
            switch secondResult {
            case .failure(let message):
              completion(.failure(message))
            case .success(let secondSize):
              if secondSize.width == firstSize.width, secondSize.height == firstSize.height {
                completion(.success(secondSize))
              } else if attempt >= maxAttempts {
                completion(
                  .failure(
                    "初期解像度が安定しなかった"
                      + " (first: \(firstSize.width)x\(firstSize.height)、"
                      + "second: \(secondSize.width)x\(secondSize.height))"))
              } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                  self.waitForStableInboundFrameSize(
                    channel: channel,
                    attempt: attempt + 1,
                    maxAttempts: maxAttempts,
                    completion: completion)
                }
              }
            }
          }
        }
      }
    }
  }

  /// inbound-rtp (video) の frameWidth / frameHeight が条件を満たすまで待つ
  private func waitForInboundFrameSize(
    channel: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    condition: InboundFrameSizeCondition,
    completion: @escaping (InboundFrameSizeResult) -> Void
  ) {
    fetchInboundVideoFrameSize(channel: channel) { result in
      switch result {
      case .failure(let message):
        completion(.failure(message))
      case .success(let size):
        if condition.predicate(size) {
          completion(.success(size))
          return
        }
        if attempt >= maxAttempts {
          completion(.failure(condition.failureDescription(size)))
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          self.waitForInboundFrameSize(
            channel: channel,
            attempt: attempt + 1,
            maxAttempts: maxAttempts,
            condition: condition,
            completion: completion)
        }
      }
    }
  }

  /// inbound-rtp (video) の frameWidth / frameHeight を取得する
  private func fetchInboundVideoFrameSize(
    channel: MediaChannel,
    attempt: Int = 1,
    maxAttempts: Int = 3,
    completion: @escaping (InboundFrameSizeResult) -> Void
  ) {
    channel.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .failure(let error):
          // getStats の failure は getStats 実行中の接続状態の遷移 (切断・チャンネル再生成等) が
          // 原因で発生し得るため、リトライする (SimulcastE2ETests と同じ方針)
          guard attempt < maxAttempts else {
            completion(.failure("recvonly の getStats に失敗した : \(error)"))
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.fetchInboundVideoFrameSize(
              channel: channel,
              attempt: attempt + 1,
              maxAttempts: maxAttempts,
              completion: completion)
          }
        case .success(let stats):
          completion(.success(self.inboundVideoFrameSize(stats: stats)))
        }
      }
    }
  }

  /// inbound-rtp (video) から frameWidth / frameHeight / 受信量を取り出す
  private func inboundVideoFrameSize(stats: Statistics) -> InboundVideoFrameSize {
    let inbound = stats.entries.first {
      $0.type == "inbound-rtp"
        && ($0.values["kind"] as? NSString) == "video"
    }
    return InboundVideoFrameSize(
      width: (inbound?.values["frameWidth"] as? NSNumber)?.intValue ?? 0,
      height: (inbound?.values["frameHeight"] as? NSNumber)?.intValue ?? 0,
      bytesReceived: (inbound?.values["bytesReceived"] as? NSNumber)?.intValue ?? 0,
      packetsReceived: (inbound?.values["packetsReceived"] as? NSNumber)?.intValue ?? 0)
  }

  /// sendonly の outbound rid 立ち上がり判定結果
  private enum OutboundRidCheckResult {
    case success
    case skipped(String)
    case failure(String)
  }

  /// inbound-rtp の解像度取得結果
  private enum InboundFrameSizeResult {
    case success(InboundVideoFrameSize)
    case failure(String)
  }
}
