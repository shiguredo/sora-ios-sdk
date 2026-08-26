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

  /// 切断ハンドラの発火順序 (onDisconnect -> onDisconnectComplete、各 1 回) を main queue 上で
  /// 最終検証する。
  /// 本テストは同期パス (切断時に非同期処理が進行していない) が対象のため、発火記録と評価が
  /// 同一スレッド (main) に束ねられ、FIFO で処理済みになってから評価される。
  /// (テストスレッドで直接評価すると、onDisconnectComplete の発火記録が未処理のまま
  /// 評価されるレースがあり、回帰を検出し損なう)
  private func verifyDisconnectOrderOnMainQueue(_ order: [String]) {
    let finalVerifyExpectation = self.expectation(
      description: "切断ハンドラの発火順序と回数の最終検証が完了すること")
    DispatchQueue.main.async {
      XCTAssertEqual(
        order, ["onDisconnect", "onDisconnectComplete"],
        "onDisconnect が onDisconnectComplete より先に各 1 回発火すること: \(order)")
      finalVerifyExpectation.fulfill()
    }
    wait(for: [finalVerifyExpectation], timeout: 10)
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

  /// ユーザー起因の切断で onDisconnect が onDisconnectComplete より先に各 1 回発火することを
  /// 確認する
  func testSendonlyDisconnectComplete() throws {
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = buildChannelId(unique: true)
    // 接続と切断のみを検証するため、音声は無効にする。
    // 映像・音声の両方を無効にすると Sora サーバーが INVALID-MESSAGE を返すため、
    // 映像は有効のままカメラの自動起動のみ無効にする (capturer は接続しない)
    config.audioEnabled = false
    config.initialCameraEnabled = false

    let connectExpectation = self.expectation(description: "接続が完了すること")
    let disconnectExpectation = self.expectation(description: "onDisconnect が発火すること")
    let disconnectCompleteExpectation = self.expectation(
      description: "onDisconnectComplete が発火すること")

    var channel1: MediaChannel?
    // 切断ハンドラの発火順序を記録する (main queue 上で追記する)
    var disconnectOrder: [String] = []
    // ユーザー起因切断で通知される SoraCloseEvent を保持する
    var disconnectEvent: SoraCloseEvent?

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("接続に失敗した : \(error)")
          connectExpectation.fulfill()
          return
        }
        guard let channel = mediaChannel else {
          XCTFail("接続した MediaChannel が nil")
          connectExpectation.fulfill()
          return
        }
        channel1 = channel
        channel.handlers.onDisconnect = { event in
          DispatchQueue.main.async {
            disconnectEvent = event
            disconnectOrder.append("onDisconnect")
            disconnectExpectation.fulfill()
          }
        }
        channel.handlers.onDisconnectComplete = {
          DispatchQueue.main.async {
            disconnectOrder.append("onDisconnectComplete")
            disconnectCompleteExpectation.fulfill()
          }
        }
        connectExpectation.fulfill()
      }
    }
    wait(for: [connectExpectation], timeout: 35)
    guard let channel1 else {
      XCTFail("接続に失敗した")
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait はタイムアウト (0 秒) でも failure を報告しない。
      // 接続失敗 (コールバックが error または nil) 時は SDK の接続が終了しているため、
      // 以降の fulfill は発生しない。タイムアウト時は接続が進行中の場合があるが、
      // ハンドラ登録は接続コールバック内で行われるため、この時点では未登録である
      _ = XCTWaiter.wait(
        for: [disconnectExpectation, disconnectCompleteExpectation], timeout: 0)
      return
    }

    // ユーザー起因の切断を実行する
    channel1.disconnect(error: nil)

    // onDisconnect と onDisconnectComplete の発火を待つ
    wait(for: [disconnectExpectation, disconnectCompleteExpectation], timeout: 10)

    // 正常切断であることを確認する
    // (ユーザー起因の disconnect(error: nil) は SoraCloseEvent.ok(code: 1000) で通知される)
    if case .ok(let code, _) = disconnectEvent {
      XCTAssertEqual(code, 1000, "正常切断コードであること")
    } else {
      XCTFail(
        "予期しない切断イベント: \(String(describing: disconnectEvent)) (期待値: .ok(code: 1000))")
    }

    verifyDisconnectOrderOnMainQueue(disconnectOrder)

    // 遅延したハンドラ発火がテスト完了後に main queue で実行されても
    // 次のテストに影響しないよう、ハンドラを解放する
    channel1.handlers.onDisconnect = nil
    channel1.handlers.onDisconnectComplete = nil
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

    // 初回接続・サーバー切断検知・切断処理完了検知・再接続の完了を待つ expectation
    let connect1Expectation = self.expectation(description: "初回接続が完了すること")
    let disconnectExpectation = self.expectation(description: "サーバー切断を検知すること")
    let disconnectCompleteExpectation = self.expectation(description: "サーバー切断の処理完了を検知すること")
    let connect2Expectation = self.expectation(description: "再接続が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel1: MediaChannel?
    var channel2: MediaChannel?
    var capturer: DummyVideoCapturer?
    // 初回接続時の接続 ID とサーバー切断時の切断理由を保持する
    var connectionId1: String?
    var disconnectEvent: SoraCloseEvent?
    // 切断ハンドラの発火順序を記録する (main queue 上で追記する)
    var disconnectOrder: [String] = []
    // disconnectCompleteExpectation の二重 fulfill を防ぐためのフラグです
    // (遅延した発火がテスト完了後に main queue で実行されても、
    // 次のテストで NSInternalInconsistencyException が発生しないようにする)
    var disconnectCompleteExpectationFulfilled = false
    func fulfillDisconnectCompleteExpectationIfNeeded() {
      if !disconnectCompleteExpectationFulfilled {
        disconnectCompleteExpectationFulfilled = true
        disconnectCompleteExpectation.fulfill()
      }
    }

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
        // (切断理由の確認、発火順序の記録、切断検知 expectation の fulfill を行う)
        channel.handlers.onDisconnect = { event in
          DispatchQueue.main.async {
            disconnectEvent = event
            disconnectOrder.append("onDisconnect")
            disconnectExpectation.fulfill()
          }
        }
        // 切断処理の完了通知を記録する (onDisconnectComplete は onDisconnect の後に発火する)
        channel.handlers.onDisconnectComplete = {
          DispatchQueue.main.async {
            disconnectOrder.append("onDisconnectComplete")
            fulfillDisconnectCompleteExpectationIfNeeded()
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
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait はタイムアウト (0 秒) でも failure を報告しない。
      // 接続失敗 (コールバックが error または nil) 時は SDK の接続が終了しているため、
      // 以降の fulfill は発生しない。タイムアウト時は接続が進行中の場合があるが、
      // ハンドラ登録は接続コールバック内で行われるため、この時点では未登録である
      _ = XCTWaiter.wait(
        for: [disconnectExpectation, disconnectCompleteExpectation, connect2Expectation],
        timeout: 0)
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
      // 後始末 (サーバー切断は発生しないため、切断検知 expectation を wait 済みにする)
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait は fulfill を行わないため、ここで二重に fulfill される
      // ことはない。未 fulfill のままでもタイムアウト (0 秒) は failure を報告しない。
      // disconnectAll はこのテスト側の onDisconnect ハンドラを上書きするため、
      // disconnectExpectation は未 fulfill のまま渡る (タイムアウト 0 秒は無害)
      _ = XCTWaiter.wait(
        for: [disconnectExpectation, disconnectCompleteExpectation, connect2Expectation],
        timeout: 0)
      return
    }

    // サーバー切断の検知を待つ
    wait(for: [disconnectExpectation], timeout: 10)
    guard let disconnectEvent else {
      XCTFail("サーバー切断を検知できなかった")
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait は fulfill を行わないため、ここで二重に fulfill される
      // ことはない。未 fulfill のままでもタイムアウト (0 秒) は failure を報告しない。
      // disconnectAll はこのテスト側の onDisconnect ハンドラを上書きするため、
      // disconnectExpectation は未 fulfill のまま渡る (タイムアウト 0 秒は無害)
      _ = XCTWaiter.wait(
        for: [disconnectExpectation, disconnectCompleteExpectation, connect2Expectation],
        timeout: 0)
      return
    }
    // 切断理由を確認する (Sora API 切断では code 1000 / reason "DISCONNECTED-API" が期待される。
    // サーバー実装依存のため、実測して確定する)
    if case .ok(let code, let reason) = disconnectEvent {
      XCTAssertEqual(code, 1000, "正常切断コードであること")
      XCTAssertEqual(reason, "DISCONNECTED-API", "切断理由が DISCONNECTED-API であること")
    } else {
      XCTFail("予期しない切断: \(disconnectEvent) (期待値: .ok(code: 1000))")
      // 後続アサーションで失敗を重ねないよう、後始末して終了する
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      _ = XCTWaiter.wait(
        for: [disconnectCompleteExpectation, connect2Expectation], timeout: 0)
      return
    }

    // 切断処理の完了通知 (onDisconnectComplete) を待つ
    // (即時再接続による DUPLICATED-CHANNEL-ID レース回避のための 1 秒待機を、
    // クライアント側で確認できる切断処理の完了に置き換える)
    wait(for: [disconnectCompleteExpectation], timeout: 10)

    verifyDisconnectOrderOnMainQueue(disconnectOrder)

    DispatchQueue.main.async {
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
    // 遅延したハンドラ発火がテスト完了後に main queue で実行されても
    // 次のテストに影響しないよう、ハンドラを解放してから切断する
    channel1.handlers.onDisconnect = nil
    channel1.handlers.onDisconnectComplete = nil
    channel2.handlers.onDisconnect = nil
    channel2.handlers.onDisconnectComplete = nil
    for channel in [channel1, channel2] {
      disconnectAndVerify(channel: channel)
    }
  }

  /// DataChannel シグナリング有効時に type: "switched" メッセージを受信し、
  /// シグナリングが WebSocket から DataChannel へ切り替わることを確認する
  func testSendonlySwitched() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)
    let channelId = buildChannelId(unique: true)

    // 接続完了・switched 受信・onDataChannel 発火・signaling ラベルの OPEN を待つ expectation
    let connectExpectation = self.expectation(description: "接続が完了すること")
    let switchedExpectation = self.expectation(description: "switched メッセージを受信すること")
    let dataChannelExpectation = self.expectation(
      description: "メッセージング用ラベルの DataChannel がすべて OPEN になった後に onDataChannel が発火すること")
    let signalingOpenedExpectation = self.expectation(
      description: "signaling ラベルの DataChannel が OPEN すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel: MediaChannel?
    var capturer: DummyVideoCapturer?
    // offer に data_channels フィールドが含まれるかと switched メッセージの内容を保持する
    var offerContainsDataChannels = false
    var offerContainsMessagingLabel = false
    var switchedIgnoreDisconnectWebSocket: Bool?
    // onDataChannelOpened で通知されたラベルと重複通知の有無を記録する
    var openedLabels: Set<String> = []
    var duplicateLabelNotification = false
    // onDataChannel の発火回数を記録する (switched 受信時の発火を検出するため)
    var onDataChannelFireCount = 0
    // expectation の二重 fulfill (XCTest の API violation) を防ぐためのフラグ。
    // ハンドラ経由の fulfill と後始末 (XCTSkip / エラー分岐) の fulfill が重複すると、
    // "API violation - multiple calls made to fulfill" としてテスト失敗になるため
    var switchedExpectationFulfilled = false
    var dataChannelExpectationFulfilled = false
    var signalingOpenedExpectationFulfilled = false

    // sendonly 用の Configuration
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = channelId
    config.dataChannelSignaling = true
    config.ignoreDisconnectWebSocket = true
    config.videoEnabled = true
    config.audioEnabled = false
    config.videoCodec = .vp8
    config.initialCameraEnabled = false
    // onDataChannel の発火を検証するため、メッセージング用ラベルを明示的に払い出す
    // (メッセージング用ラベルが存在しない接続では onDataChannel は発火しない。
    // direction は Sora の data_channels 仕様の必須項目)
    config.dataChannels = [
      ["label": "#spam", "direction": "sendrecv", "compress": false]
    ]

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
        // 払い出したメッセージング用ラベル (#spam) が offer に含まれるかを記録する
        if dict["type"] as? String == "offer",
          let dataChannels = dict["data_channels"] as? [[String: Any]]
        {
          if dataChannels.contains(where: { ($0["label"] as? String) == "#spam" }) {
            offerContainsMessagingLabel = true
          }
        }
        // type: "switched" メッセージの ignore_disconnect_websocket フィールドを記録する
        if dict["type"] as? String == "switched" {
          switchedIgnoreDisconnectWebSocket = dict["ignore_disconnect_websocket"] as? Bool
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !switchedExpectationFulfilled {
            switchedExpectationFulfilled = true
            switchedExpectation.fulfill()
          }
        }
      }
    }
    config.mediaChannelHandlers.onDataChannel = { _ in
      DispatchQueue.main.async {
        onDataChannelFireCount += 1
        // onDataChannel の発火が #spam の OPEN に起因することを確認する。
        // (#spam の OPEN 通知処理 (onDataChannelOpened) が同一イベント内で先に main queue へ
        // 積まれ、main queue の FIFO で先に処理されるため、この時点で #spam は OPEN 済み。
        // 同一スレッドからのエンキュー順序に依存するため、クロススレッドのレースはない。
        // ここで #spam が未 OPEN なら、#spam の OPEN に起因しない発火 (switched のみで
        // 発火する実装等) への回帰を検出できる)
        XCTAssertTrue(
          openedLabels.contains("#spam"),
          "onDataChannel の発火時点で #spam が OPEN 済みであること")
        // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
        if !dataChannelExpectationFulfilled {
          dataChannelExpectationFulfilled = true
          dataChannelExpectation.fulfill()
        }
      }
    }
    // onDataChannelOpened は全ラベル対象でラベルごとに 1 回発火することを確認する
    config.mediaChannelHandlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        if !openedLabels.insert(label).inserted {
          duplicateLabelNotification = true
        }
        // メッセージング用ラベル (#spam) の OPEN 時点で onDataChannel が未発火であることを確認する。
        // (onDataChannel は #spam の OPEN に起因して発火するため、この時点では必ず未発火。
        // ここで発火済み (1 以上) なら、#spam の OPEN より前に発火する実装への回帰を検出できる)
        if label == "#spam" {
          XCTAssertEqual(
            onDataChannelFireCount, 0, "#spam の OPEN 時点では onDataChannel が未発火であること")
        }
        // signaling ラベルの OPEN を記録する (全ラベル対象の検証で使用)
        if label == "signaling" {
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !signalingOpenedExpectationFulfilled {
            signalingOpenedExpectationFulfilled = true
            signalingOpenedExpectation.fulfill()
          }
        }
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
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait はタイムアウト (0 秒) でも failure を報告しない。
      // 接続失敗時は SDK の接続が終了しているため、以降の fulfill は発生しない
      _ = XCTWaiter.wait(
        for: [switchedExpectation, dataChannelExpectation, signalingOpenedExpectation],
        timeout: 0)
      return
    }

    // offer に data_channels フィールドが含まれるかを確認する
    // (Sora サーバーが DataChannel シグナリング未対応の場合は XCTSkip でスキップする)
    // offer に data_channels フィールドが含まれない場合 (DataChannel シグナリング未対応) と、
    // 払い出したメッセージング用ラベル (#spam) が offer に含まれない場合は、
    // onDataChannel の発火検証ができないため XCTSkip でスキップする
    guard offerContainsDataChannels, offerContainsMessagingLabel else {
      // 残留チャンネルを残さないよう、後始末を実行してからスキップする
      capturer.stop()
      disconnectAll(channels: [channel])
      // XCTSkip では expectation のチェックが行われないため、fulfill は不要
      if !offerContainsDataChannels {
        throw XCTSkip("Sora サーバーが DataChannel シグナリング未対応のためスキップします")
      }
      throw XCTSkip("Sora サーバーがメッセージング用ラベルを払い出さないためスキップします")
    }

    // type: "switched" メッセージの受信を待つ
    wait(for: [switchedExpectation], timeout: 10)
    guard let switchedIgnoreDisconnectWebSocket else {
      XCTFail("switched メッセージを受信できなかった")
      capturer.stop()
      disconnectAll(channels: [channel])
      // 未 wait の expectation (dataChannel / signalingOpened) を wait 済みにして、
      // テスト終了時の unwaited expectation 報告を防ぐ。XCTWaiter.wait はタイムアウト
      // (0 秒) でも failure を報告しない。switchedExpectation は直上の wait で消費済みの
      // ため対象外。switched が来ない = DataChannel シグナリングが確立していないため、
      // 以降の fulfill は発生しない
      _ = XCTWaiter.wait(
        for: [dataChannelExpectation, signalingOpenedExpectation],
        timeout: 0)
      return
    }
    // ignore_disconnect_websocket フィールドが true であることを確認する
    XCTAssertTrue(
      switchedIgnoreDisconnectWebSocket, "ignore_disconnect_websocket が true であること")

    // onDataChannel が発火したことを確認する
    // (メッセージング用ラベル (#spam) の DataChannel がクライアント側で OPEN になった時点で発火する)
    wait(for: [dataChannelExpectation], timeout: 10)

    // onDataChannelOpened が全ラベル対象で発火し、払い出したメッセージング用ラベル (#spam) が
    // 含まれることを確認する。重複通知は SDK 側で防止されている。
    XCTAssertFalse(
      duplicateLabelNotification, "onDataChannelOpened が重複して発火した: \(openedLabels)")
    XCTAssertTrue(
      openedLabels.contains("#spam"), "メッセージング用ラベル (#spam) が通知されること: \(openedLabels)")
    // onDataChannelOpened は # 始まりのラベルに限定しない (全ラベル対象) ことを確認する。
    // signaling ラベルの OPEN は onDataChannel の発火条件 (全 # ラベル OPEN) とは独立のため、
    // assertion 前に明示的に signaling の OPEN を待つ (タイミング依存のレースを防ぐ)。
    wait(for: [signalingOpenedExpectation], timeout: 10)
    XCTAssertTrue(
      openedLabels.contains("signaling"),
      "非メッセージング用ラベル (signaling) も通知されること: \(openedLabels)")

    // onDataChannel は 1 回のみ発火すること (switched 受信時の発火が復活した場合は 2 回発火する)。
    // onDataChannelFireCount の更新は main queue に束ねられているため、検証も main queue 上で
    // 行い、先行して積まれた全発火処理が FIFO で処理済みになってから評価する。
    // (テストスレッドで直接評価すると、switched 受信時の 2 回目の発火が未処理のまま
    // 評価されるレースがあり、回帰を検出し損なう)
    let finalVerifyExpectation = self.expectation(description: "最終発火回数の検証が完了すること")
    DispatchQueue.main.async {
      XCTAssertEqual(
        onDataChannelFireCount, 1, "onDataChannel が 1 回のみ発火すること")
      finalVerifyExpectation.fulfill()
    }
    wait(for: [finalVerifyExpectation], timeout: 10)

    // 後始末: capturer を停止し、チャンネルを切断する
    capturer.stop()
    disconnectAndVerify(channel: channel)
  }

  /// ignoreDisconnectWebSocket = true でも、接続確立前の接続失敗はエラーで終端することを確認する。
  /// (SignalingChannel は接続確立前 (webSocketChannel == nil) の候補枯渇時に、
  /// ignoreDisconnectWebSocket に関係なく切断する。これを適用しないと、
  /// リダイレクト先への接続失敗が検出不能になり、state が .connecting のまま終端しない。
  /// 本テストは Sora サーバに接続せず、接続できない URL への接続失敗で検証する)
  func testSendonlyConnectionFailureWithIgnoreDisconnectWebSocket() throws {
    // 接続失敗を検証するため、接続できない URL を urlCandidates に設定する
    guard let url = URL(string: "wss://127.0.0.1:9/signaling") else {
      XCTFail("テスト用 URL が不正です")
      return
    }
    var config = Configuration(
      urlCandidates: [url],
      channelId: buildChannelId(unique: true),
      role: .sendonly)
    config.ignoreDisconnectWebSocket = true

    // connect がエラーで終端することを待つ expectation
    let connectExpectation = self.expectation(
      description: "接続失敗がエラーで終端すること")

    _ = sora?.connect(configuration: config) { _, error in
      DispatchQueue.main.async {
        XCTAssertNotNil(error, "接続失敗時は error が渡ること")
        // 新実装では接続失敗が即時検出され、接続タイムアウトではないエラーで終端する。
        // 旧実装 (ignoreDisconnectWebSocket を接続確立前に適用) では接続失敗が検出されず、
        // connectionTimeout (30 秒) で終端するため、error 種別で回帰を検出できる。
        if let error = error as? SoraError, case .connectionTimeout = error {
          XCTFail("接続失敗がタイムアウトで終端しないこと (旧実装の挙動)")
        }
        connectExpectation.fulfill()
      }
    }

    wait(for: [connectExpectation], timeout: 35)
  }

  /// サーバー側切断が DataChannel 経由で伝播し、切断理由が SoraCloseEvent で通知されることを確認する
  ///
  /// dataChannelSignaling = true + ignoreDisconnectWebSocket = true で接続し、Sora API
  /// (DisconnectConnection) でサーバー側から切断する。type: "close" を DataChannel 経由で
  /// 受信し、onDisconnect の SoraCloseEvent.ok(code:reason:) の値と一致することを確認する。
  /// (SoraError.dataChannelClosed は SoraCloseEvent.ok に変換されて onDisconnect で通知される。
  /// code / reason の一致は DataChannel 経由の切断であることの証明になる。
  /// type: "close" はサーバー側の data_channel_signaling_close_message 設定に依存するため、
  /// 受信できなかった場合は一致検証を省略する)
  func testSendonlyDataChannelClose() throws {
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

    // 接続完了・switched 受信・close 受信・切断の完了を待つ expectation
    let connectExpectation = self.expectation(description: "接続が完了すること")
    let switchedExpectation = self.expectation(description: "switched メッセージを受信すること")
    let closeReceivedExpectation = self.expectation(description: "type: close を受信すること")
    let disconnectExpectation = self.expectation(description: "切断が完了すること")

    // 接続したチャンネルと capturer を保持する (切断・停止に使用する)
    var channel: MediaChannel?
    var capturer: DummyVideoCapturer?
    // offer に data_channels フィールドが含まれるかと switched の内容を保持する
    var offerContainsDataChannels = false
    var switchedIgnoreDisconnectWebSocket: Bool?
    // type: close で受信した code / reason と切断イベントを保持する
    var closeCode: Int?
    var closeReason: String?
    var disconnectEvent: SoraCloseEvent?
    // expectation の二重 fulfill (XCTest の API violation) を防ぐためのフラグ
    var switchedExpectationFulfilled = false
    var closeReceivedExpectationFulfilled = false
    var disconnectExpectationFulfilled = false

    // sendonly 用の Configuration (DataChannel シグナリング有効 + WebSocket 切断の無視)
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = channelId
    config.dataChannelSignaling = true
    config.ignoreDisconnectWebSocket = true
    config.videoEnabled = true
    config.audioEnabled = false
    config.videoCodec = .vp8
    config.initialCameraEnabled = false

    // ハンドラは connect 呼び出しより前に登録する (switched は接続完了より先に到着し得る)
    // ハンドラは WebSocket 受信スレッドと DataChannel の delegate スレッドから呼ばれるため、
    // 共有状態の更新は main queue に束ねる
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
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !switchedExpectationFulfilled {
            switchedExpectationFulfilled = true
            switchedExpectation.fulfill()
          }
        }
        // type: "close" メッセージの code / reason を記録する
        // (WebSocket 経由の close もここには届くが、一致検証の成否で DataChannel 経路を判定する)
        if dict["type"] as? String == "close" {
          closeCode = dict["code"] as? Int
          closeReason = dict["reason"] as? String
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !closeReceivedExpectationFulfilled {
            closeReceivedExpectationFulfilled = true
            closeReceivedExpectation.fulfill()
          }
        }
      }
    }
    config.mediaChannelHandlers.onDisconnect = { event in
      DispatchQueue.main.async {
        disconnectEvent = event
        // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
        if !disconnectExpectationFulfilled {
          disconnectExpectationFulfilled = true
          disconnectExpectation.fulfill()
        }
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
        guard let connectedChannel = mediaChannel, let stream = connectedChannel.senderStream else {
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
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait はタイムアウト (0 秒) でも failure を報告しない。
      // 接続失敗時は SDK の接続が終了しているため、以降の fulfill は発生しない
      _ = XCTWaiter.wait(
        for: [switchedExpectation, closeReceivedExpectation, disconnectExpectation],
        timeout: 0)
      return
    }

    // offer に data_channels フィールドが含まれるかを確認する
    // (Sora サーバーが DataChannel シグナリング未対応の場合は XCTSkip でスキップする)
    guard offerContainsDataChannels else {
      // 残留チャンネルを残さないよう、後始末を実行してからスキップする
      capturer.stop()
      disconnectAll(channels: [channel])
      // XCTSkip では expectation のチェックが行われないため、fulfill は不要
      throw XCTSkip("Sora サーバーが DataChannel シグナリング未対応のためスキップします")
    }

    // switched 受信を待つ
    let switchedResult = XCTWaiter.wait(for: [switchedExpectation], timeout: 10)
    guard switchedResult == .completed else {
      XCTFail("switched メッセージを受信できなかった")
      capturer.stop()
      disconnectAll(channels: [channel])
      _ = XCTWaiter.wait(
        for: [closeReceivedExpectation, disconnectExpectation],
        timeout: 0)
      return
    }
    // ignore_disconnect_websocket が true であることを確認する
    // (false の場合はサーバーが ignoreDisconnectWebSocket を尊重しないため、本テストの
    // 検証が成立しない。後始末を実行してからスキップする)
    guard switchedIgnoreDisconnectWebSocket == true else {
      capturer.stop()
      disconnectAll(channels: [channel])
      throw XCTSkip("switched の ignore_disconnect_websocket が false のためスキップします")
    }

    // Sora API (DisconnectConnection) でサーバー側から切断する
    let apiExpectation = self.expectation(description: "Sora API の切断が成功すること")
    var request = URLRequest(url: apiUrl)
    request.httpMethod = "POST"
    request.setValue("Sora_20151104.DisconnectConnection", forHTTPHeaderField: "X-Sora-Target")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["channel_id": channelId, "connection_id": channel.connectionId])
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
    guard self.apiDisconnectSucceeded else {
      // 後始末 (サーバー切断は発生しないため、close / 切断待機の expectation を wait 済みにする)
      capturer.stop()
      disconnectAll(channels: [channel])
      _ = XCTWaiter.wait(
        for: [closeReceivedExpectation, disconnectExpectation],
        timeout: 0)
      return
    }

    // type: "close" の受信を待つ
    // (サーバー側の data_channel_signaling_close_message 設定に依存するため、
    // 受信できない場合も失敗にはしない)
    let closeResult = XCTWaiter.wait(for: [closeReceivedExpectation], timeout: 10)
    let closeReceived = closeResult == .completed

    // 切断 (onDisconnect) を待つ
    let disconnectResult = XCTWaiter.wait(for: [disconnectExpectation], timeout: 10)
    guard disconnectResult == .completed, let disconnectEvent else {
      XCTFail("切断が完了しなかった")
      capturer.stop()
      disconnectAll(channels: [channel])
      return
    }

    // SoraCloseEvent を検証する
    // (DataChannel 経由の close は dataChannelSignalingClose に格納され、
    // SoraError.dataChannelClosed → SoraCloseEvent.ok(code:reason:) へ無変換で伝播する。
    // WebSocket 経由の close は SDK が処理しないため .ok(1000, "NO-ERROR") になり、
    // 一致しない。したがって一致検証の成功は DataChannel 経由の切断であることの証明になる)
    if case .ok(let code, let reason) = disconnectEvent {
      if closeReceived {
        XCTAssertEqual(code, closeCode, "onDisconnect の code が close の code と一致すること")
        XCTAssertEqual(
          reason, closeReason, "onDisconnect の reason が close の reason と一致すること")
      }
    } else {
      XCTFail("予期しない切断: \(disconnectEvent)")
    }

    // 後始末: capturer を停止し、チャンネルを切断する
    // (サーバー切断済みのため、disconnectAndVerify の state チェックでスキップされる)
    capturer.stop()
    disconnectAndVerify(channel: channel)
  }
}
