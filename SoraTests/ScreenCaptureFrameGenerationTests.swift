import CoreMedia
import CoreVideo
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

/// 画面共有の capture ID 世代管理と sample buffer 所有境界に関するユニットテスト
///
/// 画面共有を停止して直ちに再開始したときに、停止前に送信キューへ投入された旧フレームが
/// 古い sender stream を使わないことを capture ID の世代判定で検証する。
/// あわせて、送信キューへ渡す値が所有権を持つ表現だけであること、間引きと semaphore の
/// 取得失敗で破棄されるフレームで transformer が実行されないことを検証する。
/// モックやスタブは使用しない。
final class ScreenCaptureFrameGenerationTests: XCTestCase {
  /// 送信された frame 数を数える実 VideoFilter です。
  ///
  /// モックではなく実プロトコルの実装であり、`BasicMediaStream.send(videoFrame:)` から
  /// 実際に呼ばれた回数だけを記録します。
  private final class CountingVideoFilter: VideoFilter {
    /// filter が呼ばれた回数です。
    private(set) var count = 0
    /// filter が受け取った frame の timestamp です。送信された frame の PTS を確認するために記録します。
    private(set) var timestamps: [CMTime] = []

    /// 呼び出し回数と frame の timestamp を記録し、frame をそのまま返します。
    func filter(videoFrame: VideoFrame) -> VideoFrame {
      count += 1
      if let timestamp = videoFrame.timestamp {
        timestamps.append(timestamp)
      }
      return videoFrame
    }
  }
  // ScreenCaptureController と MediaChannel を構築する
  private func makeScreenCaptureController() throws -> (
    controller: ScreenCaptureController, mediaChannel: MediaChannel
  ) {
    let mediaChannel = try MediaChannel(configuration: makeTestConfiguration())
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

  // 2 つの CMTime が同じ時刻を表すかどうかを返す
  //
  // CMTime は value / timescale の組み合わせで表されるため、値の比較ではなく CMTimeCompare で判定する。
  private func timeEquals(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
    CMTimeCompare(lhs, rhs) == 0
  }

  // テストで共通利用する実 CMSampleBuffer を生成する
  //
  // 実 CoreVideo / CoreMedia の API で image buffer を持つ sample buffer を生成する。
  // モックやスタブは使用しない。
  private func makeSampleBuffer(
    presentationTimestamp: CMTime,
    width: Int = 64,
    height: Int = 48
  ) -> CMSampleBuffer? {
    var createdPixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ]
    let pixelBufferStatus = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &createdPixelBuffer)
    guard pixelBufferStatus == kCVReturnSuccess, let pixelBuffer = createdPixelBuffer else {
      return nil
    }

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription)
    guard formatStatus == noErr, let formatDescription else {
      return nil
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: presentationTimestamp,
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let sampleBufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer)
    guard sampleBufferStatus == noErr, let sampleBuffer else {
      return nil
    }
    return sampleBuffer
  }

  // テストで共通利用する、image buffer を持たない video sample buffer を実 API で生成する
  //
  // ReplayKit が渡す video sample buffer は image buffer を含むためこの入力にはならないが、
  // transformer の戻り値は型で video buffer と強制されないため、VideoFrame の生成失敗経路は
  // 利用者入力から到達し得る。CMBlockBuffer と format description から image buffer を持たない
  // sample buffer を組み立て、その経路を決定的に再現する。
  private func makeSampleBufferWithoutImage(
    presentationTimestamp: CMTime,
    width: Int = 64,
    height: Int = 48
  ) -> CMSampleBuffer? {
    // 画素データを持たないが sample buffer としては成立するバッファを用意する
    let dataLength = width * height * 4
    var blockBuffer: CMBlockBuffer?
    let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: dataLength,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: dataLength,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard blockBufferStatus == kCMBlockBufferNoErr, let blockBuffer else {
      return nil
    }

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: kCVPixelFormatType_32BGRA,
      width: Int32(width),
      height: Int32(height),
      extensions: nil,
      formatDescriptionOut: &formatDescription)
    guard formatStatus == noErr, let formatDescription else {
      return nil
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: presentationTimestamp,
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let sampleBufferStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer)
    guard sampleBufferStatus == noErr, let sampleBuffer else {
      return nil
    }
    return sampleBuffer
  }

  // テストで共通利用する所有権付き frame を生成する
  //
  // 送信キューの代わりに performSend へ直接投入する場合に使用する。
  private func makeOwnedFrame(
    sampleBuffer: CMSampleBuffer,
    captureID: UInt64,
    presentationTimestamp: CMTime,
    videoSampleBufferTransformer: ((CMSampleBuffer) -> CMSampleBuffer?)?
  ) -> ScreenCaptureController.ScreenCaptureOwnedFrame? {
    guard
      let ownedSampleBuffer = ScreenCaptureController.ScreenCaptureOwnedSampleBuffer(sampleBuffer)
    else {
      return nil
    }
    return ScreenCaptureController.ScreenCaptureOwnedFrame(
      captureID: captureID,
      presentationTimestamp: presentationTimestamp,
      sampleBuffer: ownedSampleBuffer,
      videoSampleBufferTransformer: videoSampleBufferTransformer)
  }

  // テストで共通利用する capture ID を `.running` まで進める
  //
  // テストは MediaChannel を接続しないため、送信経路が接続状態を要求しないように設定する。
  // 接続状態の確認そのものを検証するテストは、このヘルパーの後に
  // setMediaChannelConnectionRequiredForTesting(true) で確認を有効にする。
  private func startRunningCapture(
    controller: ScreenCaptureController,
    senderStream: MediaStream,
    settings: ScreenCaptureSettings = ScreenCaptureSettings()
  ) throws -> UInt64 {
    controller.setMediaChannelConnectionRequiredForTesting(false)
    let captureID = try controller.beginStartCapture(settings: settings, senderStream: senderStream)
    guard case .success = controller.completeStartCapture(captureID: captureID, error: nil) else {
      throw SoraError.mediaChannelError(reason: "failed to complete screen capture start in test")
    }
    return captureID
  }

  /// capture A の開始後に、capture A の frame は送信でき、capture A を停止すると
  /// 送信できないことを確認する
  ///
  /// isActiveCaptureID は「現在の activeCaptureID」と引数の capture ID を照合する。
  /// stop で activeCaptureID が nil になると、不一致となり capture A の frame が拒否される。
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
  /// 停止→再開始の競合では、送信経路が実行時点の captureState しか確認しないため、
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
      let mediaChannel = try MediaChannel(configuration: makeTestConfiguration())
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

    let mediaChannel = try MediaChannel(configuration: makeTestConfiguration())
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

    let mediaChannel = try MediaChannel(configuration: makeTestConfiguration())
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

  // MARK: - sample buffer の所有境界とフレーム送出

  /// capture が停止中の frame は enqueue されないことを確認する
  ///
  /// 停止中は captureState が `.running` ではないため、所有表現への変換より前に破棄される。
  /// このとき semaphore は取得しないため、取得済みフラグは false になる。
  func testEnqueueOwnedFrameIsRejectedBeforeCaptureStarts() throws {
    let (controller, _) = try makeScreenCaptureController()
    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard
      let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }

    // capture を開始していないため captureState は .stopped である
    let enqueued = controller.enqueueOwnedFrame(
      sampleBuffer: sampleBuffer,
      presentationTimestamp: presentationTimestamp)

    // 所有表現への変換 (sample buffer のコピー) より前に破棄され、flight も取得しない
    XCTAssertFalse(enqueued, "停止中の frame は enqueue されないこと")
    XCTAssertNil(
      controller.lastSentVideoPresentationTimestampForTesting,
      "停止中の frame では送信 timestamp を更新しないこと")
  }

  /// targetFPS の間引きで破棄される frame は enqueue されないことを確認する
  ///
  /// 1 つ目の frame を送信した直後と同じ PTS の frame は、間引き判定で破棄される。
  /// 破棄は transformer より前で行われるため、transformer は呼ばれない。
  func testEnqueueOwnedFrameIsThrottledByTargetFPS() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    // transformer は間引きで破棄される frame では呼ばれてはならない
    var transformerCallCount = 0
    let captureID = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(
        targetFPS: 15,
        videoSampleBufferTransformer: { sampleBuffer in
          transformerCallCount += 1
          return sampleBuffer
        }))
    XCTAssertGreaterThan(captureID, 0, "capture ID が採番されること")

    guard
      let firstSampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    // 1 つ目の frame は送信され、timestamp が記録される
    let firstEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: firstSampleBuffer,
      presentationTimestamp: presentationTimestamp)
    XCTAssertTrue(firstEnqueued, "最初の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "最初の frame は VideoFilter へ到達すること")
    XCTAssertEqual(transformerCallCount, 1, "最初の frame では transformer が 1 回呼ばれること")

    guard
      let secondSampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    // 同じ PTS の frame は targetFPS (15fps) の間引きで破棄される
    let secondEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: secondSampleBuffer,
      presentationTimestamp: presentationTimestamp)
    XCTAssertFalse(secondEnqueued, "間引き対象の frame は enqueue されないこと")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "間引き対象の frame は VideoFilter へ到達しないこと")
    XCTAssertEqual(transformerCallCount, 1, "間引き対象の frame では transformer が呼ばれないこと")
  }

  /// 送信中の flight を保持している間に到着した frame は破棄されることを確認する
  ///
  /// semaphore は単発 flight のため、保持中に到着した frame は待たずに破棄される。
  /// 保持した flight は解放し、次の frame は enqueue できることを確認する。
  func testEnqueueOwnedFrameIsDroppedWhileFlightIsInProgress() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    _ = try startRunningCapture(controller: controller, senderStream: senderStream)

    // テスト側で flight を保持し、送信中の状態を再現する
    XCTAssertTrue(controller.tryAcquireSendFlight(), "テスト用に flight を取得できること")

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard
      let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    // 送信中のため即時取得に失敗し、frame は破棄される
    let droppedEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: sampleBuffer,
      presentationTimestamp: presentationTimestamp)
    XCTAssertFalse(droppedEnqueued, "送信中の frame は enqueue されないこと")

    // 保持していた flight を返却すると、次の frame は enqueue できる
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    controller.tryAcquireSendFlightRelease()

    let nextTimestamp = CMTime(value: 2, timescale: 1)
    guard let nextSampleBuffer = makeSampleBuffer(presentationTimestamp: nextTimestamp) else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    let nextEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: nextSampleBuffer,
      presentationTimestamp: nextTimestamp)
    XCTAssertTrue(nextEnqueued, "flight の返却後の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "flight の返却後の frame は VideoFilter へ到達すること")
  }

  /// transformer が未設定の場合は元の sample buffer がそのまま送信されることを確認する
  ///
  /// 既定の ScreenCaptureSettings() は transformer が nil である。この経路を破棄と
  /// 読み違えると既定の画面キャプチャが全フレーム破棄になるため、送信されることを確認する。
  func testProcessOwnedFrameSendsFrameWithoutTransformer() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    let captureID = try startRunningCapture(controller: controller, senderStream: senderStream)

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp),
      let ownedFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureID,
        presentationTimestamp: presentationTimestamp,
        videoSampleBufferTransformer: nil)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }

    // transformer 未設定でも frame は破棄されず、送信 timestamp も記録される
    XCTAssertTrue(
      controller.performSend(ownedFrame: ownedFrame), "frame を送信できること")
    // frame の処理は owner queue 上で行われるため、 VideoFilter を assert する前に drain する
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "transformer 未設定の frame は VideoFilter へ到達すること")
    XCTAssertEqual(
      controller.lastSentVideoPresentationTimestampForTesting,
      presentationTimestamp,
      "送信した frame の PTS が記録されること")
  }

  /// VideoFrame の生成に失敗した frame は送信されず、送信 timestamp も更新されず、
  /// semaphore が回復することを確認する
  ///
  /// transformer の戻り値は型で video buffer と強制されないため、image buffer を持たない
  /// sample buffer を返す transformer を経由してこの経路に到達し得る。破棄で throttle 状態を
  /// 汚染しないため、直後の frame は間引かれずに送信できる。
  func testProcessOwnedFrameKeepsTimestampWhenFrameConversionFails() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    // image buffer を持たない buffer を返す transformer を世代に固定して開始する
    let invalidTimestamp = CMTime(value: 1, timescale: 1)
    let invalidBuffer = try XCTUnwrap(
      makeSampleBufferWithoutImage(presentationTimestamp: invalidTimestamp))
    let transformer: (CMSampleBuffer) -> CMSampleBuffer? = { _ in invalidBuffer }
    let captureID = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(videoSampleBufferTransformer: transformer))

    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: invalidTimestamp),
      let ownedFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureID,
        presentationTimestamp: invalidTimestamp,
        videoSampleBufferTransformer: transformer)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }
    // transformer が返した buffer は image buffer を持たないため変換できない
    XCTAssertNil(
      VideoFrame(from: invalidBuffer),
      "image buffer を持たない sample buffer は VideoFrame に変換できないこと")

    XCTAssertTrue(controller.performSend(ownedFrame: ownedFrame), "処理自体は完了すること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 0, "変換に失敗した frame は送信されないこと")
    XCTAssertNil(
      controller.lastSentVideoPresentationTimestampForTesting,
      "変換に失敗した frame では PTS を記録しないこと")

    // 変換失敗で throttle 状態が汚染されないため、同じ PTS の次の frame は間引かれずに送信できる
    XCTAssertTrue(
      controller.shouldSendVideoFrame(presentationTimestamp: invalidTimestamp),
      "変換失敗で throttle 状態が汚染されないこと")

    // semaphore も回復しているため、transformer が有効な buffer を返せば送信できる
    guard let validSampleBuffer = makeSampleBuffer(presentationTimestamp: invalidTimestamp),
      let validOwnedFrame = makeOwnedFrame(
        sampleBuffer: validSampleBuffer,
        captureID: captureID,
        presentationTimestamp: invalidTimestamp,
        videoSampleBufferTransformer: nil)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }
    XCTAssertTrue(
      controller.performSend(ownedFrame: validOwnedFrame),
      "変換失敗の後の frame を送信できること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "変換失敗の後の frame は VideoFilter へ到達すること")
  }

  /// transformer が別の sample buffer を返した場合はその buffer が送信されることを確認する
  ///
  /// 返された buffer の PTS が送信に使われ、元の buffer の PTS は使われないことを確認する。
  func testProcessOwnedFrameSendsTransformedBuffer() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    let originalTimestamp = CMTime(value: 1, timescale: 1)
    let transformedTimestamp = CMTime(value: 5, timescale: 1)
    // 実 API で生成した別の sample buffer を返す transformer
    let transformedBuffer = try XCTUnwrap(
      makeSampleBuffer(presentationTimestamp: transformedTimestamp))
    var transformerCallCount = 0
    let transformer: (CMSampleBuffer) -> CMSampleBuffer? = { _ in
      transformerCallCount += 1
      return transformedBuffer
    }
    let captureID = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(videoSampleBufferTransformer: transformer))

    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: originalTimestamp),
      let ownedFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureID,
        presentationTimestamp: originalTimestamp,
        videoSampleBufferTransformer: transformer)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }

    // 送信される frame は transformer が返した buffer から生成される
    XCTAssertTrue(
      controller.performSend(ownedFrame: ownedFrame), "frame を送信できること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(transformerCallCount, 1, "payload の transformer が呼ばれること")
    XCTAssertEqual(filter.count, 1, "transformer が返した frame は VideoFilter へ到達すること")

    // VideoFilter が受け取った frame の PTS が transformer の戻り値の PTS であること。
    // 戻り値を無視して元の buffer を送る実装では、ここが元の PTS になって失敗する。
    XCTAssertEqual(filter.timestamps.count, 1, "送信された frame の timestamp を記録できること")
    let sentTimestamp = try XCTUnwrap(filter.timestamps.first)
    XCTAssertTrue(
      timeEquals(sentTimestamp, transformedTimestamp),
      "送信された frame の PTS は transformer が返した buffer の PTS であること")
    XCTAssertFalse(
      timeEquals(sentTimestamp, originalTimestamp),
      "送信された frame の PTS は元の buffer の PTS ではないこと")

    // throttle の記録は payload が持つ元の PTS を使う (改修前どおり)
    let recordedTimestamp = try XCTUnwrap(controller.lastSentVideoPresentationTimestampForTesting)
    XCTAssertTrue(
      timeEquals(recordedTimestamp, originalTimestamp),
      "throttle の記録には payload の PTS を使うこと")
  }

  /// transformer が frame を drop した場合は送信 timestamp を更新し、
  /// semaphore を回復することを確認する
  ///
  /// 破棄された frame は throttle 状態を汚染しないため、直後の frame が間引かれずに送信される。
  /// `VideoFrame(from:)` の生成に失敗する経路は実 CoreMedia API で決定的に作れないため、
  /// ここでは transformer の drop 経路で同じ不変条件 (破棄では timestamp を更新しない) を確認する。
  func testProcessOwnedFrameKeepsTimestampWhenTransformerDropsFrame() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    // 1 件目は drop し、2 件目はそのまま返す transformer を世代に固定して開始する
    var transformerCallCount = 0
    let transformer: (CMSampleBuffer) -> CMSampleBuffer? = { sampleBuffer in
      transformerCallCount += 1
      return transformerCallCount == 1 ? nil : sampleBuffer
    }
    let captureID = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(videoSampleBufferTransformer: transformer))

    let droppedTimestamp = CMTime(value: 1, timescale: 1)
    guard let droppedSampleBuffer = makeSampleBuffer(presentationTimestamp: droppedTimestamp),
      let droppedOwnedFrame = makeOwnedFrame(
        sampleBuffer: droppedSampleBuffer,
        captureID: captureID,
        presentationTimestamp: droppedTimestamp,
        videoSampleBufferTransformer: transformer)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }

    XCTAssertTrue(
      controller.performSend(ownedFrame: droppedOwnedFrame),
      "処理自体は完了すること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 0, "drop された frame は送信されないこと")
    XCTAssertNil(
      controller.lastSentVideoPresentationTimestampForTesting,
      "drop された frame では PTS を記録しないこと")

    // drop で throttle 状態が汚染されないため、同じ PTS の次の frame は間引かれずに送信できる
    XCTAssertTrue(
      controller.shouldSendVideoFrame(presentationTimestamp: droppedTimestamp),
      "drop で throttle 状態が汚染されないこと")

    // semaphore も回復し、2 件目は transformer を通過するため送信できる
    guard let nextSampleBuffer = makeSampleBuffer(presentationTimestamp: droppedTimestamp),
      let nextOwnedFrame = makeOwnedFrame(
        sampleBuffer: nextSampleBuffer,
        captureID: captureID,
        presentationTimestamp: droppedTimestamp,
        videoSampleBufferTransformer: transformer)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }
    XCTAssertTrue(
      controller.performSend(ownedFrame: nextOwnedFrame),
      "次の frame を送信できること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "drop の後の frame は VideoFilter へ到達すること")
  }

  /// 旧世代の capture ID を持つ frame は送信されないことを確認する
  ///
  /// 停止してから再開始すると capture ID が進む。旧世代の frame は送信直前の照合で
  /// 破棄され、現行世代の frame は送信される。停止直後の再開始で旧フレームが送信される
  /// 不具合の回帰確認である。
  func testProcessOwnedFrameRejectsStaleCaptureID() async throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    let captureAID = try startRunningCapture(controller: controller, senderStream: senderStream)
    XCTAssertGreaterThan(captureAID, 0, "capture A の ID が採番されること")
    XCTAssertEqual(filter.count, 0, "開始直後は送信されていないこと")

    // capture A を停止し、停止完了させる
    guard let stopTask = controller.stopCaptureForDisconnect() else {
      XCTFail("capture A の停止が受理されること")
      return
    }
    await stopTask.value

    // capture B を開始して世代を進める
    let captureBID = try startRunningCapture(controller: controller, senderStream: senderStream)
    XCTAssertNotEqual(captureBID, captureAID, "capture B の ID は A と異なること")

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp),
      let staleFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureAID,
        presentationTimestamp: presentationTimestamp,
        videoSampleBufferTransformer: nil),
      let currentFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureBID,
        presentationTimestamp: presentationTimestamp,
        videoSampleBufferTransformer: nil)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }

    // 旧世代 (capture A) の frame は送信されない
    XCTAssertTrue(
      controller.performSend(ownedFrame: staleFrame), "処理自体は完了すること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 0, "旧世代の frame は VideoFilter へ到達しないこと")
    XCTAssertNil(
      controller.lastSentVideoPresentationTimestampForTesting,
      "旧世代の frame では PTS を記録しないこと")

    // 現行世代 (capture B) の frame は送信される
    XCTAssertTrue(
      controller.performSend(ownedFrame: currentFrame),
      "現行世代の frame を送信できること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "現行世代の frame は VideoFilter へ到達すること")
    XCTAssertEqual(
      controller.lastSentVideoPresentationTimestampForTesting,
      presentationTimestamp,
      "現行世代の frame の PTS が記録されること")
  }

  /// 接続中でない場合は接続状態の判定が false になることを確認する
  ///
  /// 送信経路は capture state と接続状態を別々に確認する。未接続では接続状態の判定が false になる。
  func testIsMediaChannelConnectedIsFalseWhileDisconnected() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)
    _ = try startRunningCapture(controller: controller, senderStream: senderStream)

    XCTAssertFalse(
      controller.isMediaChannelConnected(),
      "未接続では接続状態の判定が false になること")
  }

  /// 未接続の場合は接続状態の確認で frame が破棄され、transformer も実行されないことを確認する
  ///
  /// 接続状態の確認は transformer より前に行う。切断中に到着した frame では利用者の
  /// transformer を呼ばずに破棄する。接続状態の確認を有効にしたまま本番の queue closure と
  /// 同じ `processOwnedFrame` を呼び、破棄されることを確認する。
  func testProcessOwnedFrameRejectsFrameWhileDisconnected() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    // transformer が呼ばれたかどうかを数える。接続状態の確認は transformer より前に行うため、
    // 未接続の frame ではこのクロージャーが呼ばれてはならない。
    var transformerCallCount = 0
    let captureID = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(videoSampleBufferTransformer: { sampleBuffer in
        transformerCallCount += 1
        return sampleBuffer
      }))
    // 接続状態の確認を有効にし、本番の queue closure と同じ経路を駆動する
    controller.setMediaChannelConnectionRequiredForTesting(true)
    XCTAssertFalse(controller.isMediaChannelConnected(), "テストの MediaChannel は未接続であること")

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp),
      let ownedFrame = makeOwnedFrame(
        sampleBuffer: sampleBuffer,
        captureID: captureID,
        presentationTimestamp: presentationTimestamp,
        videoSampleBufferTransformer: nil)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }

    XCTAssertTrue(controller.tryAcquireSendFlight(), "テスト用に flight を取得できること")
    controller.processOwnedFrame(ownedFrame)
    // send は非同期のため、filter へ到達しないことを「まだ処理されていないだけ」で
    // 通さないように owner queue まで drain してから assert する
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(transformerCallCount, 0, "未接続の frame では transformer が実行されないこと")
    XCTAssertEqual(filter.count, 0, "未接続の frame は VideoFilter へ到達しないこと")
    XCTAssertNil(
      controller.lastSentVideoPresentationTimestampForTesting,
      "未接続の frame では PTS を記録しないこと")
  }

  /// 送信対象の frame では transformer が実行されることを確認する
  ///
  /// 間引きと semaphore の取得を通過した frame だけが transformer の対象になる。
  func testTransformerRunsOnlyForSendableFrame() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter

    var transformerCallCount = 0
    _ = try startRunningCapture(
      controller: controller,
      senderStream: senderStream,
      settings: ScreenCaptureSettings(
        targetFPS: 15,
        videoSampleBufferTransformer: { sampleBuffer in
          transformerCallCount += 1
          return sampleBuffer
        }))

    let firstTimestamp = CMTime(value: 1, timescale: 1)
    let secondTimestamp = CMTime(value: 2, timescale: 1)
    guard let firstSampleBuffer = makeSampleBuffer(presentationTimestamp: firstTimestamp),
      let secondSampleBuffer = makeSampleBuffer(presentationTimestamp: secondTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }

    let firstEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: firstSampleBuffer,
      presentationTimestamp: firstTimestamp)
    XCTAssertTrue(firstEnqueued, "最初の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)

    let secondEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: secondSampleBuffer,
      presentationTimestamp: secondTimestamp)
    XCTAssertTrue(secondEnqueued, "間隔の空いた frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)

    XCTAssertEqual(transformerCallCount, 2, "送信対象の frame では transformer が実行されること")
    XCTAssertEqual(filter.count, 2, "送信対象の frame は VideoFilter へ到達すること")
  }

  /// PTS が無効な frame は単調時刻で間引かれることを確認する
  ///
  /// PTS が `.invalid` または `.indefinite` の場合は、前回の送信からの経過時間で判定する。
  /// targetFPS の短い間隔では破棄され、間隔が経過すると送信される。
  func testShouldSendVideoFrameFallsBackToUptimeWhenTimestampIsInvalid() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    let captureID = try startRunningCapture(controller: controller, senderStream: senderStream)

    // 1 件目は送信され、単調時刻が記録される
    let firstTimestamp = CMTime(value: 1, timescale: 1)
    guard let firstSampleBuffer = makeSampleBuffer(presentationTimestamp: firstTimestamp),
      let firstOwnedFrame = makeOwnedFrame(
        sampleBuffer: firstSampleBuffer,
        captureID: captureID,
        presentationTimestamp: firstTimestamp,
        videoSampleBufferTransformer: nil)
    else {
      XCTFail("テスト用の所有権付き frame を生成できること")
      return
    }
    XCTAssertTrue(controller.performSend(ownedFrame: firstOwnedFrame), "最初の frame を送信できること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)

    // PTS が無効な frame は単調時刻のフォールバックで判定され、直後は破棄される
    XCTAssertFalse(
      controller.shouldSendVideoFrame(presentationTimestamp: .invalid),
      "PTS が無効な frame は間隔が経過するまで破棄されること")

    // 間隔が経過すると送信される
    Thread.sleep(forTimeInterval: 0.15)
    XCTAssertTrue(
      controller.shouldSendVideoFrame(presentationTimestamp: .invalid),
      "PTS が無効でも間隔が経過すれば送信されること")
  }

  /// 送信経路が permit を二重に返却しないことを確認する
  ///
  /// `enqueueOwnedFrame` が取得した permit は `processOwnedFrame` の `defer` が 1 回だけ返却する。
  /// 送信キューと owner queue を drain しても permit は消費されないため、
  /// drain の直後に存在する permit は 1 つだけである。二重 signal があると permit が 2 つになり、
  /// 続けて 2 回取得できてしまい単発 flight の契約が壊れる。
  func testSendFlightIsNotDoublyReleasedAfterSend() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    _ = try startRunningCapture(controller: controller, senderStream: senderStream)

    let firstTimestamp = CMTime(value: 1, timescale: 1)
    guard let firstSampleBuffer = makeSampleBuffer(presentationTimestamp: firstTimestamp) else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    let firstEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: firstSampleBuffer,
      presentationTimestamp: firstTimestamp)
    XCTAssertTrue(firstEnqueued, "最初の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 1, "送信された frame は VideoFilter へ到達すること")

    // permit は 1 つだけ存在するため、2 回目の取得は失敗する
    XCTAssertTrue(controller.tryAcquireSendFlight(), "1 回目の permit 取得は成功すること")
    XCTAssertFalse(
      controller.tryAcquireSendFlight(),
      "enqueue した frame の処理で permit が二重に返却されないこと")
    controller.tryAcquireSendFlightRelease()

    // 続けて 2 件目を送信した後も permit は 1 つだけ存在する
    let secondTimestamp = CMTime(value: 2, timescale: 1)
    guard let secondSampleBuffer = makeSampleBuffer(presentationTimestamp: secondTimestamp) else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    let secondEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: secondSampleBuffer,
      presentationTimestamp: secondTimestamp)
    XCTAssertTrue(secondEnqueued, "2 件目の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 2, "2 件目の frame も VideoFilter へ到達すること")
    XCTAssertTrue(controller.tryAcquireSendFlight(), "2 件目の後も permit は 1 つだけ存在すること")
    XCTAssertFalse(
      controller.tryAcquireSendFlight(),
      "2 件目を送信した後も permit が二重に返却されないこと")
    controller.tryAcquireSendFlightRelease()
  }

  /// 破棄した frame の permit が返却されることを確認する
  ///
  /// 間引きで破棄される frame は permit を取得しない。そのため破棄の直後でも permit は 1 つ
  /// しか存在せず、続けて送信対象の frame を enqueue できる。破棄時に permit を取得したまま
  /// 返却しない実装では、以降のフレームが全て破棄される。
  func testSendFlightIsReturnedWhenFrameIsRejected() throws {
    let (controller, mediaChannel) = try makeScreenCaptureController()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = CountingVideoFilter()
    senderStream.videoFilter = filter
    _ = try startRunningCapture(controller: controller, senderStream: senderStream)

    let presentationTimestamp = CMTime(value: 1, timescale: 1)
    guard let sampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp) else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    // 1 つ目の frame を送信して throttle の基準時刻を記録する
    let firstEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: sampleBuffer,
      presentationTimestamp: presentationTimestamp)
    XCTAssertTrue(firstEnqueued, "最初の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)

    // 同じ PTS の frame は間引きで破棄され、permit を取得しない
    guard let rejectedSampleBuffer = makeSampleBuffer(presentationTimestamp: presentationTimestamp)
    else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    let rejected = controller.enqueueOwnedFrame(
      sampleBuffer: rejectedSampleBuffer,
      presentationTimestamp: presentationTimestamp)
    XCTAssertFalse(rejected, "間引き対象の frame は enqueue されないこと")

    // 破棄時に permit を取得したまま返却しない実装では、ここで失敗する
    let nextTimestamp = CMTime(value: 2, timescale: 1)
    guard let nextSampleBuffer = makeSampleBuffer(presentationTimestamp: nextTimestamp) else {
      XCTFail("テスト用の CMSampleBuffer を生成できること")
      return
    }
    let nextEnqueued = controller.enqueueOwnedFrame(
      sampleBuffer: nextSampleBuffer,
      presentationTimestamp: nextTimestamp)
    XCTAssertTrue(nextEnqueued, "破棄の後の frame は enqueue されること")
    drainSendVideoFrameQueueAndOwner(controller: controller, senderStream: senderStream)
    XCTAssertEqual(filter.count, 2, "破棄の後に送信された frame は VideoFilter へ到達すること")
  }
}
