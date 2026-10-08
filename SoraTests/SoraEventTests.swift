// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import WebRTC
import XCTest

@testable import Sora

/// 購読 API (`Sora.subscribeEvents(bufferingPolicy:)` /
/// `MediaChannel.subscribeEvents(bufferingPolicy:)`) の契約を確認します。
///
/// 実 Sora 接続を伴わずに確認できる契約だけを扱います。実イベントの順序、legacy handler
/// との対応、複数接続の混線は `SoraEventE2ETests` で確認します。モックやスタブは使いません。
final class SoraEventTests: XCTestCase {
  /// テスト用の `Configuration` を作ります。
  private static func makeConfiguration() -> Configuration {
    Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "sora-event",
      role: .sendrecv)
  }

  /// テスト用の `MediaChannel` を作ります (接続はしません)。
  ///
  /// `MediaChannel` は `Sendable` ではないため、テストの async 関数の中だけで扱い、`Task` へは
  /// 渡しません。
  private func makeMediaChannel() throws -> MediaChannel {
    try MediaChannel(configuration: Self.makeConfiguration())
  }

  /// 購読だけを返し、`MediaChannel` を保持しない stream を作ります。
  ///
  /// 戻った時点で `MediaChannel` の参照が無くなるため、`deinit` による購読の終端を確認できます。
  private func makeStreamReleasingMediaChannel() throws -> AsyncStream<SoraEvent> {
    let mediaChannel = try makeMediaChannel()
    return mediaChannel.subscribeEvents()
  }

  /// `Sora` インスタンスの購読を開始し、指定のイベントを配送してからインスタンスを解放します。
  ///
  /// `Sora` インスタンスの購読はインスタンスの解放で終端するため、解放してから読み切れる stream を
  /// 返します (件数を決めて待つと、配送点が退行した場合にテストが終わらなくなります)。
  private func makeSoraEventsAfterPublishing(
    _ publish: (Sora) -> Void
  ) -> AsyncStream<SoraEvent> {
    let sora = Sora()
    let stream = sora.subscribeEvents()
    publish(sora)
    return stream
  }

  /// 複数の購読者が同じイベントをそれぞれ受け取ること。
  ///
  /// 1 つの `AsyncStream` を複数の `Iterator` で消費するとイベントは購読者間で分かれるため、
  /// 購読者ごとに stream を作っていることをここで確認します。
  func testMultipleSubscribersReceiveSameEventsIndependently() async throws {
    let mediaChannel = try makeMediaChannel()
    let first = mediaChannel.subscribeEvents()
    let second = mediaChannel.subscribeEvents()

    // 2 つの購読を開始した後に配送する。両方へ同じイベントが届くこと。
    mediaChannel.publishEvent(kind: .connected)
    mediaChannel.publishEvent(kind: .streamAdded, streamId: "stream-1")
    mediaChannel.finishEvents()

    let firstEvents = await collectAllEvents(first)
    let secondEvents = await collectAllEvents(second)

    XCTAssertEqual(firstEvents.map(\.kind), [.connected, .streamAdded])
    XCTAssertEqual(secondEvents.map(\.kind), [.connected, .streamAdded])
    XCTAssertEqual(firstEvents.map(\.sequence), [1, 2], "通し番号は配送のたびに進むこと")
    guard confirmEventCount(firstEvents, 2) else {
      return
    }
    XCTAssertEqual(firstEvents[1].streamId, "stream-1", "payload が購読者へ届くこと")
  }

  /// 購読者がいない間も通し番号が進むこと。
  ///
  /// 購読を開始する前に配送されたイベントにも採番される契約であり、購読後に受け取る最初の値が
  /// 1 とは限らない根拠になります。
  func testSequenceAdvancesWithoutSubscribers() async throws {
    let mediaChannel = try makeMediaChannel()
    mediaChannel.publishEvent(kind: .connected)

    let stream = mediaChannel.subscribeEvents()
    mediaChannel.publishEvent(kind: .streamAdded, streamId: "stream-1")
    mediaChannel.finishEvents()

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.map(\.kind), [.streamAdded], "購読開始後のイベントだけが届くこと")
    XCTAssertEqual(events.map(\.sequence), [2], "購読開始前の配送にも採番されること")
  }

  /// buffer があふれた場合に最も古いイベントが破棄され、`sequence` で欠落を検出できること。
  func testBufferPolicyDropsOldestEventsAndSequenceDetectsLoss() async throws {
    let mediaChannel = try makeMediaChannel()
    // 消費を開始する前に 4 件配送し、buffer を 2 件に制限する。
    let stream = mediaChannel.subscribeEvents(bufferingPolicy: .bufferingNewest(2))

    for index in 1...4 {
      mediaChannel.publishEvent(kind: .signalingReceivedJSON, signalingJSON: "message-\(index)")
    }
    mediaChannel.finishEvents()

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.count, 2, "buffer の上限を超えた分は破棄されること")
    XCTAssertEqual(events.map(\.sequence), [3, 4], "新しいイベントが残ること")
    XCTAssertEqual(
      events.map(\.signalingJSON), ["message-3", "message-4"],
      "破棄されたイベントの payload が残らないこと")
  }

  /// 購読者ごとに buffer と drop 方針が独立していること。
  func testSubscribersHaveIndependentBufferPolicies() async throws {
    let mediaChannel = try makeMediaChannel()
    let bounded = mediaChannel.subscribeEvents(bufferingPolicy: .bufferingNewest(1))
    let unbounded = mediaChannel.subscribeEvents(bufferingPolicy: .unbounded)

    for index in 1...3 {
      mediaChannel.publishEvent(kind: .signalingReceivedJSON, signalingJSON: "message-\(index)")
    }
    mediaChannel.finishEvents()

    let boundedEvents = await collectAllEvents(bounded)
    let unboundedEvents = await collectAllEvents(unbounded)

    XCTAssertEqual(boundedEvents.count, 1, "1 件に制限した購読だけが drop されること")
    XCTAssertEqual(unboundedEvents.count, 3, "別の購読者の buffer は影響を受けないこと")
  }

  /// 購読している `Task` を cancel すると、その購読だけが解除されること。
  ///
  /// cancel した購読者には以降のイベントが届かず、cancel していない購読者には届くことを確認します。
  /// 購読者の管理からも消えていることは購読者数で確認します。
  func testCancellingConsumingTaskUnsubscribesOnlyThatSubscriber() async throws {
    let mediaChannel = try makeMediaChannel()
    let cancelled = mediaChannel.subscribeEvents()
    let kept = mediaChannel.subscribeEvents()

    let task = Task { await collectAllEvents(cancelled) }
    // 消費が開始してから cancel し、消費ループの終了を待つ。cancel が消費ループへ伝わる前に
    // 配送すると、buffer に残ったイベントが配送され得る。
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    _ = await task.value
    waitForSubscriptionCount(1) { mediaChannel.eventSubscriptionCountForTesting }

    mediaChannel.publishEvent(kind: .connected)
    mediaChannel.finishEvents()

    let cancelledEvents = await task.value
    let keptEvents = await collectAllEvents(kept)

    XCTAssertTrue(cancelledEvents.isEmpty, "cancel した購読には配送されないこと")
    XCTAssertEqual(keptEvents.map(\.kind), [.connected], "cancel していない購読には配送されること")
  }

  /// 購読に使った `AsyncStream` への参照を解放すると購読が解除されること。
  ///
  /// 解除が購読者の管理からも消えることを購読者数で確認します (解除されても配送されないだけの
  /// 実装では、購読者の管理が解放されずに残ります)。
  func testReleasingStreamRemovesSubscription() throws {
    let mediaChannel = try makeMediaChannel()

    do {
      let stream = mediaChannel.subscribeEvents()
      // stream をスコープの終わりまで生かしたまま購読者を確認する。
      withExtendedLifetime(stream) {
        XCTAssertEqual(
          mediaChannel.eventSubscriptionCountForTesting, 1, "購読の開始で購読者が登録されること")
      }
    }

    XCTAssertEqual(
      mediaChannel.eventSubscriptionCountForTesting, 0, "stream の解放で購読が解除されること")
  }

  /// 接続の終了で `.disconnected` を配送してから stream が終端すること。
  ///
  /// 終端後の購読には終端済みの stream を返し、以降のイベントを配送しないことを確認します。
  func testStreamFinishesAfterDisconnectedEventAndFinishedStreamIsReturned() async throws {
    let mediaChannel = try makeMediaChannel()
    let stream = mediaChannel.subscribeEvents()

    mediaChannel.publishEvent(kind: .disconnected, closeEvent: .ok(code: 1000, reason: "done"))
    mediaChannel.finishEvents()

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.map(\.kind), [.disconnected], "終端の前に切断イベントが届くこと")
    guard case .ok(let code, let reason)? = events.first?.closeEvent else {
      XCTFail("切断イベントに SoraCloseEvent が入っていない")
      return
    }
    XCTAssertEqual(code, 1000)
    XCTAssertEqual(reason, "done")

    let afterFinish = mediaChannel.subscribeEvents()
    let afterFinishEvents = await collectAllEvents(afterFinish)
    XCTAssertTrue(afterFinishEvents.isEmpty, "終端後の購読には何も配送されないこと")
  }

  /// イベントが接続情報、通し番号、payload を持つこと。
  func testEventCarriesConnectionIdTransportEpochAndPayload() async throws {
    let mediaChannel = try makeMediaChannel()
    let stream = mediaChannel.subscribeEvents()

    mediaChannel.publishEvent(kind: .connected)
    mediaChannel.publishEvent(kind: .videoEnabledChanged, streamId: "stream-1", isEnabled: true)
    mediaChannel.publishEvent(
      kind: .dataChannelMessage, dataChannelLabel: "#messaging", dataChannelMessage: Data([1, 2]))
    mediaChannel.finishEvents()

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.map(\.kind), [.connected, .videoEnabledChanged, .dataChannelMessage])
    guard confirmEventCount(events, 3) else {
      return
    }

    // 未接続の MediaChannel では接続 ID が無く、transport epoch は 0 のままである。
    XCTAssertNil(events[0].connectionId)
    XCTAssertEqual(events[0].transportEpoch, 0)
    XCTAssertEqual(events.map(\.sequence), [1, 2, 3])

    XCTAssertEqual(events[1].kind, .videoEnabledChanged)
    XCTAssertEqual(events[1].streamId, "stream-1")
    XCTAssertEqual(events[1].isEnabled, true)

    XCTAssertEqual(events[2].kind, .dataChannelMessage)
    XCTAssertEqual(events[2].dataChannelLabel, "#messaging")
    XCTAssertEqual(events[2].dataChannelMessage, Data([1, 2]))
    XCTAssertNil(events[2].error, "該当しない payload は nil であること")
    XCTAssertNil(events[2].closeEvent, "該当しない payload は nil であること")
  }

  /// `Sora` インスタンスの購読がインスタンス単位のイベントを配送すること।
  func testSoraSubscriptionDeliversInstanceEvents() async throws {
    let stream = makeSoraEventsAfterPublishing { sora in
      sora.publishEvent(kind: .mediaChannelAdded, connectionId: "connection-1")
      sora.publishEvent(
        kind: .audioRouteChanged,
        audioRoute: SoraAudioRouteEvent(
          reason: .newDeviceAvailable,
          previousRoute: SoraAudioRouteSnapshot(inputs: [], outputs: [])))
    }

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.map(\.kind), [.mediaChannelAdded, .audioRouteChanged])
    XCTAssertEqual(events.map(\.sequence), [1, 2], "Sora インスタンス単位でも通し番号が進むこと")
    guard confirmEventCount(events, 2) else {
      return
    }
    XCTAssertEqual(events[0].connectionId, "connection-1")
    XCTAssertEqual(events[1].audioRoute?.reason, .newDeviceAvailable)
  }

  /// `Sora` 側の配送点 (`add` / `remove`) がイベントとして配送されること。
  ///
  /// `Sora.connect` を通さずに配送点を直接確認します。追加は接続の開始前、除去は接続の終了後に
  /// 呼ばれるため、どちらも接続 ID は確定していません。
  func testSoraAddAndRemoveMediaChannelAreDeliveredAsEvents() async throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSoraEventsAfterPublishing { sora in
      sora.add(mediaChannel: mediaChannel)
      sora.remove(mediaChannel: mediaChannel)
    }

    let events = await collectAllEvents(stream)

    XCTAssertEqual(events.map(\.kind), [.mediaChannelAdded, .mediaChannelRemoved])
    guard confirmEventCount(events, 2) else {
      return
    }
    XCTAssertNil(events[0].connectionId, "接続前の追加では接続 ID が未確定であること")
    XCTAssertEqual(events[0].transportEpoch, 0)
    XCTAssertNil(events[1].connectionId)
    XCTAssertEqual(events[1].transportEpoch, 0)
  }

  /// `MediaChannel` の解放で購読が終端すること。
  ///
  /// 明示切断を経由せずに解放された場合も `deinit` が購読を終端します。終端しない場合は
  /// ここでタイムアウトして失敗します。
  @MainActor
  func testReleasingMediaChannelFinishesSubscriptions() async throws {
    let stream = try makeStreamReleasingMediaChannel()
    let finished = expectation(description: "解放で購読が終端すること")
    Task { @MainActor in
      for await _ in stream {}
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 5)
  }

  /// 設定エラーで終端した接続が `Sora` の購読へ `.connectFailed` として配送されること。
  ///
  /// `Sora.connect` の設定エラー経路を実サーバーなしで確認します。
  @MainActor
  func testSoraConfigurationErrorIsDeliveredAsConnectFailed() async throws {
    let sora = Sora()
    let stream = sora.subscribeEvents()
    let received = expectation(description: "connectFailed が配送されること")
    var connectFailedEvent: SoraEvent?

    Task { @MainActor in
      for await event in stream where event.kind == .connectFailed {
        connectFailedEvent = event
        received.fulfill()
        break
      }
    }

    var configuration = Self.makeConfiguration()
    // JSON 化できない dataChannels は接続開始前に設定エラーとして終端する。
    configuration.dataChannels = Data([0x01])
    _ = sora.connect(configuration: configuration) { _, _ in }

    await fulfillment(of: [received], timeout: 10)
    XCTAssertEqual(connectFailedEvent?.kind, .connectFailed)
    XCTAssertNotNil(connectFailedEvent?.error, "設定エラーの snapshot が載ること")
    XCTAssertNil(connectFailedEvent?.connectionId, "接続前のため connectionId は nil であること")
  }

  /// 購読している `Task` の loop から同期 API と購読 API を呼べること。
  ///
  /// 配送は購読者を管理する storage の排他区間の外で行うため、購読者のコードから同期 getter、
  /// 購読 API、配送 API を呼べます。ここでは呼び出しが停止せず、再入した配送も購読者へ届くこと、
  /// loop の中で作った購読が stream の解放で解除されることを確認します。
  @MainActor
  func testReentrantCallsFromSubscriptionDoNotDeadlock() async throws {
    let mediaChannel = try makeMediaChannel()
    let stream = mediaChannel.subscribeEvents()
    let received = expectation(description: "購読が 2 件のイベントを受け取ること")
    var kinds: [SoraEventKind] = []

    Task { @MainActor in
      for await event in stream {
        kinds.append(event.kind)
        // 購読 loop の中から同期 getter、購読 API、配送 API を呼ぶ。
        _ = mediaChannel.state
        _ = mediaChannel.connectionId
        _ = mediaChannel.subscribeEvents()
        if kinds.count == 1 {
          mediaChannel.publishEvent(kind: .streamAdded, streamId: "reentrant")
        } else {
          received.fulfill()
          break
        }
      }
    }

    mediaChannel.publishEvent(kind: .connected)
    await fulfillment(of: [received], timeout: 10)
    XCTAssertEqual(kinds, [.connected, .streamAdded], "再入した配送も購読者へ届くこと")
    // loop の中で作った購読は、その stream の解放で解除される。
    waitForSubscriptionCount(1) { mediaChannel.eventSubscriptionCountForTesting }
  }

  /// redirect で transport epoch が進み、その後のイベントが新しい世代を運ぶこと。
  ///
  /// 実サーバーから redirect を起こせないため、signaling の受信ハンドラーへ redirect を直接渡します
  /// (`PeerChannelRedirectInvalidationTests` と同じ手法)。イベントの配送点は接続を必要とするため、
  /// ここでは `transportEpoch` が接続の現在の世代を運ぶことを確認します。
  func testEventTransportEpochFollowsRedirectGeneration() async throws {
    let mediaChannel = try makeMediaChannel()
    let stream = mediaChannel.subscribeEvents()
    let peerChannel = mediaChannel.peerChannel

    let generationBefore = peerChannel.dataChannelGeneration
    mediaChannel.publishEvent(kind: .signalingReceivedJSON, signalingJSON: "{}")

    // redirect を signaling の受信ハンドラーへ直接渡し、世代を進める。
    peerChannel.signalingChannel.internalHandlers.onReceive?(
      .redirect(SignalingRedirect(location: "wss://example.com/signaling")))
    XCTAssertGreaterThan(
      peerChannel.dataChannelGeneration, generationBefore, "redirect で世代が進むこと")

    mediaChannel.publishEvent(kind: .signalingReceivedJSON, signalingJSON: "{}")
    mediaChannel.finishEvents()

    let events = await collectAllEvents(stream)
    guard confirmEventCount(events, 2) else {
      return
    }
    XCTAssertEqual(events[0].transportEpoch, generationBefore, "redirect 前のイベントは旧世代を運ぶこと")
    XCTAssertEqual(
      events[1].transportEpoch, peerChannel.dataChannelGeneration,
      "redirect 後のイベントは新しい世代を運ぶこと")
  }

  /// 種別が拡張可能であること。
  ///
  /// `SoraEventKind` は `RawRepresentable` な struct のため、SDK が種別を追加しても利用者の
  /// 既存コード (等価比較と `default` を伴う switch) は compile でき続けます。未知の種別でも
  /// 値として扱えることをここで確認します。
  func testEventKindIsExtensible() {
    let futureKind = SoraEventKind(rawValue: "futureEvent")

    XCTAssertEqual(futureKind.rawValue, "futureEvent")
    XCTAssertNotEqual(futureKind, SoraEventKind.connected)
    XCTAssertEqual(SoraEventKind(rawValue: "connected"), SoraEventKind.connected)
  }

  /// DataChannel のメッセージ受信が購読 API のイベントとして配送されること。
  ///
  /// 実 `RTCDataChannel` と受信経路の delegate を使い、配送点を確認します。legacy handler を
  /// 設定していなくても購読者へ配送されることも併せて確認します。
  func testDataChannelMessageIsDeliveredAsEvent() async throws {
    let mediaChannel = try makeTestMediaChannel()
    let peerChannel = mediaChannel.peerChannel

    // 受信経路は登録済みの DataChannel を参照するため、送信と同じ経路で登録する。
    let peerConnection = try makeTestPeerConnection(
      factory: peerChannel.nativePeerChannelFactory)
    let nativeDataChannel = try makeTestDataChannel(peerConnection: peerConnection, label: "#spam")
    peerChannel.register(
      dataChannel: DataChannel(
        dataChannel: nativeDataChannel,
        compress: false,
        mediaChannel: mediaChannel,
        peerChannel: peerChannel,
        generation: peerChannel.dataChannelGeneration))

    let stream = mediaChannel.subscribeEvents()
    let message = Data("sora-event".utf8)
    BasicDataChannelDelegate(
      compress: false,
      mediaChannel: mediaChannel,
      peerChannel: peerChannel,
      generation: peerChannel.dataChannelGeneration
    ).dataChannel(
      nativeDataChannel,
      didReceiveMessageWith: RTCDataBuffer(data: message, isBinary: false))
    mediaChannel.finishEvents()

    var received: [SoraEvent] = []
    for await event in stream {
      received.append(event)
    }

    XCTAssertEqual(received.map(\.kind), [.dataChannelMessage])
    guard confirmEventCount(received, 1) else {
      return
    }
    XCTAssertEqual(received[0].dataChannelLabel, "#spam")
    XCTAssertEqual(received[0].dataChannelMessage, message)
  }

  /// イベント数が期待値であることを確認します。
  ///
  /// 期待値でない場合はメッセージを記録して `false` を返します。呼び出し側は `guard` で戻り、
  /// 添字アクセスでのクラッシュ (テストプロセスが落ちて他のテストの結果も失われる) を防ぎます。
  private func confirmEventCount(
    _ events: [SoraEvent], _ expected: Int, file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    guard events.count == expected else {
      XCTFail("イベント数が \(expected) 件であること (実際: \(events.count) 件)", file: file, line: line)
      return false
    }
    return true
  }

  /// 購読者数が期待値になるまで、呼び出し側のスレッドで runloop を回して待ちます。
  ///
  /// 購読の解除は配送スレッドで行われるため、解除の直後に購読者数が減っているとは限りません。
  /// `MediaChannel` を actor 境界へ渡さずに済むよう、値を closure で受け取る同期メソッドにします。
  private func waitForSubscriptionCount(
    _ expected: Int, timeout: TimeInterval = 5, count: () -> Int
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && count() != expected {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(count(), expected, "購読者数が \(expected) であること")
  }
}

/// stream を終端まで読み切り、届いたイベントを返します。
private func collectAllEvents(_ stream: AsyncStream<SoraEvent>) async -> [SoraEvent] {
  var events: [SoraEvent] = []
  for await event in stream {
    events.append(event)
  }
  return events
}
