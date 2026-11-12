// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

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

/// VideoHardMuteActor の lease / revocation 管理と映像送信元の予約に関するユニットテスト
///
/// VideoHardMuteActor.setMute は実カメラ操作を含むため、カメラが利用できない
/// Simulator では mute / unmute の全体 (store / restart / stream 照合) を検証できない。
/// 本テストでは、カメラ操作に到達する前の lease / revocation のロジック
/// (release の冪等性と、storedCapturer との独立) を検証する。
/// `operationTracker.begin` が拒否する経路では `senderStream.videoEnabled` が
/// 変更されないことも検証する。
/// カメラが必要な検証 (別接続の capturer 混線や復元処理など) は実機で確認する。
///
/// 併せて、`VideoSourceCoordinator` の映像送信元の予約 (カメラと画面共有の排他) と
/// 失敗理由、`MediaChannel.startScreenCapture` が返すエラーを検証する。
///
/// actor は await 中に再入できるため、lease 自身の破棄状態による再確認と、
/// release が進行中操作の cleanup 完了を待つ barrier が必要になる。
/// 本テストではカメラに依存しない tracker を含めて、その順序を検証する
/// (setMute 全体の挙動は実機で確認する)。
final class VideoHardMuteActorLeaseTests: XCTestCase {
  /// カメラ競合のほか、画面共有の操作中・予約 revoke 済みでも返る後方互換メッセージです。
  private let cameraConflictMessage =
    "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
  /// 画面キャプチャの後始末に失敗したときに返るエラーメッセージです。
  private let screenCleanupFailedMessage =
    "screen capture cleanup failed, call stopScreenCapture before startScreenCapture"

  // テスト用の MediaChannel / lease / SenderStreamBox / CameraSettingsSnapshot を構築する
  //
  // videoTrackId を指定すると video track 付きの sender stream を作る。
  // videoEnabled を検証するテストでは video track が必要になる (video track が無いと
  // videoEnabled が常に false になり「変更されない」検証が空虚になる)。
  // mediaStream は operation の世代をテストから取得するために返す。
  private func makeDependencies(videoTrackId: String? = nil) throws -> (
    mediaChannel: MediaChannel,
    senderStreamBox: SenderStreamBox,
    mediaStream: BasicMediaStream,
    cameraSettings: CameraSettingsSnapshot
  ) {
    let mediaChannel = try MediaChannel(configuration: makeTestConfiguration())
    let peerChannel = mediaChannel.peerChannel
    let nativeStream =
      if let videoTrackId {
        peerChannel.nativePeerChannelFactory.createNativeSenderStream(
          streamId: "test",
          videoTrackId: videoTrackId,
          audioTrackId: nil,
          constraints: MediaConstraints())
      } else {
        peerChannel.nativePeerChannelFactory.createNativeStream(streamId: "test")
      }
    let mediaStream = BasicMediaStream(peerChannel: peerChannel, nativeStream: nativeStream)
    return (
      mediaChannel,
      SenderStreamBox(stream: mediaStream),
      mediaStream,
      CameraSettingsSnapshot(mediaChannel.configuration.cameraSettings)
    )
  }

  // SoraError.mediaChannelError の reason を部分一致で検証する
  //
  // 案内文の契約を固定するため、実装のメッセージを変更するときはここも更新する必要がある。
  private func assertMediaChannelError(
    _ error: Error,
    contains expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let reason = mediaChannelErrorReason(error, file: file, line: line) else {
      return
    }
    XCTAssertTrue(
      reason.contains(expected),
      "reason に \(expected) が含まれること: \(reason)",
      file: file,
      line: line)
  }

