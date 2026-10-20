import XCTest

@testable import Sora

/// 実 Sora 接続でのイベント購読 API の E2E テスト
///
/// 環境変数 (`SORA_SIGNALING_URL` / `TEST_SECRET_KEY`) が未設定の場合は `E2ETestBase` の契約で
/// スキップされます。モックやスタブは使いません。
/// 実イベントの配送順序、legacy handler との対応、複数接続の混線がないことを確認します。
final class SoraEventE2ETests: E2ETestBase {
  /// 購読したイベントを配送スレッドで記録します。
  ///
  /// 配送はイベントの発生元のスレッドで行われるため、lock で保護します。購読の開始は
  /// `Sora.connect` を呼んだスレッド (接続の開始前) から行うため、MainActor に依存しません。
  private final class SoraEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SoraEvent] = []
    private var didFinish = false

    func append(_ event: SoraEvent) {
      lock.lock()
      recorded.append(event)
      lock.unlock()
    }

    func markFinished() {
      lock.lock()
      didFinish = true
      lock.unlock()
    }

    var events: [SoraEvent] {
      lock.lock()
      defer { lock.unlock() }
      return recorded
    }

    var finished: Bool {
      lock.lock()
      defer { lock.unlock() }
      return didFinish
    }

    func contains(kind: SoraEventKind) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return recorded.contains { $0.kind == kind }
    }

    func firstIndex(of kind: SoraEventKind) -> Int? {
      lock.lock()
      defer { lock.unlock() }
      return recorded.firstIndex { $0.kind == kind }
    }
  }

  /// stream の消費を開始し、届いたイベントを recorder へ記録します。
  ///
  /// 購読の開始は接続の開始前 (`SoraHandlers.onAddMediaChannel`) に行うため、MainActor へ
  /// 依存しない `nonisolated` メソッドにします。stream が終端すると Task も終了します。
  @discardableResult
  private nonisolated func startConsuming(
    _ stream: AsyncStream<SoraEvent>, into recorder: SoraEventRecorder
  ) -> Task<Void, Never> {
    Task {
      for await event in stream {
        recorder.append(event)
      }
      recorder.markFinished()
    }
  }

  /// 条件が成立するまで main runloop を回して待ちます。
  ///
  /// テスト本体は MainActor 上で動くため、runloop を回して配送を進めます。
  /// タイムアウトした場合は `XCTFail` を記録します。
  private func waitUntil(
    _ description: String, timeout: TimeInterval = 30, condition: () -> Bool
  ) {
    guard waitForCondition(timeout: timeout, condition: condition) else {
      XCTFail("\(description) が \(timeout) 秒以内に成立しなかった")
      return
    }
  }

  /// 条件が成立するまで main runloop を回して待ち、成立したかを返します。
  ///
  /// タイムアウトしても失敗を記録しません。Sora サーバーの対応状況によって成立しない待機を
  /// スキップとして扱うために使います。
  private func waitForCondition(timeout: TimeInterval = 20, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
  }

  /// 1 接続で、接続ライフサイクル、シグナリング、切断と購読の終端が配送され、
  /// legacy handler と内容が対応することを確認します。
  func testSingleConnectionDeliversLifecycleSignalingAndLegacyCorrespondence() throws {
    guard let sora else {
      XCTFail("Sora インスタンスが無い")
      return
    }

    var config = try buildConfiguration(role: .recvonly)
    config.channelId = buildChannelId(unique: true)
    config.initialCameraEnabled = false
    config.audioEnabled = false

    let soraRecorder = SoraEventRecorder()
    let channelRecorder = SoraEventRecorder()
    var channel: MediaChannel?
    var legacySignalingCount = 0

    // 接続前に Sora インスタンスの購読を開始する。接続 handler の中で発行される `connected` は、
    // main queue へ載せてから購読すると取り逃すため、接続の前に購読しておく。
    startConsuming(sora.subscribeEvents(), into: soraRecorder)

    let connectExpectation = expectation(description: "接続が完了すること")
    _ = sora.connect(configuration: config) { mediaChannel, error in
      // 購読は接続 handler の中で同期的に開始する。main queue へ載せてから購読すると、接続完了の
      // `connected` の配送より後に購読することになり取り逃す。購読の開始は任意のスレッドから
      // 行えるため、handler のスレッドで開始してから main queue へ結果を渡す。
      let events = mediaChannel?.subscribeEvents()
      DispatchQueue.main.async {
        if let error {
          XCTFail("接続に失敗した: \(error)")
          connectExpectation.fulfill()
          return
        }
        guard let mediaChannel, let events else {
          XCTFail("接続成功時に MediaChannel が返らない")
          connectExpectation.fulfill()
          return
        }
        channel = mediaChannel
        // legacy handler と新 API が同じ受信で配送されることを確認する。
        mediaChannel.handlers.onReceiveSignalingJSON = { _ in
          DispatchQueue.main.async { legacySignalingCount += 1 }
        }
        self.startConsuming(events, into: channelRecorder)
        connectExpectation.fulfill()
      }
    }
    wait(for: [connectExpectation], timeout: 35)

    guard let channel else {
      return
    }

    waitUntil("Sora インスタンスの connected が配送されること") {
      soraRecorder.contains(kind: .connected)
    }
    waitUntil("シグナリングの受信イベントが配送されること") {
      channelRecorder.contains(kind: .signalingReceivedJSON)
    }

    // 切断を実行し、legacy handler と新 API の両方で切断を観測する。
    let disconnectExpectation = expectation(description: "切断が完了すること")
    var legacyDisconnectCount = 0
    channel.handlers.onDisconnect = { _ in
      DispatchQueue.main.async {
        legacyDisconnectCount += 1
        disconnectExpectation.fulfill()
      }
    }
    channel.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: 35)

    waitUntil("MediaChannel の disconnected が配送されること") {
      channelRecorder.contains(kind: .disconnected)
    }
    waitUntil("接続の終了で購読が終端すること") {
      channelRecorder.finished
    }

    XCTAssertGreaterThanOrEqual(
      legacySignalingCount, 1, "legacy の onReceiveSignalingJSON も同じ受信で呼ばれること")
    XCTAssertEqual(legacyDisconnectCount, 1, "legacy の onDisconnect が 1 回呼ばれること")

    // Sora インスタンス側の順序 (mediaChannelAdded → connected) を確認する。
    guard let addedIndex = soraRecorder.firstIndex(of: .mediaChannelAdded),
      let connectedIndex = soraRecorder.firstIndex(of: .connected)
    else {
      XCTFail("Sora インスタンスのイベントに mediaChannelAdded / connected が含まれること")
      return
    }
    XCTAssertLessThan(addedIndex, connectedIndex, "mediaChannelAdded が connected より先に配送されること")

    // MediaChannel 側の順序と通し番号を確認する。購読を開始する前に配送されたイベントにも
    // 通し番号が採番されるため、購読後に受け取る最初の値は 1 とは限らない。また複数のスレッドから
    // 同時に配送されたイベントは、受信順と通し番号の順序が一致しないことがある。受信した範囲で
    // 欠落なく連続していることを確認する。
    let channelEvents = channelRecorder.events
    XCTAssertFalse(channelEvents.isEmpty, "イベントが 1 件も配送されなかった")
    XCTAssertTrue(channelRecorder.contains(kind: .connected), "接続の完了で connected が配送されること")
    XCTAssertTrue(channelRecorder.contains(kind: .disconnected), "切断で disconnected が配送されること")
    let sequences = channelEvents.map(\.sequence).sorted()
    guard let firstSequence = sequences.first, let lastSequence = sequences.last else {
      return
    }
    XCTAssertEqual(
      sequences, Array(firstSequence...lastSequence),
      "通し番号が受け取った範囲で欠落なく連続していること")
    XCTAssertTrue(
      channelEvents.allSatisfy { $0.connectionId == channel.connectionId },
      "MediaChannel のイベントが自接続の connectionId を持つこと")
  }

  /// 2 接続で、stream と DataChannel のイベントが配送され、接続間で混線しないことを確認します。
  ///
  /// Sora サーバーが DataChannel シグナリングとメッセージング用ラベルに対応しない場合は
  /// スキップします。
  func testTwoConnectionsDeliverStreamAndDataChannelEventsWithoutMixing() throws {
    guard let sora else {
      XCTFail("Sora インスタンスが無い")
      return
    }

    let channelId = buildChannelId(unique: true)
    let messagingLabel = "#spam"

    var config1 = try buildConfiguration(role: .sendrecv)
    config1.channelId = channelId
    config1.videoEnabled = true
    config1.audioEnabled = false
    config1.videoCodec = .vp8
    config1.initialCameraEnabled = false
    // メッセージングは DataChannel シグナリングが有効な場合だけ利用できる (サーバーが switched を
    // 送る前提)。既存の DataChannel の E2E テストと同じ設定にする。
    config1.dataChannelSignaling = true
    config1.ignoreDisconnectWebSocket = true
    config1.dataChannels = [
      ["label": messagingLabel, "direction": "sendrecv", "compress": false]
    ]

    // handler bag を接続間で共有しないよう、2 接続目の Configuration も組み立て直す。
    var config2 = try buildConfiguration(role: .sendrecv)
    config2.channelId = channelId
    config2.videoEnabled = true
    config2.audioEnabled = false
    config2.videoCodec = .vp8
    config2.initialCameraEnabled = false
    config2.dataChannelSignaling = true
    config2.ignoreDisconnectWebSocket = true
    config2.dataChannels = [
      ["label": messagingLabel, "direction": "sendrecv", "compress": false]
    ]

    // サーバーがメッセージング用ラベルを払い出したかは legacy handler で観測する。新 API の
    // イベントでスキップを判定すると、配送点の退行がスキップに隠れて検出できなくなる。
    var offerContainsMessagingLabel = false
    config1.mediaChannelHandlers.onReceiveSignalingJSON = { json in
      guard json.contains("\"data_channels\""), json.contains(messagingLabel) else {
        return
      }
      DispatchQueue.main.async { offerContainsMessagingLabel = true }
    }

    let recorder1 = SoraEventRecorder()
    let recorder2 = SoraEventRecorder()
    var channel1: MediaChannel?
    var channel2: MediaChannel?
    var capturer1: DummyVideoCapturer?
    var capturer2: DummyVideoCapturer?
    var connectFailed = false

    // 購読は接続の開始前に開始する。DataChannel の open と `switched` は接続の完了 (connect
    // handler) より前に配送され得るため、接続後に購読すると取り逃す。`onAddMediaChannel` は
    // 接続処理の開始前に呼ばれる (呼び出し元は `Sora.connect` を呼んだスレッド)。
    var pendingRecorders = [recorder1, recorder2]
    sora.handlers.onAddMediaChannel = { mediaChannel in
      guard !pendingRecorders.isEmpty else {
        return
      }
      let recorder = pendingRecorders.removeFirst()
      self.startConsuming(mediaChannel.subscribeEvents(), into: recorder)
    }

    let connect1Expectation = expectation(description: "1 接続目の接続が完了すること")
    let connect2Expectation = expectation(description: "2 接続目の接続が完了すること")

    _ = sora.connect(configuration: config1) { mediaChannel, error in
      DispatchQueue.main.async {
        guard let mediaChannel, let stream = mediaChannel.senderStream, error == nil else {
          XCTFail("1 接続目の接続に失敗した: \(String(describing: error))")
          connectFailed = true
          connect1Expectation.fulfill()
          return
        }
        channel1 = mediaChannel
        let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
        capturer.stream = stream
        capturer.start()
        capturer1 = capturer
        connect1Expectation.fulfill()

        _ = sora.connect(configuration: config2) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            guard let mediaChannel2, let stream2 = mediaChannel2.senderStream, error2 == nil else {
              XCTFail("2 接続目の接続に失敗した: \(String(describing: error2))")
              connectFailed = true
              connect2Expectation.fulfill()
              return
            }
            channel2 = mediaChannel2
            let newCapturer2 = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
            newCapturer2.stream = stream2
            newCapturer2.start()
            capturer2 = newCapturer2
            connect2Expectation.fulfill()
          }
        }
      }
    }

    /// 起動済みの capturer を停止します。
    let stopCapturers: () -> Void = {
      capturer1?.stop()
      capturer2?.stop()
    }

    wait(for: [connect1Expectation], timeout: 35)
    guard !connectFailed, let channel1 else {
      stopCapturers()
      disconnectAll(channels: [channel1, channel2])
      // 2 接続目を開始していないため、未 wait の expectation を timeout 0 で消費して
      // テスト終了時の unwaited expectation 報告を防ぐ。
      _ = XCTWaiter.wait(for: [connect2Expectation], timeout: 0)
      return
    }
    wait(for: [connect2Expectation], timeout: 35)
    guard !connectFailed, let channel2, capturer1 != nil, capturer2 != nil else {
      stopCapturers()
      disconnectAll(channels: [channel1, channel2])
      return
    }

    // 相手の video が届くと両接続に streamAdd のイベントが配送される。
    waitUntil("1 接続目に streamAdded が配送されること", timeout: 45) {
      recorder1.contains(kind: .streamAdded)
    }
    waitUntil("2 接続目に streamAdded が配送されること", timeout: 45) {
      recorder2.contains(kind: .streamAdded)
    }

    // Sora サーバーがメッセージング用ラベルを払い出さない場合はスキップする (legacy handler で
    // 観測した offer で判定する)。以降の DataChannel の検証は新 API のイベントを `waitUntil` で
    // 待ち、配送点の退行を失敗として検出する。
    guard waitForCondition(timeout: 20, condition: { offerContainsMessagingLabel }) else {
      stopCapturers()
      disconnectAll(channels: [channel1, channel2])
      throw XCTSkip("Sora サーバーがメッセージング用ラベルを払い出さないためスキップします")
    }

    waitUntil("1 接続目に DataChannel の open イベントが配送されること", timeout: 20) {
      recorder1.contains(kind: .dataChannelOpened)
    }
    waitUntil("2 接続目に DataChannel の open イベントが配送されること", timeout: 20) {
      recorder2.contains(kind: .dataChannelOpened)
    }
    waitUntil("両接続に DataChannel の available イベントが配送されること", timeout: 20) {
      recorder1.contains(kind: .dataChannelAvailable)
        && recorder2.contains(kind: .dataChannelAvailable)
    }

    // sendMessage は switched の受信を前提とするため、両接続の switched を待つ。
    waitUntil("両接続が DataChannel シグナリングへ切り替わること", timeout: 20) {
      recorder1.events.contains {
        $0.kind == .signalingReceivedJSON && ($0.signalingJSON?.contains("switched") ?? false)
      }
        && recorder2.events.contains {
          $0.kind == .signalingReceivedJSON && ($0.signalingJSON?.contains("switched") ?? false)
        }
    }

    // client1 から client2 へメッセージを送信し、購読者側で受信できることを確認する。
    let message = Data("sora-event-e2e".utf8)
    XCTAssertNil(channel1.sendMessage(label: messagingLabel, data: message), "メッセージの送信が成功すること")
    waitUntil("2 接続目に DataChannel のメッセージイベントが配送されること", timeout: 20) {
      recorder2.events.contains {
        $0.kind == .dataChannelMessage && $0.dataChannelLabel == messagingLabel
          && $0.dataChannelMessage == message
      }
    }

    // 接続ごとのイベントが混線しないことを確認する。connectionId は接続ごとに異なる。
    // offer を処理する前に配送されたイベント (offer の signalingReceivedJSON) は connectionId が
    // nil になるため、nil は許容し、値がある場合はその接続の ID と一致することを確認する。
    XCTAssertNotEqual(channel1.connectionId, channel2.connectionId, "接続 ID が接続ごとに異なること")
    XCTAssertTrue(
      recorder1.events.allSatisfy {
        $0.connectionId == nil || $0.connectionId == channel1.connectionId
      },
      "1 接続目のイベントが 1 接続目の connectionId か nil を持つこと")
    XCTAssertTrue(
      recorder2.events.allSatisfy {
        $0.connectionId == nil || $0.connectionId == channel2.connectionId
      },
      "2 接続目のイベントが 2 接続目の connectionId か nil を持つこと")

    // 切断し、両接続で切断イベントが配送されて購読が終端することを確認する。
    stopCapturers()
    for channel in [channel1, channel2] {
      channel.disconnect(error: nil)
    }
    waitUntil("1 接続目の購読が終端すること", timeout: 35) { recorder1.finished }
    waitUntil("2 接続目の購読が終端すること", timeout: 35) { recorder2.finished }

    // 切断イベントが配送されること。同時に配送されたイベントがある場合は最後とは限らないため、
    // 順序は streamAdded より後であることで確認する。
    XCTAssertTrue(recorder1.contains(kind: .disconnected), "1 接続目に disconnected が配送されること")
    XCTAssertTrue(recorder2.contains(kind: .disconnected), "2 接続目に disconnected が配送されること")

    guard let streamIndex1 = recorder1.firstIndex(of: .streamAdded),
      let disconnectedIndex1 = recorder1.firstIndex(of: .disconnected)
    else {
      XCTFail("1 接続目のイベントに streamAdded / disconnected が含まれること")
      return
    }
    XCTAssertLessThan(streamIndex1, disconnectedIndex1, "streamAdded が disconnected より先に配送されること")
  }
}
