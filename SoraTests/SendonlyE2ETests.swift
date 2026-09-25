import XCTest

@testable import Sora

/// sendonly ダミー映像・音声テスト
final class SendonlyE2ETests: E2ETestBase {
  // Sora API (DisconnectConnection) の切断が成功したかどうか。
  // コールバックの結果を wait 後に検証してテストメソッド側で設定する
  private var apiDisconnectSucceeded = false
  // Sora API コールバックの結果。コールバック内では XCTFail を呼ばず、
  // wait の後にテストメソッド側で検証する (コールバックがテスト終了後に発火しても
  // 次のテストへ失敗が誤帰属されないようにするため)
  private var apiError: Error?
  private var apiResponse: URLResponse?
  // Sora API の wait が終了したかどうか。wait 終了後に発火したコールバックの
  // 結果保持と fulfill を抑止する
  private var apiWaitFinished = false

  override func setUp() async throws {
    try await super.setUp()
    apiDisconnectSucceeded = false
    apiError = nil
    apiResponse = nil
    apiWaitFinished = false
  }

  /// sendonly の接続を待ち、接続できたチャンネルを返す
  ///
  /// connect callback は libwebrtc の delegate スレッドから呼ばれるため、state の更新は
  /// main queue に束ねる。接続に失敗した場合は callback が失敗を報告済みのため、ここでは
  /// 追加の失敗を記録せず、後始末だけを行って nil を返す。接続に失敗した場合も
  /// `sora?.mediaChannels` にはチャンネルが残る (一覧から外れるのは切断完了の通知が
  /// 届いたとき) ため、残っているチャンネルをすべて切断してから戻る
  private func connectAndWait(configuration: Configuration) -> MediaChannel? {
    let connectExpectation = self.expectation(description: "sendonly の接続が完了すること")
    var connectedChannel: MediaChannel?
    // wait の終了後に発火した callback で assertion を記録しないためのフラグ。
    // 記録するとテスト終了後の失敗が次のテストへ誤帰属される
    var waitFinished = false
    _ = sora?.connect(configuration: configuration) { mediaChannel, error in
      DispatchQueue.main.async {
        guard !waitFinished else { return }
        if let error {
          // 接続失敗はここで 1 回だけ報告する (wait 後の guard では追加の失敗を記録しない)。
          // 接続できていないため、channel は採用しない
          XCTFail("接続に失敗した: \(error)")
        } else {
          // 接続成功時は mediaChannel が渡る契約を検証する
          XCTAssertNotNil(mediaChannel, "接続成功時は mediaChannel が渡ること")
          connectedChannel = mediaChannel
        }
        connectExpectation.fulfill()
      }
    }

    // SDK の connectionTimeout (30 秒) より長く待つ
    wait(for: [connectExpectation], timeout: 35)
    waitFinished = true

    guard let connectedChannel else {
      disconnectAll(channels: sora?.mediaChannels ?? [])
      return nil
    }
    return connectedChannel
  }

  /// main queue へ渡すために `Statistics` から Sendable な値だけを取り出した snapshot
  ///
  /// `Statistics` は Sendable ではないため、`getStats` の handler (WebRTC のスレッド) の中で
  /// この型へ詰め替え、この値だけを main queue へ渡す
  private struct StatsSnapshot: Sendable {
    /// `kind` の outbound-rtp が存在するかどうか
    let hasOutbound: Bool
    /// `kind` の outbound-rtp が送信したバイト数
    let bytesSent: Int
    /// `kind` の outbound-rtp が送信したパケット数
    let packetsSent: Int
    /// 音声の場合に OPUS のコーデック統計が存在するかどうか
    let hasAudioOpusCodec: Bool

    /// `kind` ("video" / "audio") の outbound-rtp と、音声の場合は OPUS のコーデック統計を取り出す
    init(stats: Statistics, kind: String) {
      let outbound = stats.entries.first {
        $0.type == "outbound-rtp" && (($0.values["kind"] as? NSString) as String?) == kind
      }
      self.hasOutbound = outbound != nil
      self.bytesSent = (outbound?.values["bytesSent"] as? NSNumber)?.intValue ?? 0
      self.packetsSent = (outbound?.values["packetsSent"] as? NSNumber)?.intValue ?? 0
      self.hasAudioOpusCodec =
        kind == "audio"
        && stats.entries.contains {
          $0.type == "codec" && (($0.values["mimeType"] as? NSString) as String?) == "audio/opus"
        }
    }
  }