  /// 画面共有の開始予約の失敗を検証するため、接続状態と送信ストリームを持つ MediaChannel を構築する
  ///
  /// 実接続は行わず、`#if DEBUG` の `setConnectionStateForTesting(_:)` で接続状態だけを作る。
  /// 呼び出し側は後始末で `.disconnected` に戻してから MediaChannel を解放する。
  private func makeConnectedMediaChannel(
    videoSourceCoordinator: VideoSourceCoordinator
  ) throws -> MediaChannel {
    var configuration = makeTestConfiguration()
    configuration.publisherStreamId = testSenderStreamId
    let mediaChannel = try MediaChannel(
      configuration: configuration,
      videoSourceCoordinator: videoSourceCoordinator)
    mediaChannel.peerChannel.add(
      stream: makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel))
    mediaChannel.setConnectionStateForTesting(.connected)
    return mediaChannel
  }

  /// `MediaChannel.startScreenCapture` が `expected` と完全一致するメッセージで失敗することを検証する
  ///
  /// 案内文は利用者との契約であるため、部分一致ではなく完全一致で固定する。
  private func assertStartScreenCaptureFailure(
    _ mediaChannel: MediaChannel,
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await mediaChannel.startScreenCapture()
      XCTFail("画面共有を開始できないこと", file: file, line: line)
    } catch {
      guard let reason = mediaChannelErrorReason(error, file: file, line: line) else {
        return
      }
      XCTAssertEqual(
        reason,
        expected,
        "reason が一致すること: \(reason)",
        file: file,
        line: line)
    }
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

    let generation = dependencies.mediaStream.beginVideoOperation()
    do {
      try await actor.setMute(
        mute: true,
        generation: generation,
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

    let generation = dependencies.mediaStream.beginVideoOperation()
    do {
      try await actor.setMute(
        mute: true,
        generation: generation,
        lease: lease,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      XCTFail("破棄予約後の lease では操作を開始できないこと")
    } catch {
      assertMediaChannelError(error, contains: "cancelled")
    }
  }

  /// 実行中の操作がある間は、拒否された setMute が videoEnabled を変更しないことを確認する
  ///
  /// 別の lease で operationTracker.begin を先に呼び、進行中の操作がある状態を模擬する。
  /// 2 つ目の呼び出しは operationTracker.begin で "in progress" になり、videoEnabled の
  /// 設定より前に拒否されるため、拒否された呼び出しが値を変更しない。
  /// videoEnabled の設定を operationTracker.begin より前に戻すと、このテストは失敗する。
  func testInProgressRejectionDoesNotChangeVideoEnabled() async throws {
    let tracker = VideoHardMuteOperationTracker()
    let actor = VideoHardMuteActor(operationTracker: tracker)
    let dependencies = try makeDependencies(videoTrackId: "video")
    let occupyingLease = VideoHardMuteLease()
    let lease = VideoHardMuteLease()

    XCTAssertTrue(
      dependencies.senderStreamBox.stream.videoEnabled,
      "前提: video track は既定で有効であること")

    // 進行中の操作を模擬して activeLease を占有する
    try tracker.begin(lease: occupyingLease)
    // 検証が途中で終わっても占有を解放する
    defer { tracker.finish(lease: occupyingLease) }

    do {
      try await actor.setMute(
        mute: true,
        generation: dependencies.mediaStream.beginVideoOperation(),
        lease: lease,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      XCTFail("実行中の操作がある間は拒否されること")
    } catch {
      assertMediaChannelError(error, contains: "in progress")
    }

    XCTAssertTrue(
      dependencies.senderStreamBox.stream.videoEnabled,
      "拒否された呼び出しが videoEnabled を変更しないこと")
  }

  /// 取消済み lease の setMute が videoEnabled を変更しないことを確認する
  ///
  /// videoEnabled の設定を operationTracker.begin より前に戻すと、このテストは失敗する。
  func testCancelledRejectionDoesNotChangeVideoEnabled() async throws {
    let actor = VideoHardMuteActor()
    let dependencies = try makeDependencies(videoTrackId: "video")
    let lease = VideoHardMuteLease()

    XCTAssertTrue(
      dependencies.senderStreamBox.stream.videoEnabled,
      "前提: video track は既定で有効であること")

    lease.revoke()

    do {
      try await actor.setMute(
        mute: true,
        generation: dependencies.mediaStream.beginVideoOperation(),
        lease: lease,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      XCTFail("破棄予約後の lease では操作を開始できないこと")
    } catch {
      assertMediaChannelError(error, contains: "cancelled")
    }

    XCTAssertTrue(
      dependencies.senderStreamBox.stream.videoEnabled,
      "取消済み lease の拒否が videoEnabled を変更しないこと")
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

  /// 開始取消後も、物理停止の成功を確認するまでは切断処理が所有ストリームを参照できることを確認する
  func testCancelledCameraStartRetainsOwnershipUntilStopped() async throws {
    let dependencies = try makeDependencies()
    // process-wide の shared を汚染しないよう、テストローカルの owner を注入する
    let cameraCoordinator = CameraVideoCaptureCoordinator(owner: CameraStateOwner())

    // lease 破棄と送信元予約破棄の両経路で、開始成功後の停止対象を失わないことを確認する。
    for revokeLease in [true, false] {
      let lease = VideoHardMuteLease()
      let videoSourceCoordinator = VideoSourceCoordinator()
      let ownership = CameraCaptureOwnership()
      let senderStream = dependencies.senderStreamBox
      let reservation = try XCTUnwrap(
        videoSourceCoordinator.beginCamera(stream: senderStream.stream))
      let authorization = CameraStartAuthorization(
        reservation: reservation,
        videoSourceCoordinator: videoSourceCoordinator,
        cameraCaptureOwnership: ownership)
      if revokeLease {
        lease.revoke()
      } else {
        videoSourceCoordinator.revoke()
      }

      let completed = await cameraCoordinator.perform {
        authorization.completeStartedCamera(lease: lease, senderStream: senderStream.stream)
      }
      XCTAssertFalse(completed, "取消後に開始予約を確定しないこと")
      XCTAssertTrue(
        ownership.currentSenderStream() === senderStream.stream,
        "開始済みカメラの停止が未完了なら、切断処理へ所有情報を引き継ぐこと")

      videoSourceCoordinator.cancelCamera(reservation)
      ownership.clear(ifOwnedBy: senderStream.stream)
      XCTAssertNil(ownership.currentSenderStream(), "停止確認後は所有情報を解除できること")
    }
  }

  /// カメラ cleanup 失敗後は隔離し、停止成功を確認するまで新しい操作を許可しないことを確認する
  func testCameraCoordinatorQuarantinesCleanupFailure() {
    // 隔離状態は process-wide の owner が保持するため、テストローカルの owner を注入して
    // 他のテストへ状態を持ち越さないようにする。
    let owner = CameraStateOwner()
    let coordinator = CameraVideoCaptureCoordinator(owner: owner)

    XCTAssertTrue(coordinator.isAvailable)
    coordinator.quarantine()
    XCTAssertTrue(coordinator.isQuarantined)
    XCTAssertEqual(owner.snapshot.phase, .quarantined, "隔離状態が owner に記録されること")
    XCTAssertFalse(coordinator.isAvailable, "cleanup 失敗後は新しいカメラ操作を拒否すること")

    coordinator.clearQuarantineAfterSuccessfulStop()
    XCTAssertFalse(coordinator.isQuarantined)
    XCTAssertEqual(owner.snapshot.phase, .idle, "解除が owner に記録されること")
    XCTAssertTrue(coordinator.isAvailable, "停止成功を確認した後はカメラ操作を再開できること")
  }

  /// 隔離した capturer と異なる capturer の停止完了では隔離を解除しないことを確認する
  func testCameraCoordinatorKeepsQuarantineForOtherCapturer() {
    let owner = CameraStateOwner()
    let coordinator = CameraVideoCaptureCoordinator(owner: owner)
    let quarantined = CameraCapturerID()

    coordinator.quarantine(capturerID: quarantined)
    XCTAssertEqual(owner.snapshot.phase, .quarantined, "隔離状態が owner に記録されること")

    coordinator.clearQuarantineAfterSuccessfulStop(capturerID: CameraCapturerID())

    XCTAssertTrue(coordinator.isQuarantined, "別 capturer の停止完了では隔離を解除しないこと")
    XCTAssertEqual(owner.snapshot.phase, .quarantined, "owner の隔離も維持されること")
  }

  /// 隔離した capturer と一致する ID の停止完了で隔離が解除されることを確認する
  func testCameraCoordinatorClearsQuarantineForMatchingCapturer() {
    let owner = CameraStateOwner()
    let coordinator = CameraVideoCaptureCoordinator(owner: owner)
    let capturerID = CameraCapturerID()

    coordinator.quarantine(capturerID: capturerID)
    XCTAssertEqual(owner.snapshot.phase, .quarantined, "隔離状態が owner に記録されること")

    coordinator.clearQuarantineAfterSuccessfulStop(capturerID: capturerID)

    XCTAssertFalse(coordinator.isQuarantined, "一致する capturer の停止完了で隔離を解除すること")
    XCTAssertEqual(owner.snapshot.phase, .idle, "owner の隔離も解除されること")
  }

  /// 隔離中はカメラ操作が拒否されることを coordinator 経由で確認する
  ///
  /// `cameraOperationRejectionError` は引数の coordinator が保持する owner を参照するため、
  /// テストローカルの owner でも操作拒否の判定を検証できる。
  func testCameraOperationRejectionErrorFollowsInjectedOwner() {
    let owner = CameraStateOwner()
    let coordinator = CameraVideoCaptureCoordinator(owner: owner)

    XCTAssertNil(
      CameraVideoCapturer.cameraOperationRejectionError(coordinator: coordinator, stream: nil),
      "隔離していない場合は拒否しないこと")

    coordinator.quarantine()

    let error = CameraVideoCapturer.cameraOperationRejectionError(
      coordinator: coordinator, stream: nil)
    guard let soraError = error as? SoraError, case .cameraError(let reason) = soraError else {
      XCTFail("cameraError が返ること: \(String(describing: error))")
      return
    }
    XCTAssertEqual(reason, "camera capture is quarantined after a cleanup failure")

    coordinator.clearQuarantineAfterSuccessfulStop()
    XCTAssertNil(
      CameraVideoCapturer.cameraOperationRejectionError(coordinator: coordinator, stream: nil),
      "隔離解除後は拒否しないこと")
  }

  /// 画面共有の予約中はカメラ操作が拒否され、隔離がある場合は隔離が優先されることを確認する
  func testCameraOperationRejectionErrorForScreenReservation() throws {
    let dependencies = try makeDependencies()
    let coordinator = CameraVideoCaptureCoordinator(owner: CameraStateOwner())
    let sourceCoordinator = VideoSourceCoordinator()
    let stream = dependencies.senderStreamBox.stream
    guard case .success(let reservation) = sourceCoordinator.beginScreen(stream: stream) else {
      XCTFail("画面共有を予約できること")
      return
    }
    XCTAssertTrue(sourceCoordinator.completeScreenStart(reservation))
    // 画面共有の予約はプロセス全体の registry が保持するため、テスト内で解放する
    defer {
      if let stopReservation = sourceCoordinator.beginScreenStop() {
        sourceCoordinator.finishScreenStop(stopReservation, stopped: true)
      }
    }

    let screenError = CameraVideoCapturer.cameraOperationRejectionError(
      coordinator: coordinator, stream: stream)
    guard let screenSoraError = screenError as? SoraError,
      case .cameraError(let screenReason) = screenSoraError
    else {
      XCTFail("cameraError が返ること: \(String(describing: screenError))")
      return
    }
    XCTAssertEqual(screenReason, "screen capture is active on the camera stream")

    // 隔離中は画面共有の予約を確認せず、隔離の理由で拒否する
    coordinator.quarantine()

    let quarantinedError = CameraVideoCapturer.cameraOperationRejectionError(
      coordinator: coordinator, stream: stream)
    guard let quarantinedSoraError = quarantinedError as? SoraError,
      case .cameraError(let quarantinedReason) = quarantinedSoraError
    else {
      XCTFail("cameraError が返ること: \(String(describing: quarantinedError))")
      return
    }
    XCTAssertEqual(quarantinedReason, "camera capture is quarantined after a cleanup failure")
  }

  /// 同じ接続のカメラと画面共有を、非同期開始より前の予約で排他できることを確認する
  func testVideoSourceCoordinatorReservesOnlyOneSource() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()

    guard
      let cameraReservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("最初のカメラ予約を取得できること")
      return
    }
    XCTAssertNil(
      coordinator.beginCamera(stream: dependencies.senderStreamBox.stream),
      "開始処理中のカメラを重複予約できないこと")
    XCTAssertEqual(
      coordinator.beginScreen(stream: dependencies.senderStreamBox.stream),
      .failure(.cameraInUse),
      "カメラ予約中は画面共有を予約できないこと")
    XCTAssertTrue(coordinator.completeCamera(cameraReservation, active: true))

    coordinator.releaseCamera()
    guard
      case .success(let screenReservation) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("カメラ予約の解放後は画面共有を予約できること")
      return
    }
    XCTAssertTrue(coordinator.completeScreenStart(screenReservation))
    XCTAssertNil(
      coordinator.beginCamera(stream: dependencies.senderStreamBox.stream),
      "画面共有予約中はカメラを予約できないこと")
    guard let stopReservation = coordinator.beginScreenStop() else {
      XCTFail("画面共有の停止予約を取得できること")
      return
    }
    coordinator.finishScreenStop(stopReservation, stopped: true)
  }

  /// 切断で破棄した映像送信元には、遅延した開始要求や新しい予約を許可しないことを確認する
  func testVideoSourceCoordinatorRejectsReservationAfterRevoke() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()

    guard let reservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("カメラ予約を取得できること")
      return
    }
    XCTAssertTrue(coordinator.isValid(reservation))

    coordinator.revoke()
    XCTAssertFalse(coordinator.isValid(reservation), "切断後は既存のカメラ予約を無効化すること")

    coordinator.releaseCamera()
    XCTAssertNil(
      coordinator.beginCamera(stream: dependencies.senderStreamBox.stream),
      "解放後も切断済み coordinator を再利用できないこと")
    XCTAssertEqual(
      coordinator.beginScreen(stream: dependencies.senderStreamBox.stream),
      .failure(.cancelled),
      "切断後は画面共有も予約できないこと")
  }

  /// 画面共有の開始待ち中に停止すると、古い開始予約を完了できないことを確認する
  func testVideoSourceCoordinatorCancelsDelayedScreenStart() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      case .success(let reservation) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("画面共有予約を取得できること")
      return
    }

    guard let stopReservation = coordinator.beginScreenStop() else {
      XCTFail("画面共有の停止予約を取得できること")
      return
    }
    XCTAssertFalse(coordinator.isValid(reservation), "停止開始時に古い世代を無効化すること")
    XCTAssertFalse(
      coordinator.completeScreenStart(reservation),
      "停止後に遅れて完了した開始を確定しないこと")

    coordinator.finishScreenStop(stopReservation, stopped: true)
    XCTAssertNotNil(
      coordinator.beginCamera(stream: dependencies.senderStreamBox.stream),
      "画面共有停止後はカメラを予約できること")
  }

  /// カメラの接続間引き継ぎ後に、以前の所有接続へ予約を残さないことを確認する
  func testVideoSourceCoordinatorClearsPreviousCameraOwnerAfterHandoff() throws {
    let first = try makeDependencies()
    let second = try makeDependencies()
    let firstCoordinator = VideoSourceCoordinator()
    let secondCoordinator = VideoSourceCoordinator()

    guard let firstReservation = firstCoordinator.beginCamera(stream: first.senderStreamBox.stream)
    else {
      XCTFail("最初の接続がカメラを予約できること")
      return
    }
    XCTAssertTrue(firstCoordinator.completeCamera(firstReservation, active: true))

    guard
      let secondReservation = secondCoordinator.beginCamera(stream: second.senderStreamBox.stream)
    else {
      XCTFail("引き継ぎ先の接続がカメラ開始を予約できること")
      return
    }
    VideoSourceCoordinator.releaseCameraReservations(
      for: first.senderStreamBox.stream,
      excluding: secondReservation)

    XCTAssertFalse(firstCoordinator.isValid(firstReservation))
    XCTAssertTrue(secondCoordinator.isValid(secondReservation))
    guard
      case .success = firstCoordinator.beginScreen(stream: first.senderStreamBox.stream)
    else {
      XCTFail("物理カメラを失った接続は画面共有へ切り替えられること")
      return
    }
  }

  /// 先行カメラ停止の完了が、その後に予約されたカメラ開始世代を破棄しないことを確認する
  func testVideoSourceCoordinatorKeepsCameraStartReservedAfterPriorStop() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      let activeReservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("動作中カメラの予約を取得できること")
      return
    }
    XCTAssertTrue(coordinator.completeCamera(activeReservation, active: true))
    guard
      let startingReservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("先行停止中に後続開始を予約できること")
      return
    }

    VideoSourceCoordinator.releaseCameraReservations(for: dependencies.senderStreamBox.stream)

    XCTAssertTrue(
      coordinator.isValid(startingReservation),
      "先行停止は後続の cameraStarting 世代を解除しないこと")
  }

  /// カメラ予約の取消は一致する世代だけを解除し、後続の開始予約へ作用しないことを確認する
  func testVideoSourceCoordinatorCancelsOnlyMatchingCameraGeneration() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      let firstReservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("最初のカメラ予約を取得できること")
      return
    }
    XCTAssertTrue(coordinator.completeCamera(firstReservation, active: true))

    coordinator.cancelCamera(firstReservation)
    XCTAssertFalse(coordinator.isValid(firstReservation), "一致する動作中カメラ予約を解除すること")
    guard
      let secondReservation = coordinator.beginCamera(stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("取消後に次のカメラ予約を取得できること")
      return
    }

    coordinator.cancelCamera(firstReservation)
    XCTAssertTrue(coordinator.isValid(secondReservation), "古い取消で後続予約を解除しないこと")
    coordinator.cancelCamera(secondReservation)
  }

  /// 画面共有予約を公開カメラ API からも同じ送信ストリームで検出できることを確認する
  func testVideoSourceCoordinatorPublishesScreenReservationByStream() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      case .success(let reservation) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("画面共有予約を取得できること")
      return
    }

    XCTAssertTrue(
      VideoSourceCoordinator.hasScreenReservation(for: dependencies.senderStreamBox.stream))
    guard let stopReservation = coordinator.beginScreenStop() else {
      XCTFail("画面共有の停止予約を取得できること")
      return
    }
    coordinator.finishScreenStop(stopReservation, stopped: true)
    XCTAssertFalse(
      VideoSourceCoordinator.hasScreenReservation(for: dependencies.senderStreamBox.stream))
    XCTAssertFalse(coordinator.isValid(reservation))
  }

  /// 古い重複停止の完了が、停止後に取得した新しい開始予約を破棄しないことを確認する
  func testVideoSourceCoordinatorIgnoresStaleDuplicateStopCompletion() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      case .success(let firstStart) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("最初の画面共有予約を取得できること")
      return
    }
    XCTAssertTrue(coordinator.completeScreenStart(firstStart))
    guard let firstStop = coordinator.beginScreenStop(),
      let duplicateStop = coordinator.beginScreenStop()
    else {
      XCTFail("重複停止が同じ停止世代を取得できること")
      return
    }
    XCTAssertEqual(firstStop, duplicateStop)

    coordinator.finishScreenStop(firstStop, stopped: true)
    guard
      case .success(let secondStart) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("停止後に次の画面共有予約を取得できること")
      return
    }

    coordinator.finishScreenStop(duplicateStop, stopped: true)
    XCTAssertTrue(
      coordinator.isValid(secondStart),
      "古い停止完了で新しい開始世代を破棄しないこと")
  }

  /// 古い開始の cleanup が、停止後に取得した新しい開始予約へ作用しないことを確認する
  func testVideoSourceCoordinatorRejectsCleanupFromStaleStart() throws {
    let dependencies = try makeDependencies()
    let coordinator = VideoSourceCoordinator()
    guard
      case .success(let firstStart) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream),
      let firstStop = coordinator.beginScreenStop()
    else {
      XCTFail("最初の開始と停止を予約できること")
      return
    }
    coordinator.finishScreenStop(firstStop, stopped: true)
    guard
      case .success(let secondStart) = coordinator.beginScreen(
        stream: dependencies.senderStreamBox.stream)
    else {
      XCTFail("次の画面共有予約を取得できること")
      return
    }

    XCTAssertNil(
      coordinator.beginScreenStop(for: firstStart),
      "古い開始世代から新しい開始を停止できないこと")
    XCTAssertTrue(coordinator.isValid(secondStart))
  }

  /// 画面共有の開始予約が失敗理由を区別して返すことを確認する
  ///
  /// 同じ接続のカメラ・別接続のカメラ予約・画面共有の開始中 / 実行中 / 停止中・後始末待ちを
  /// 順に作り、`beginScreen` がそれぞれの理由を返すことと、後始末待ちから停止の再試行で
  /// 回復できることを検証する。`.cancelled` は
  /// `testVideoSourceCoordinatorRejectsReservationAfterRevoke` で検証する。
  func testVideoSourceCoordinatorReportsScreenStartFailureReasons() throws {
    let dependencies = try makeDependencies()
    let stream = dependencies.senderStreamBox.stream
    let cameraCoordinator = VideoSourceCoordinator()
    let screenCoordinator = VideoSourceCoordinator()

    guard let cameraReservation = cameraCoordinator.beginCamera(stream: stream) else {
      XCTFail("カメラ予約を取得できること")
      return
    }
    XCTAssertEqual(
      cameraCoordinator.beginScreen(stream: stream),
      .failure(.cameraInUse),
      "同じ接続のカメラ予約中は cameraInUse を返すこと")
    XCTAssertEqual(
      screenCoordinator.beginScreen(stream: stream),
      .failure(.cameraInUse),
      "別の接続のカメラ予約中は cameraInUse を返すこと")

    XCTAssertTrue(cameraCoordinator.completeCamera(cameraReservation, active: true))
    XCTAssertEqual(
      cameraCoordinator.beginScreen(stream: stream),
      .failure(.cameraInUse),
      "動作中のカメラがある場合も cameraInUse を返すこと")
    cameraCoordinator.releaseCamera()

    guard case .success(let started) = screenCoordinator.beginScreen(stream: stream) else {
      XCTFail("画面共有予約を取得できること")
      return
    }
    XCTAssertEqual(
      screenCoordinator.beginScreen(stream: stream),
      .failure(.screenOperationInProgress),
      "画面共有の開始中は screenOperationInProgress を返すこと")

    XCTAssertTrue(screenCoordinator.completeScreenStart(started))
    XCTAssertEqual(
      screenCoordinator.beginScreen(stream: stream),
      .failure(.screenOperationInProgress),
      "画面共有の実行中は screenOperationInProgress を返すこと")

    guard let stopReservation = screenCoordinator.beginScreenStop() else {
      XCTFail("画面共有の停止を予約できること")
      return
    }
    XCTAssertEqual(
      screenCoordinator.beginScreen(stream: stream),
      .failure(.screenOperationInProgress),
      "画面共有の停止中は screenOperationInProgress を返すこと")

    screenCoordinator.finishScreenStop(stopReservation, stopped: false)
    XCTAssertEqual(
      screenCoordinator.beginScreen(stream: stream),
      .failure(.screenCleanupPending),
      "停止に失敗した後始末待ちの状態では screenCleanupPending を返すこと")

    guard let retryReservation = screenCoordinator.beginScreenStop() else {
      XCTFail("後始末待ちから停止を再試行できること")
      return
    }
    screenCoordinator.finishScreenStop(retryReservation, stopped: true)
    guard case .success = screenCoordinator.beginScreen(stream: stream) else {
      XCTFail("停止に成功した後は画面共有を予約できること")
      return
    }
  }

  /// 後始末待ちの状態で画面共有を開始すると、停止の再試行を案内するエラーになることを確認する
  ///
  /// `VideoSourceCoordinator` の後始末待ち状態だけを人工的に作り、`ScreenCaptureController` は
  /// `.stopped` のまま、ReplayKit 側の後始末失敗は再現しない。
  func testMediaChannelStartScreenCaptureReportsScreenCleanupPendingError() async throws {
    let videoSourceCoordinator = VideoSourceCoordinator()
    let mediaChannel = try makeConnectedMediaChannel(
      videoSourceCoordinator: videoSourceCoordinator)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    let senderStream = try XCTUnwrap(mediaChannel.senderStream, "送信ストリームを取得できること")
    guard
      case .success(let reservation) = videoSourceCoordinator.beginScreen(
        stream: senderStream)
    else {
      XCTFail("画面共有予約を取得できること")
      return
    }
    XCTAssertTrue(videoSourceCoordinator.completeScreenStart(reservation))
    guard let stopReservation = videoSourceCoordinator.beginScreenStop() else {
      XCTFail("画面共有の停止を予約できること")
      return
    }
    // 停止に失敗した後始末待ちの状態にする。
    videoSourceCoordinator.finishScreenStop(stopReservation, stopped: false)

    await assertStartScreenCaptureFailure(
      mediaChannel, equals: screenCleanupFailedMessage)
  }

  /// 案内された stopScreenCapture() の再試行で後始末待ちが解消することを確認する
  ///
  /// `ScreenCaptureController` は未起動のため、録画が残ったままの停止失敗そのものは再現しない。
  func testMediaChannelStopScreenCaptureRecoversFromScreenCleanupFailure() async throws {
    let videoSourceCoordinator = VideoSourceCoordinator()
    let mediaChannel = try makeConnectedMediaChannel(
      videoSourceCoordinator: videoSourceCoordinator)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    let senderStream = try XCTUnwrap(mediaChannel.senderStream, "送信ストリームを取得できること")
    guard
      case .success(let reservation) = videoSourceCoordinator.beginScreen(
        stream: senderStream)
    else {
      XCTFail("画面共有予約を取得できること")
      return
    }
    XCTAssertTrue(videoSourceCoordinator.completeScreenStart(reservation))
    guard let stopReservation = videoSourceCoordinator.beginScreenStop() else {
      XCTFail("画面共有の停止を予約できること")
      return
    }
    videoSourceCoordinator.finishScreenStop(stopReservation, stopped: false)
    await assertStartScreenCaptureFailure(
      mediaChannel, equals: screenCleanupFailedMessage)

    // 案内どおりに停止を再試行すると、後始末待ちが解消する。
    await mediaChannel.stopScreenCapture()
    guard case .success = videoSourceCoordinator.beginScreen(stream: senderStream) else {
      XCTFail("停止の再試行で画面共有を予約できること")
      return
    }
    guard let recoveredReservation = videoSourceCoordinator.beginScreenStop() else {
      XCTFail("回復後の予約を解放できること")
      return
    }
    videoSourceCoordinator.finishScreenStop(recoveredReservation, stopped: true)
  }

  /// 同じ送信ストリームでカメラが動作中の場合は、従来どおりカメラ競合のエラーになることを確認する
  ///
  /// `VideoSourceCoordinator` のカメラ状態を人工的に作る経路のみを検証する。実カメラの
  /// `isCameraVideoCaptureRunning` 判定は実機確認とする。
  func testMediaChannelStartScreenCaptureKeepsCameraConflictErrorForCameraInUse() async throws {
    let videoSourceCoordinator = VideoSourceCoordinator()
    let mediaChannel = try makeConnectedMediaChannel(
      videoSourceCoordinator: videoSourceCoordinator)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    let senderStream = try XCTUnwrap(mediaChannel.senderStream, "送信ストリームを取得できること")
    guard let cameraReservation = videoSourceCoordinator.beginCamera(stream: senderStream) else {
      XCTFail("カメラ予約を取得できること")
      return
    }
    XCTAssertTrue(videoSourceCoordinator.completeCamera(cameraReservation, active: true))

    await assertStartScreenCaptureFailure(mediaChannel, equals: cameraConflictMessage)
  }

  /// 画面共有の実行中に開始すると、従来どおりカメラ競合のエラーになることを確認する
  func testMediaChannelStartScreenCaptureKeepsCameraConflictErrorForScreenOperationInProgress()
    async throws
  {
    let videoSourceCoordinator = VideoSourceCoordinator()
    let mediaChannel = try makeConnectedMediaChannel(
      videoSourceCoordinator: videoSourceCoordinator)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    let senderStream = try XCTUnwrap(mediaChannel.senderStream, "送信ストリームを取得できること")
    guard
      case .success(let reservation) = videoSourceCoordinator.beginScreen(
        stream: senderStream)
    else {
      XCTFail("画面共有予約を取得できること")
      return
    }
    XCTAssertTrue(videoSourceCoordinator.completeScreenStart(reservation))

    await assertStartScreenCaptureFailure(mediaChannel, equals: cameraConflictMessage)
  }

  /// 接続状態の確認後に切断処理が走った競合で、カメラ競合のエラーになることを確認する
  ///
  /// `MediaChannel` は接続状態のまま `VideoSourceCoordinator` だけを revoke し、
  /// `.cancelled` が従来のカメラ競合メッセージへ写像されることを検証する。
  func testMediaChannelStartScreenCaptureMapsCancelledToCameraConflictError() async throws {
    let videoSourceCoordinator = VideoSourceCoordinator()
    let mediaChannel = try makeConnectedMediaChannel(
      videoSourceCoordinator: videoSourceCoordinator)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    videoSourceCoordinator.revoke()
    await assertStartScreenCaptureFailure(mediaChannel, equals: cameraConflictMessage)
  }

  /// 初期カメラ無効から開始した場合も、停止キュー完了まで切断 callback と所有情報を保持することを確認する
  func testMediaChannelDisconnectWaitsForCameraCleanup() async throws {
    // process-wide の shared を汚染しないよう、テストローカルの owner を注入する
    let coordinator = CameraVideoCaptureCoordinator(owner: CameraStateOwner())
    let ownership = CameraCaptureOwnership()
    let videoSourceCoordinator = VideoSourceCoordinator()
    var configuration = makeTestConfiguration()
    configuration.initialCameraEnabled = false

    let mediaChannel = try MediaChannel(
      configuration: configuration,
      cameraCaptureCoordinator: coordinator,
      cameraCaptureOwnership: ownership,
      videoSourceCoordinator: videoSourceCoordinator)
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeStream(streamId: "camera-cleanup-test")
    let senderStream = BasicMediaStream(
      peerChannel: mediaChannel.peerChannel,
      nativeStream: nativeStream)
    let senderStreamBox = SenderStreamBox(stream: senderStream)
    let lease = VideoHardMuteLease()
    let reservation = try XCTUnwrap(videoSourceCoordinator.beginCamera(stream: senderStream))
    let authorization = CameraStartAuthorization(
      reservation: reservation,
      videoSourceCoordinator: videoSourceCoordinator,
      cameraCaptureOwnership: ownership)

    // 実カメラの代替物は作らず、開始成功後に使う予約確定処理と実際の切断処理を接続する。
    let completed = await coordinator.perform {
      authorization.completeStartedCamera(lease: lease, senderStream: senderStreamBox.stream)
    }
    XCTAssertTrue(completed, "接続後のカメラ開始予約を確定できること")
    let gate = CameraCaptureTestGate()
    coordinator.enqueue {
      await gate.wait()
    }
    await gate.waitUntilBlocked()

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
      configuration: makeTestConfiguration(),
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
