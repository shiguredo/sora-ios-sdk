import XCTest

@testable import Sora

/// 非同期操作をテスト側で明示的に再開するための同期ゲート
private actor ScreenCaptureTestGate {
  private var isOpen = false
  private var isWaiting = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var waitingObservers: [CheckedContinuation<Void, Never>] = []

  /// ゲートが開くまで待機する
  func wait() async {
    if isOpen {
      return
    }
    isWaiting = true
    let observers = waitingObservers
    waitingObservers.removeAll()
    for observer in observers {
      observer.resume()
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  /// 操作がゲートで待機を開始するまで待つ
  func waitUntilBlocked() async {
    if isWaiting {
      return
    }
    await withCheckedContinuation { continuation in
      waitingObservers.append(continuation)
    }
  }

  /// 待機中の操作を再開する
  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

/// 非同期操作の実行順を記録するテスト用コンテナ
private actor ScreenCaptureOperationOrder {
  private var storage: [Int] = []

  /// 実行された操作番号を記録する
  func append(_ value: Int) {
    storage.append(value)
  }

  /// 現在までの実行順を返す
  var values: [Int] {
    storage
  }
}

/// 画面共有の capture ID 世代管理に関するユニットテスト
///
/// 画面共有を停止して直ちに再開始したときに、停止前に送信キューへ投入された旧フレームが
/// 古い sender stream を使わないことを、capture ID の世代判定 (isActiveCaptureID) で
/// 検証する。モックやスタブは使用しない。
final class ScreenCaptureFrameGenerationTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return url
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    let url = makeTestURL()
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
  }

  // ScreenCaptureController と MediaChannel を構築する
  private func makeScreenCaptureController() throws -> (
    controller: ScreenCaptureController, mediaChannel: MediaChannel
  ) {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let controller = ScreenCaptureController(mediaChannel: mediaChannel)
    return (controller, mediaChannel)
  }

  // テストで共通利用する senderStream を構築する
  private func makeSenderStream(mediaChannel: MediaChannel) -> MediaStream {
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeStream(streamId: "test-stream")
    return BasicMediaStream(peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
  }

  // テストで共通利用する ScreenCaptureSettings を構築する
  private func makeSettings() -> ScreenCaptureSettings {
    ScreenCaptureSettings()
  }

  /// capture A の開始後に、capture A の frame は送信でき、capture A を停止すると
  /// 送信できないことを確認する
  ///
  /// isActiveCaptureID は「context が保持する capture ID」(capture A) と
  /// 現在の activeCaptureID を照合する。stop で activeCaptureID が nil になると、
  /// 送信直前の照合で capture A の frame が拒否される。
  func testFrameForStoppedCaptureIsRejected() async throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    // capture A を開始する
    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // capture A の frame は送信できる (送信直前の照合で一致)
    XCTAssertTrue(
      controller.isActiveCaptureID(captureAID),
      "実行中の capture の frame は送信できること")

    // capture A を停止する (activeCaptureID が nil になる)
    guard let stopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("停止が受理されること")
      return
    }
    await stopTask.value

    // 停止後の capture A の frame は送信できない
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID),
      "停止した capture の frame は送信できないこと")
  }

  /// capture A を停止して capture B を再開始した後、capture A の frame は送信できず、
  /// capture B の frame は送信できることを確認する
  ///
  /// 停止→再開始の競合では、isReadyToSend() が実行時点の captureState しか確認しないため、
  /// 再実行後に .running になった state では旧 capture の frame を識別できない。
  /// capture ID の照合で旧 capture (capture A) の送信を拒否し、新 capture (capture B) のみ
  /// 送信できることを検証する。実際の停止 Task の完了を待ってから
  /// beginStartCapture を呼ぶことで、実再開始のイベント列を入力する。
  func testFrameForRestartedCaptureIsRejected() async throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    // capture A を開始し、完了させる (state = .running)
    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)
    if case .success = controller.completeStartCapture(captureID: captureAID, error: nil) {
    } else {
      XCTFail("capture A の開始が完了すること")
    }

    // capture A を停止し、停止完了させる (state = .stopped)
    guard let stopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("capture A の停止が受理されること")
      return
    }
    await stopTask.value

    // capture B を即時再開始し、完了させる (state = .running)
    let captureBID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)
    XCTAssertNotEqual(captureBID, captureAID, "capture B の ID は A と異なること")
    if case .success = controller.completeStartCapture(captureID: captureBID, error: nil) {
    } else {
      XCTFail("capture B の開始が完了すること")
    }

    // capture A の frame は送信できない (旧 capture)
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID),
      "再開始後の旧 capture の frame は送信できないこと")
    // capture B の frame は送信できる (現行 capture)
    XCTAssertTrue(
      controller.isActiveCaptureID(captureBID),
      "再開始後の新 capture の frame は送信できること")
  }

  /// 現在の capture ID と一致しない frame は送信できないことを確認する
  ///
  /// 照合関数に「現在の capture ではない ID」を渡した場合に拒否されることを検証する。
  func testFrameForMismatchedCaptureIDIsRejected() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // 現在の capture ID と一致しない ID (次世代の ID と想定) は拒否される
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID + 1),
      "現在の capture と一致しない ID の frame は送信できないこと")
  }

  /// MediaChannel の最終参照解放で画面共有のフレーム送出を即時に無効化することを確認する
  func testMediaChannelDeinitInvalidatesActiveCapture() throws {
    var controller: ScreenCaptureController?
    var captureID: UInt64?
    weak var weakMediaChannel: MediaChannel?

    do {
      let mediaChannel = try MediaChannel(configuration: makeConfiguration())
      weakMediaChannel = mediaChannel
      let createdController = mediaChannel.getOrCreateScreenCaptureController()
      let senderStream = makeSenderStream(mediaChannel: mediaChannel)
      controller = createdController
      captureID = try createdController.beginStartCapture(
        settings: makeSettings(),
        senderStream: senderStream)
    }

    XCTAssertNil(weakMediaChannel, "MediaChannel の最終参照が解放されること")
    guard let controller, let captureID else {
      XCTFail("画面共有の状態を構築できること")
      return
    }
    XCTAssertFalse(
      controller.isActiveCaptureID(captureID),
      "deinit の切断準備で旧 capture のフレーム送出が無効になること")
  }

  /// stop が先行した場合、遅延した ReplayKit start を OS へ送らないことを確認する
  func testDelayedRecorderStartIsRejectedAfterStop() async throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)
    let captureID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // MainActor 上の start 実行より先に、別スレッドの切断が論理停止を確定した順序を再現する。
    guard let stopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("開始中の capture を停止できること")
      return
    }
    XCTAssertFalse(
      controller.shouldIssueRecorderStart(captureID: captureID),
      "停止後に遅れて到着した start は ReplayKit へ送られないこと")
    await stopTask.value
  }

  /// ReplayKit 操作キューが先行操作の非同期完了まで後続操作を開始しないことを確認する
  func testRecorderOperationQueueWaitsForPreviousCompletion() async {
    let operationQueue = SerializedAsyncOperationQueue()
    let gate = ScreenCaptureTestGate()
    let order = ScreenCaptureOperationOrder()

    // 先行操作をゲートで保留し、後続操作を同じキューへ投入する。
    let firstTask = operationQueue.enqueue {
      await order.append(1)
      await gate.wait()
    }
    let secondTask = operationQueue.enqueue {
      await order.append(2)
    }

    // 先行操作が待機へ入った同期点で、後続操作が始まっていないことを確認する。
    await gate.waitUntilBlocked()
    var values = await order.values
    XCTAssertEqual(values, [1], "先行操作が最初に開始されること")

    await gate.open()
    await firstTask.value
    await secondTask.value
    values = await order.values
    XCTAssertEqual(values, [1, 2], "先行操作の完了後に後続操作を開始すること")
  }

  /// process-wide recorder の所有権を別 controller が取得できないことを確認する
  func testRecorderCoordinatorRejectsAnotherOwner() {
    let coordinator = ScreenCaptureRecorderCoordinator()
    let ownerA = UUID()
    let ownerB = UUID()

    XCTAssertTrue(coordinator.acquire(ownerID: ownerA), "最初の owner が取得できること")
    XCTAssertFalse(
      coordinator.acquire(ownerID: ownerB),
      "使用中の recorder を別 owner が取得できないこと")
    XCTAssertTrue(coordinator.isOwner(ownerA), "失敗した取得で現在の owner が変わらないこと")

    // owner 以外からの解放要求では所有権を変更しない。
    coordinator.release(ownerID: ownerB)
    XCTAssertTrue(coordinator.isOwner(ownerA), "別 owner から recorder を解放できないこと")

    coordinator.release(ownerID: ownerA)
    XCTAssertTrue(
      coordinator.acquire(ownerID: ownerB),
      "現在の owner が解放した後は次の owner が取得できること")
    coordinator.release(ownerID: ownerB)
  }

  /// 停止失敗時は recorder を隔離し、停止確認後だけ次の owner を許可することを確認する
  func testRecorderCoordinatorQuarantinesFailedStop() {
    let coordinator = ScreenCaptureRecorderCoordinator()
    let ownerA = UUID()
    let ownerB = UUID()

    XCTAssertTrue(coordinator.acquire(ownerID: ownerA))
    coordinator.finishStop(ownerID: ownerA, recorderStopped: false)

    XCTAssertTrue(coordinator.isQuarantined, "停止を確認できない recorder を隔離すること")
    XCTAssertFalse(
      coordinator.acquire(ownerID: ownerB),
      "隔離中は別 owner が recorder を取得できないこと")

    coordinator.finishStop(ownerID: ownerA, recorderStopped: true)
    XCTAssertFalse(coordinator.isQuarantined, "停止確認後に隔離を解除すること")
    XCTAssertTrue(coordinator.acquire(ownerID: ownerB))
    coordinator.release(ownerID: ownerB)
  }

  /// 通常停止と切断停止が同じ未完了 Task を共有することを確認する
  func testDisconnectStopWaitsForExistingStopTask() async throws {
    let coordinator = ScreenCaptureRecorderCoordinator()
    let gate = ScreenCaptureTestGate()
    coordinator.enqueue {
      await gate.wait()
    }
    await gate.waitUntilBlocked()

    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let controller = ScreenCaptureController(
      mediaChannel: mediaChannel,
      recorderCoordinator: coordinator)
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)
    _ = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    guard let normalStopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("通常停止の Task を取得できること")
      return
    }
    guard let disconnectStopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("停止中も同じ完了待ち Task を取得できること")
      return
    }
    XCTAssertTrue(controller.isCaptureActive(), "停止 Task の完了前は stopping 状態であること")

    await gate.open()
    await normalStopTask.value
    await disconnectStopTask.value
    XCTAssertFalse(controller.isCaptureActive(), "共有停止 Task の完了後に stopped へ遷移すること")
  }

  /// MediaChannel が ReplayKit 停止完了後に切断 callback を通知することを確認する
  func testMediaChannelDisconnectWaitsForScreenCaptureStop() async throws {
    let coordinator = ScreenCaptureRecorderCoordinator()
    let gate = ScreenCaptureTestGate()
    coordinator.enqueue {
      await gate.wait()
    }
    await gate.waitUntilBlocked()

    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let controller = mediaChannel.getOrCreateScreenCaptureController(
      recorderCoordinator: coordinator)
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)
    _ = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    let disconnectExpectation = expectation(description: "画面共有停止後に切断 callback が届くこと")
    var disconnectCallbackCount = 0
    mediaChannel.handlers.onDisconnect = { _ in
      disconnectCallbackCount += 1
      disconnectExpectation.fulfill()
    }
    _ = mediaChannel.connect(webRTCConfiguration: WebRTCConfiguration()) { _ in }
    mediaChannel.disconnect(error: nil)

    XCTAssertEqual(disconnectCallbackCount, 0, "停止 Task の完了前に切断 callback を通知しないこと")
    XCTAssertTrue(controller.isCaptureActive(), "停止 Task の完了前は stopping 状態であること")

    await gate.open()
    await fulfillment(of: [disconnectExpectation], timeout: 3)
    XCTAssertEqual(disconnectCallbackCount, 1, "停止完了後に切断 callback を 1 回だけ通知すること")
    XCTAssertFalse(controller.isCaptureActive(), "切断 callback 時点で画面共有が停止済みであること")
  }
}
