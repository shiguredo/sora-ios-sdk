import XCTest

@testable import Sora

/// 通常カメラの停止キューをテスト側で明示的に再開するための同期ゲート
private actor CameraCaptureTestGate {
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

/// VideoHardMuteActor の lease / revocation 管理に関するユニットテスト
///
/// VideoHardMuteActor.setMute は実カメラ操作を含むため、カメラが利用できない
/// Simulator では mute / unmute の全体 (store / restart / stream 照合) を検証できない。
/// 本テストでは、カメラ操作に到達する前の lease / revocation のロジック
/// (release の冪等性と、storedCapturer との独立) を検証する。
/// カメラが必要な検証 (別接続の capturer 混線など) は実機で確認する。
///
/// actor は await 中に再入できるため、lease 自身の破棄状態による再確認と、
/// release が進行中操作の cleanup 完了を待つ barrier が必要になる。
/// 本テストではカメラに依存しない tracker を含めて、その順序を検証する
/// (setMute 全体の挙動は実機で確認する)。
final class VideoHardMuteActorLeaseTests: XCTestCase {
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

  // テスト用の MediaChannel / lease / SenderStreamBox / CameraSettingsSnapshot を構築する
  private func makeDependencies() throws -> (
    mediaChannel: MediaChannel,
    senderStreamBox: SenderStreamBox,
    cameraSettings: CameraSettingsSnapshot
  ) {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    let nativeStream = peerChannel.nativePeerChannelFactory.createNativeStream(streamId: "test")
    let mediaStream = BasicMediaStream(peerChannel: peerChannel, nativeStream: nativeStream)
    return (
      mediaChannel,
      SenderStreamBox(stream: mediaStream),
      CameraSettingsSnapshot(mediaChannel.configuration.cameraSettings)
    )
  }

  /// release は冪等であり、複数回呼んでも安全であることを確認する
  ///
  /// mock / stub は使用しない。release() は「storedCapturer の破棄」と
  /// 「lease の破棄予約」のみで、複数回呼んでも状態を壊さない。
  func testReleaseIsIdempotent() async {
    let actor = VideoHardMuteActor()
    let lease = VideoHardMuteLease()

    // 2 回呼んでもクラッシュせず、安全に完了する
    await actor.release(lease: lease)
    await actor.release(lease: lease)
  }

  /// 未知の lease (release されていない lease) の setMute は revocation で失敗しないことを確認する
  ///
  /// lease ごとに破棄予約が独立しており、
  /// 別 lease の release がこの lease に影響しないことを検証する。
  func testReleaseOfOtherLeaseDoesNotAffectTarget() async throws {
    let actor = VideoHardMuteActor()
    let dependencies = try makeDependencies()

    // UUID が異なる 2 つの lease を作る
    let leaseA = VideoHardMuteLease()
    let leaseB = VideoHardMuteLease()

    // leaseA を release しても leaseB は影響を受けない (カメラ未起動なら冪等 return)
    await actor.release(lease: leaseA)

    do {
      try await actor.setMute(
        mute: true,
        lease: leaseB,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      // カメラ未起動のため、冪等として成功 (revocation ではない)
    } catch {
      XCTFail("別 lease の setMute が revocation で失敗することはない: \(error)")
    }
  }

  /// release より後に遅延到着した同じ lease の操作を拒否することを確認する
  func testReleasedLeaseRejectsDelayedOperation() async throws {
    let actor = VideoHardMuteActor()
    let dependencies = try makeDependencies()
    let lease = VideoHardMuteLease()

    await actor.release(lease: lease)

    do {
      try await actor.setMute(
        mute: true,
        lease: lease,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      XCTFail("破棄予約後の lease では操作を開始できないこと")
    } catch let error as SoraError {
      guard case .mediaChannelError(let reason) = error else {
        XCTFail("mediaChannelError が返ること: \(error)")
        return
      }
      XCTAssertTrue(reason.contains("cancelled"))
    }
  }

  /// release が同じ lease の進行中操作を完了バリアとして待つことを確認する
  func testReleaseWaitsForActiveOperationCompletion() async throws {
    let tracker = VideoHardMuteOperationTracker()
    let actor = VideoHardMuteActor(operationTracker: tracker)
    let lease = VideoHardMuteLease()
    try tracker.begin(lease: lease)

    let releaseTask = Task {
      await actor.release(lease: lease)
    }

    // production の actor.release が tracker の完了待ちへ入る同期点を待つ。
    await tracker.waitUntilReleaseIsPending()
    XCTAssertTrue(lease.isRevoked, "進行中操作の完了前に lease を破棄すること")
    XCTAssertEqual(
      tracker.pendingReleaseCount,
      1,
      "進行中操作がある間は release が完了待ちになること")

    tracker.finish(lease: lease)
    await releaseTask.value
    XCTAssertEqual(
      tracker.pendingReleaseCount,
      0,
      "操作完了後に release の待機を解除すること")
  }

  /// 通常カメラ cleanup が別接続の sender stream を停止対象にしないことを確認する
  func testCameraCleanupRejectsAnotherConnectionStream() throws {
    let first = try makeDependencies()
    let second = try makeDependencies()

    XCTAssertTrue(
      CameraVideoCaptureCoordinator.isOwned(
        currentStream: first.senderStreamBox.stream,
        by: first.senderStreamBox.stream),
      "同じ接続の sender stream は停止対象になること")
    XCTAssertFalse(
      CameraVideoCaptureCoordinator.isOwned(
        currentStream: second.senderStreamBox.stream,
        by: first.senderStreamBox.stream),
      "別接続の sender stream は停止対象にならないこと")
  }

  /// redirect で streams が空になっても通常カメラの所有ストリームを保持できることを確認する
  func testCameraCaptureOwnershipRetainsOnlyCurrentOwner() throws {
    let first = try makeDependencies()
    let second = try makeDependencies()
    let ownership = CameraCaptureOwnership()

    ownership.set(senderStream: first.senderStreamBox.stream)
    XCTAssertTrue(
      ownership.currentSenderStream() === first.senderStreamBox.stream,
      "設定した sender stream を独立して保持すること")

    ownership.clear(ifOwnedBy: second.senderStreamBox.stream)
    XCTAssertTrue(
      ownership.currentSenderStream() === first.senderStreamBox.stream,
      "別接続からの解除では所有情報を失わないこと")

    ownership.clear(ifOwnedBy: first.senderStreamBox.stream)
    XCTAssertNil(ownership.currentSenderStream(), "所有接続からの解除で空になること")
  }

  /// カメラ cleanup 失敗後は隔離し、停止成功を確認するまで新しい操作を許可しないことを確認する
  func testCameraCoordinatorQuarantinesCleanupFailure() {
    let coordinator = CameraVideoCaptureCoordinator()

    XCTAssertTrue(coordinator.isAvailable)
    coordinator.quarantine()
    XCTAssertTrue(coordinator.isQuarantined)
    XCTAssertFalse(coordinator.isAvailable, "cleanup 失敗後は新しいカメラ操作を拒否すること")

    coordinator.clearQuarantineAfterSuccessfulStop()
    XCTAssertFalse(coordinator.isQuarantined)
    XCTAssertTrue(coordinator.isAvailable, "停止成功を確認した後はカメラ操作を再開できること")
  }

  /// 同じ接続のカメラと画面共有を、非同期開始より前の予約で排他できることを確認する
  func testVideoSourceCoordinatorReservesOnlyOneSource() {
    let coordinator = VideoSourceCoordinator()

    XCTAssertEqual(coordinator.reserveCamera(), .acquired, "最初のカメラ予約を取得できること")
    XCTAssertEqual(
      coordinator.reserveCamera(),
      .alreadyReserved,
      "同じ送信元の重複予約を識別できること")
    XCTAssertEqual(
      coordinator.reserveScreen(),
      .unavailable,
      "カメラ予約中は画面共有を予約できないこと")

    coordinator.releaseCamera()
    XCTAssertEqual(
      coordinator.reserveScreen(),
      .acquired,
      "カメラ予約の解放後は画面共有を予約できること")
    XCTAssertEqual(
      coordinator.reserveCamera(),
      .unavailable,
      "画面共有予約中はカメラを予約できないこと")
  }

  /// 切断で破棄した映像送信元には、遅延した開始要求や新しい予約を許可しないことを確認する
  func testVideoSourceCoordinatorRejectsReservationAfterRevoke() {
    let coordinator = VideoSourceCoordinator()

    XCTAssertEqual(coordinator.reserveCamera(), .acquired)
    XCTAssertTrue(coordinator.isReservedForCamera())

    coordinator.revoke()
    XCTAssertFalse(coordinator.isReservedForCamera(), "切断後は既存のカメラ予約を無効化すること")

    coordinator.releaseCamera()
    XCTAssertEqual(
      coordinator.reserveCamera(),
      .unavailable,
      "解放後も切断済み coordinator を再利用できないこと")
    XCTAssertEqual(
      coordinator.reserveScreen(),
      .unavailable,
      "切断後は画面共有も予約できないこと")
  }

  /// 通常カメラの停止キューが完了するまで MediaChannel の切断 callback を通知しないことを確認する
  func testMediaChannelDisconnectWaitsForCameraCleanup() async throws {
    let coordinator = CameraVideoCaptureCoordinator()
    let ownership = CameraCaptureOwnership()
    let gate = CameraCaptureTestGate()
    coordinator.enqueue {
      await gate.wait()
    }
    await gate.waitUntilBlocked()

    let mediaChannel = try MediaChannel(
      configuration: makeConfiguration(),
      cameraCaptureCoordinator: coordinator,
      cameraCaptureOwnership: ownership)
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeStream(streamId: "camera-cleanup-test")
    let senderStream = BasicMediaStream(
      peerChannel: mediaChannel.peerChannel,
      nativeStream: nativeStream)
    ownership.set(senderStream: senderStream)

    let disconnectExpectation = expectation(description: "通常カメラ停止後に切断 callback が届くこと")
    var disconnectCallbackCount = 0
    mediaChannel.handlers.onDisconnect = { _ in
      disconnectCallbackCount += 1
      disconnectExpectation.fulfill()
    }
    _ = mediaChannel.connect(webRTCConfiguration: WebRTCConfiguration()) { _ in }
    mediaChannel.disconnect(error: nil)

    XCTAssertEqual(disconnectCallbackCount, 0, "停止キューの完了前に切断 callback を通知しないこと")
    XCTAssertTrue(
      ownership.currentSenderStream() === senderStream,
      "停止キューの完了前は所有情報を保持すること")

    await gate.open()
    await fulfillment(of: [disconnectExpectation], timeout: 3)
    XCTAssertEqual(disconnectCallbackCount, 1, "停止キューの完了後に切断 callback を 1 回だけ通知すること")
    XCTAssertNil(ownership.currentSenderStream(), "停止処理の完了後に所有情報を解除すること")
  }

  /// MediaChannel の最終参照解放でも映像ハードミュートの lease を破棄することを確認する
  func testMediaChannelDeinitReleasesLease() async throws {
    let lease = VideoHardMuteLease()
    var mediaChannel: MediaChannel? = try MediaChannel(
      configuration: makeConfiguration(),
      videoHardMuteLease: lease)
    XCTAssertNotNil(mediaChannel, "解放前は MediaChannel が保持されていること")

    let isReleasedBeforeDeinit = await MediaChannel.videoHardMuteActor.isReleased(lease: lease)
    XCTAssertFalse(isReleasedBeforeDeinit)
    mediaChannel = nil

    // deinit が生成した cleanup Task に実行機会を与え、actor に破棄予約が届くまで待つ。
    var isReleased = false
    for _ in 0..<1_000 {
      isReleased = await MediaChannel.videoHardMuteActor.isReleased(lease: lease)
      if isReleased {
        break
      }
      await Task.yield()
    }

    XCTAssertTrue(isReleased, "MediaChannel の deinit で lease が破棄されること")
  }
}