  /// 接続済みチャンネルの統計を取得し、成功時に `verify` で検証する
  ///
  /// `getStats` の handler は WebRTC のスレッドから呼ばれるため、非 Sendable な `Statistics` を
  /// そのまま扱わず、必要な値だけを Sendable な snapshot に詰め替えてから main queue へ 1 hop する。
  /// handler を `@Sendable` にして隔離を継承させないのは、MainActor 隔離の closure を WebRTC
  /// スレッドから呼ぶと実行時違反 (`dispatch_assert_queue`) になるためである
  /// (`StereoAudioOutputE2ETests` の `audioCounts` と同じ方式)。`verify` も `@Sendable` にして、
  /// 非 Sendable な closure を handler へ持ち込まない
  private func waitForStats(
    channel: MediaChannel,
    kind: String,
    delay: TimeInterval,
    description: String,
    verify: @escaping @Sendable (StatsSnapshot) -> Void
  ) {
    let statsExpectation = self.expectation(description: description)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      channel.getStats { @Sendable result in
        // WebRTC スレッドでは数値だけを取り出し、非 Sendable な統計オブジェクトは渡さない
        let snapshot = result.map { StatsSnapshot(stats: $0, kind: kind) }
        DispatchQueue.main.async {
          defer { statsExpectation.fulfill() }
          switch snapshot {
          case .failure(let error):
            // getStats の failure は接続状態の遷移 (切断・チャンネル再生成等) が原因のため、
            // エラー詳細を含めて出力する
            XCTFail("getStats に失敗した : \(error)")
          case .success(let snapshot):
            verify(snapshot)
          }
        }
      }
    }
    // delay の待機を含めて 30 秒待つ
    wait(for: [statsExpectation], timeout: 30)
  }

  /// sendonly で DummyVideoCapturer を使ってダミー映像を送信できることを確認する
  func testSendonlyDummyVideo() throws {
    var config = try buildConfiguration(role: .sendonly)
    // 接続時の物理カメラ自動起動を抑止し、senderStream 生成後にダミー映像を流す
    config.initialCameraEnabled = false
    // この E2E はダミー映像送信の確認に限定し、音声初期化による不安定要因を避ける
    config.audioEnabled = false

    guard let channel = connectAndWait(configuration: config) else {
      return
    }
    // DummyVideoCapturer は MainActor に隔離されているため、senderStream の取得と capturer の
    // 生成・開始は MainActor 上で行う (callback 直下で生成すると MainActor 実行時違反になる)
    guard let stream = channel.senderStream else {
      XCTFail("senderStream が nil")
      disconnectAndVerify(channel: channel)
      return
    }
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    capturer.stream = stream
    capturer.start()

    // main RunLoop 上で 2 秒待機してから、ダミー映像送信の継続と WebRTC 統計情報を確認する
    waitForStats(
      channel: channel, kind: "video", delay: 2, description: "ダミー映像の統計を確認できること"
    ) { snapshot in
      XCTAssertTrue(snapshot.hasOutbound, "outbound video stats が存在すること")
      XCTAssertGreaterThan(snapshot.bytesSent, 0, "bytesSent が 0 より大きいこと")
      XCTAssertGreaterThan(snapshot.packetsSent, 0, "packetsSent が 0 より大きいこと")
    }
    XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
    XCTAssertNotNil(channel.senderStream, "senderStream が維持されていること")

    // capturer がバッファ確保の連続失敗で自動停止していないかを直接確認する
    XCTAssertTrue(capturer.isRunning, "DummyVideoCapturer が動作中であること")
    XCTAssertGreaterThan(capturer.frameCount, 0, "ダミー映像フレームが送信されていること")

    capturer.stop()
    // 切断し、正常切断コード (1000) が通知されることまで確認する
    disconnectAndVerify(channel: channel)
  }

  /// sendonly で DummyAudioDevice を使ってダミー音声を送信できることを確認する
  func testSendonlyDummyAudio() throws {
    var config = try buildConfiguration(role: .sendonly)
    // この E2E はダミー音声送信の確認に限定し、映像は無効にする
    config.videoEnabled = false
    config.audioEnabled = true
    // 440Hz 正弦波を生成するダミー音声デバイスを注入する
    let sineWaveGenerator = SineWaveGenerator(frequency: 440)
    let audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true,
      pcmGenerator: { data, frameCount, sampleRate in
        sineWaveGenerator.generate(data: data, frameCount: frameCount, sampleRate: sampleRate)
      })
    config.audioDevice = audioDevice
    // DummyAudioDevice.initialize(with:) が接続試行時に AVAudioSession を有効化するため、
    // tearDown での復元対象とする
    audioSessionActivatedByTest = true

    guard let channel = connectAndWait(configuration: config) else {
      return
    }

    // main RunLoop 上で 2 秒待機してから、ダミー音声送信の継続と WebRTC 統計情報を確認する
    waitForStats(
      channel: channel, kind: "audio", delay: 2, description: "ダミー音声の統計を確認できること"
    ) { snapshot in
      // 音声コーデック (OPUS) が確定していることを確認する (sora-js-sdk の E2E と同様)
      XCTAssertTrue(snapshot.hasAudioOpusCodec, "audio codec stats が存在すること")
      XCTAssertTrue(snapshot.hasOutbound, "outbound audio stats が存在すること")
      XCTAssertGreaterThan(snapshot.bytesSent, 0, "bytesSent が 0 より大きいこと")
      XCTAssertGreaterThan(snapshot.packetsSent, 0, "packetsSent が 0 より大きいこと")
    }
    XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")

    // 切断し、正常切断コード (1000) が通知されることまで確認する
    disconnectAndVerify(channel: channel)

    // 切断時の terminateDevice が state を終端へ戻すことを確認する。切断イベントはデバイスの停止より
    // 先に配送され得るため、停止と同じ lock 区間で更新される isInitialized が false になるまで待つ。
    // このテストは送信専用接続のため ADM は再生を初期化せず (initializePlayout は受信ストリームが
    // ある場合にしか呼ばれない)、検証できるのは録音側と isInitialized の終端性である。
    // AudioUnit 経路の実行時検証は受信ありの接続が必要で、Simulator では保証できない
    let terminated = expectation(
      for: NSPredicate { _, _ in !audioDevice.isInitialized }, evaluatedWith: nil)
    wait(for: [terminated], timeout: 5)
    XCTAssertFalse(audioDevice.isInitialized, "切断後に isInitialized が false であること")
    XCTAssertFalse(audioDevice.isRecording, "切断後に isRecording が false であること")
    XCTAssertFalse(audioDevice.isRecordingInitialized, "切断後に isRecordingInitialized が false であること")
    XCTAssertFalse(audioDevice.isHardMuted, "切断後に isHardMuted が初期状態 (ミュートなし) であること")
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
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ (fulfill だけでは hasBeenWaitedOn が立たない)
      _ = XCTWaiter.wait(for: [disconnectExpectation, connect2Expectation], timeout: 0)
      return
    }

    // Sora API (DisconnectConnection) でサーバー側から切断する
    let apiExpectation = self.expectation(description: "Sora API の呼び出しが完了すること")
    var request = URLRequest(url: apiUrl)
    request.httpMethod = "POST"
    request.setValue("Sora_20151104.DisconnectConnection", forHTTPHeaderField: "X-Sora-Target")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["channel_id": channelId, "connection_id": connectionId1])
    request.timeoutInterval = 10
    // URLSession.shared は keep-alive 接続をプールするため、サーバー側で閉じられた
    // 接続を再利用したときに NSURLErrorNetworkConnectionLost (-1005) で失敗し得る。
    // API 呼び出しごとに使い捨ての URLSession を生成し、接続を再利用しないようにする。
    // timeoutIntervalForResource でリクエストの総時間を制限し、タスクとセッションが
    // 残り続けないようにする
    let apiConfiguration = URLSessionConfiguration.ephemeral
    apiConfiguration.timeoutIntervalForResource = 10
    let apiSession = URLSession(configuration: apiConfiguration)
    apiSession.dataTask(with: request) { _, response, error in
      apiSession.invalidateAndCancel()
      // コールバック内では XCTFail を呼ばず、結果の保持と fulfill のみを行う。
      // コールバックがテスト終了後に発火しても次のテストへ失敗が誤帰属されない
      DispatchQueue.main.async {
        guard !self.apiWaitFinished else { return }
        self.apiError = error
        self.apiResponse = response
        apiExpectation.fulfill()
      }
    }.resume()
    // wait のタイムアウトをリクエストのタイムアウトより長くし、通常はコールバックが
    // wait の内側で発火するようにする
    wait(for: [apiExpectation], timeout: 15)
    apiWaitFinished = true
    // コールバックの結果は wait 後にテストメソッド側で検証する
    if let apiError {
      XCTFail("Sora API の呼び出しに失敗した : \(apiError)")
    } else if let httpResponse = apiResponse as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    {
      apiDisconnectSucceeded = true
    } else if let apiResponse {
      XCTFail("Sora API がエラーを返した : \(String(describing: apiResponse))")
    }
    // コールバックが wait 内に発火しなかった場合は wait がタイムアウトを報告済みのため、
    // ここでは追加の XCTFail を記録しない
    guard apiDisconnectSucceeded else {
      // 後始末 (サーバー切断は発生しないため、切断検知 expectation を wait 済みにする)
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      _ = XCTWaiter.wait(for: [disconnectExpectation, connect2Expectation], timeout: 0)
      return
    }

    // サーバー切断の検知を待つ
    wait(for: [disconnectExpectation], timeout: 10)
    guard let disconnectEvent else {
      XCTFail("サーバー切断を検知できなかった")
      capturer?.stop()
      disconnectAll(channels: [channel1, channel2])
      _ = XCTWaiter.wait(for: [connect2Expectation], timeout: 0)
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
    let apiExpectation = self.expectation(description: "Sora API の呼び出しが完了すること")
    var request = URLRequest(url: apiUrl)
    request.httpMethod = "POST"
    request.setValue("Sora_20151104.DisconnectConnection", forHTTPHeaderField: "X-Sora-Target")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["channel_id": channelId, "connection_id": channel.connectionId])
    request.timeoutInterval = 10
    // URLSession.shared は keep-alive 接続をプールするため、サーバー側で閉じられた
    // 接続を再利用したときに NSURLErrorNetworkConnectionLost (-1005) で失敗し得る。
    // API 呼び出しごとに使い捨ての URLSession を生成し、接続を再利用しないようにする。
    // timeoutIntervalForResource でリクエストの総時間を制限し、タスクとセッションが
    // 残り続けないようにする
    let apiConfiguration = URLSessionConfiguration.ephemeral
    apiConfiguration.timeoutIntervalForResource = 10
    let apiSession = URLSession(configuration: apiConfiguration)
    apiSession.dataTask(with: request) { _, response, error in
      apiSession.invalidateAndCancel()
      // コールバック内では XCTFail を呼ばず、結果の保持と fulfill のみを行う。
      // コールバックがテスト終了後に発火しても次のテストへ失敗が誤帰属されない
      DispatchQueue.main.async {
        guard !self.apiWaitFinished else { return }
        self.apiError = error
        self.apiResponse = response
        apiExpectation.fulfill()
      }
    }.resume()
    // wait のタイムアウトをリクエストのタイムアウトより長くし、通常はコールバックが
    // wait の内側で発火するようにする
    wait(for: [apiExpectation], timeout: 15)
    apiWaitFinished = true
    // コールバックの結果は wait 後にテストメソッド側で検証する
    if let apiError {
      XCTFail("Sora API の呼び出しに失敗した : \(apiError)")
    } else if let httpResponse = apiResponse as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    {
      apiDisconnectSucceeded = true
    } else if let apiResponse {
      XCTFail("Sora API がエラーを返した : \(String(describing: apiResponse))")
    }
    // コールバックが wait 内に発火しなかった場合は wait がタイムアウトを報告済みのため、
    // ここでは追加の XCTFail を記録しない
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
