import XCTest

@testable @preconcurrency import Sora

/// sendonly ダミー映像・音声テスト
final class SendonlyE2ETests: E2ETestBase {
  // Sora API (DisconnectConnection) の切断が成功したかどうか (testSendonlyReconnect 用。
  // URLSession のコールバックから書き込むため、main queue に束ねた上でクラスプロパティに保持する)
  private var apiDisconnectSucceeded = false

  override func setUp() {
    super.setUp()
    apiDisconnectSucceeded = false
  }

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

  /// サーバー側からの切断後に再接続できることを確認する
  func testSendonlyReconnect() throws {
    // Sora API のエンドポイントが未設定の場合はスキップする
    guard
      let apiUrlString = ProcessInfo.processInfo.environment["TEST_API_URL"],
      !apiUrlString.isEmpty,
      let apiUrl = URL(string: apiUrlString)
    else {
      throw XCTSkip("TEST_API_URL が未設定のためスキップします")
    }

    // テスト固有の一意なチャンネル ID を生成する (Sora API は channel_id を指定するため、
    // 他テストのチャンネルを誤って切断しないよう一意化が必須)
    let channelId = buildChannelId(unique: true)

    // 初回接続・サーバー切断検知・再接続の完了を待つ expectation
    let connect1Expectation = self.expectation(description: "初回接続が完了すること")
    let disconnectExpectation = self.expectation(description: "サーバー切断を検知すること")
    let connect2Expectation = self.expectation(description: "再接続が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel1: MediaChannel?
    var channel2: MediaChannel?
    var capturer: DummyVideoCapturer?
    // 初回接続時の接続 ID とサーバー切断時の切断理由を保持する
    var connectionId1: String?
    var disconnectEvent: SoraCloseEvent?

    // sendonly 用の Configuration (channelId は一意な値に上書きする)
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = channelId
    config.videoEnabled = true
    config.audioEnabled = false
    config.videoCodec = .vp8
    config.initialCameraEnabled = false

    // 初回接続
    // connect コールバックは実行キューが固定されていないため、共有状態の更新と
    // 後続処理は main queue に束ねる
    _ = sora?.connect(configuration: config) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("初回接続に失敗した : \(error)")
          connect1Expectation.fulfill()
          return
        }
        guard let channel = mediaChannel, let stream = channel.senderStream else {
          XCTFail("初回接続の senderStream が nil")
          connect1Expectation.fulfill()
          return
        }
        channel1 = channel
        connectionId1 = channel.connectionId
        // サーバー切断を検知する onDisconnect ハンドラを設定する
        // (切断理由の確認と切断検知 expectation の fulfill のみを行う)
        channel.handlers.onDisconnect = { event in
          DispatchQueue.main.async {
            disconnectEvent = event
            disconnectExpectation.fulfill()
          }
        }
        let currentCapturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
        currentCapturer.stream = stream
        currentCapturer.start()
        capturer = currentCapturer
        connect1Expectation.fulfill()
      }
    }

    // 初回接続の完了を待つ
    wait(for: [connect1Expectation], timeout: 35)
    guard let channel1, let connectionId1 else {
      XCTFail("初回接続に失敗した")
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      // 未 fulfill の expectation を fulfill して、テスト終了時の unwaited expectation
      // 報告を防ぐ
      disconnectExpectation.fulfill()
      connect2Expectation.fulfill()
      return
    }

    // Sora API (DisconnectConnection) でサーバー側から切断する
    let apiExpectation = self.expectation(description: "Sora API の切断が成功すること")
    var request = URLRequest(url: apiUrl)
    request.httpMethod = "POST"
    request.setValue("Sora_20151104.DisconnectConnection", forHTTPHeaderField: "X-Sora-Target")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["channel_id": channelId, "connection_id": connectionId1])
    request.timeoutInterval = 10
    URLSession.shared.dataTask(with: request) { _, response, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("Sora API の呼び出しに失敗した : \(error)")
        } else if let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode)
        {
          self.apiDisconnectSucceeded = true
        } else {
          XCTFail("Sora API がエラーを返した : \(String(describing: response))")
        }
        apiExpectation.fulfill()
      }
    }.resume()
    wait(for: [apiExpectation], timeout: 10)
    guard apiDisconnectSucceeded else {
      // 後始末 (サーバー切断は発生しないため、切断検知 expectation を fulfill する)
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      disconnectExpectation.fulfill()
      connect2Expectation.fulfill()
      return
    }

    // サーバー切断の検知を待つ
    wait(for: [disconnectExpectation], timeout: 10)
    guard let disconnectEvent else {
      XCTFail("サーバー切断を検知できなかった")
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      connect2Expectation.fulfill()
      return
    }
    // 切断理由を確認する (Sora API 切断では code 1000 / reason "DISCONNECTED-API" が期待される。
    // サーバー実装依存のため、実測して確定する)
    if case .ok(let code, let reason) = disconnectEvent {
      XCTAssertEqual(code, 1000, "正常切断コードであること")
      XCTAssertEqual(reason, "DISCONNECTED-API", "切断理由が DISCONNECTED-API であること")
    } else {
      XCTFail("予期しない切断: \(disconnectEvent)")
    }

    // 1 秒待機してから再接続する (即時再接続による DUPLICATED-CHANNEL-ID レースを避ける)
    // 1 秒の待機は main RunLoop 上で行い、Thread.sleep は使用しない
    // (main RunLoop を止めると DummyVideoCapturer のフレーム送信が停止するため)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      _ = self.sora?.connect(configuration: config) { mediaChannel, error in
        DispatchQueue.main.async {
          if let error {
            XCTFail("再接続に失敗した : \(error)")
            connect2Expectation.fulfill()
            return
          }
          guard let channel = mediaChannel, let stream = channel.senderStream else {
            XCTFail("再接続の senderStream が nil")
            connect2Expectation.fulfill()
            return
          }
          channel2 = channel
          // DummyVideoCapturer を新しい senderStream に付け替える
          // (既存 capturer を再利用し、stop() → stream 差し替え → start())
          capturer?.stop()
          capturer?.stream = stream
          capturer?.start()
          connect2Expectation.fulfill()
        }
      }
    }
    // 再接続の完了を待つ
    wait(for: [connect2Expectation], timeout: 35)
    guard let channel2 else {
      XCTFail("再接続に失敗した")
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      return
    }

    // 再接続後の接続 ID が初回と異なることを確認する
    XCTAssertNotEqual(
      channel2.connectionId, connectionId1,
      "再接続後の connectionId が初回と異なること")

    // 後始末: capturer を停止し、接続済みチャンネルを切断する
    // (旧チャンネルはサーバー切断済みのため、disconnectAndVerify の state チェックでスキップされる)
    capturer?.stop()
    for channel in [channel1, channel2] {
      disconnectAndVerify(channel: channel)
    }
  }

  /// DataChannel シグナリング有効時に type: "switched" メッセージを受信し、
  /// シグナリングが WebSocket から DataChannel へ切り替わることを確認する
  func testSendonlySwitched() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)
    let channelId = buildChannelId(unique: true)

    // 接続完了・switched 受信・onDataChannel 発火を待つ expectation
    let connectExpectation = self.expectation(description: "接続が完了すること")
    let switchedExpectation = self.expectation(description: "switched メッセージを受信すること")
    let dataChannelExpectation = self.expectation(description: "onDataChannel が発火すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel: MediaChannel?
    var capturer: DummyVideoCapturer?
    // offer に data_channels フィールドが含まれるかと switched メッセージの内容を保持する
    var offerContainsDataChannels = false
    var switchedIgnoreDisconnectWebSocket: Bool?

    // sendonly 用の Configuration
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = channelId
    config.dataChannelSignaling = true
    config.ignoreDisconnectWebSocket = true
    config.videoEnabled = true
    config.audioEnabled = false
    config.videoCodec = .vp8
    config.initialCameraEnabled = false

    // ハンドラは connect 呼び出しより前に登録する (switched は接続完了より先に到着し得る)
    // onReceiveSignalingJSON は WebSocket 受信スレッドと DataChannel の delegate スレッドから
    // 呼ばれるため、共有状態の更新は main queue に束ねる
    config.mediaChannelHandlers.onReceiveSignalingJSON = { json in
      DispatchQueue.main.async {
        guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return
        }
        // offer に data_channels フィールドが含まれるかを記録する (SDK と同じキャスト判定)
        if dict["type"] as? String == "offer", dict["data_channels"] is [Any] {
          offerContainsDataChannels = true
        }
        // type: "switched" メッセージの ignore_disconnect_websocket フィールドを記録する
        if dict["type"] as? String == "switched" {
          switchedIgnoreDisconnectWebSocket = dict["ignore_disconnect_websocket"] as? Bool
          switchedExpectation.fulfill()
        }
      }
    }
    config.mediaChannelHandlers.onDataChannel = { _ in
      DispatchQueue.main.async {
        dataChannelExpectation.fulfill()
      }
    }

    // 接続する
    // connect コールバックは実行キューが固定されていないため、共有状態の更新と
    // 後続処理は main queue に束ねる
    _ = sora?.connect(configuration: config) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("接続に失敗した : \(error)")
          connectExpectation.fulfill()
          return
        }
        guard let connectedChannel = mediaChannel,
          let stream = connectedChannel.senderStream
        else {
          XCTFail("senderStream が nil")
          connectExpectation.fulfill()
          return
        }
        channel = connectedChannel
        let currentCapturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
        currentCapturer.stream = stream
        currentCapturer.start()
        capturer = currentCapturer
        connectExpectation.fulfill()
      }
    }

    // 接続完了を待つ
    wait(for: [connectExpectation], timeout: 35)
    guard let channel, let capturer else {
      XCTFail("接続に失敗した")
      disconnectAll(channels: [channel])
      // 未 fulfill の expectation を fulfill して、テスト終了時の unwaited expectation
      // 報告を防ぐ
      switchedExpectation.fulfill()
      dataChannelExpectation.fulfill()
      return
    }

    // offer に data_channels フィールドが含まれるかを確認する
    // (Sora サーバーが DataChannel シグナリング未対応の場合は XCTSkip でスキップする)
    guard offerContainsDataChannels else {
      // 残留チャンネルを残さないよう、後始末を実行してからスキップする
      capturer.stop()
      disconnectAll(channels: [channel])
      switchedExpectation.fulfill()
      dataChannelExpectation.fulfill()
      throw XCTSkip("Sora サーバーが DataChannel シグナリング未対応のためスキップします")
    }

    // type: "switched" メッセージの受信を待つ
    wait(for: [switchedExpectation], timeout: 10)
    guard let switchedIgnoreDisconnectWebSocket else {
      XCTFail("switched メッセージを受信できなかった")
      capturer.stop()
      disconnectAll(channels: [channel])
      dataChannelExpectation.fulfill()
      return
    }
    // ignore_disconnect_websocket フィールドが true であることを確認する
    XCTAssertTrue(
      switchedIgnoreDisconnectWebSocket, "ignore_disconnect_websocket が true であること")

    // onDataChannel が発火したことを確認する
    // (switched 受信時に発火し、SDK が切り替え処理を実行したことの確認になる)
    wait(for: [dataChannelExpectation], timeout: 10)

    // 後始末: capturer を停止し、チャンネルを切断する
    capturer.stop()
    disconnectAndVerify(channel: channel)
  }
}
