import AVFoundation
import WebRTC
import XCTest

@testable import Sora

/// ステレオ音声出力の ADM 設定、設定検証、音声セッション管理を検証します。
///
/// SDK が利用する実際の RTCAudioDeviceModule と RTCAudioSessionConfiguration を使い、
/// モックやスタブを使用せずに確認します。
final class StereoAudioOutputTests: XCTestCase {
  // テスト用の Configuration を構築する
  private func makeConfiguration(role: Role = .recvonly) -> Configuration {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: role)
  }

  /// ステレオ有効時は実際の ADM に設定が反映されることを確認する
  func testFactoryEnablesStereoPlayoutOnActualADM() throws {
    let factory = try NativePeerChannelFactory(
      bypassVoiceProcessing: false,
      audioSessionUsage: .stereoRemoteIO)

    guard let audioDeviceModule = factory.audioDeviceModule else {
      XCTFail("RTCAudioDeviceModule が生成されること")
      return
    }
    XCTAssertTrue(audioDeviceModule.stereoPlayoutEnabled())
  }

  /// 既定のモノラル経路では ADM のステレオ設定を有効にしないことを確認する
  func testFactoryKeepsStereoPlayoutDisabledByDefault() throws {
    let factory = try NativePeerChannelFactory(bypassVoiceProcessing: false)

    guard let audioDeviceModule = factory.audioDeviceModule else {
      XCTFail("RTCAudioDeviceModule が生成されること")
      return
    }
    XCTAssertFalse(audioDeviceModule.stereoPlayoutEnabled())
  }

  /// stereo API の成功値 0 はエラーへ変換しないことを確認する
  func testStereoPlayoutResultAcceptsZero() {
    XCTAssertNoThrow(try NativePeerChannelFactory.validateStereoPlayoutResult(0))
  }

  /// stereo API の非 0 は暗黙にモノラルへ戻さず mediaChannelError にすることを確認する
  func testStereoPlayoutResultRejectsNonZeroWithoutChangingCategory() {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let categoryBefore = configuration.category

    XCTAssertThrowsError(try NativePeerChannelFactory.validateStereoPlayoutResult(-1)) { error in
      guard case SoraError.mediaChannelError = error else {
        XCTFail("SoraError.mediaChannelError が返ること: \(error)")
        return
      }
    }
    XCTAssertEqual(configuration.category, categoryBefore)
  }

  /// audioEnabled=false とステレオの同時指定を ADM 生成前に拒否することを確認する
  func testRejectsStereoWhenAudioIsDisabled() {
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    configuration.audioEnabled = false

    assertConfigurationError(configuration)
  }

  /// PCMU とステレオの同時指定を ADM 生成前に拒否することを確認する
  func testRejectsStereoWithPCMU() {
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    configuration.audioCodec = .pcmu

    assertConfigurationError(configuration)
  }

  /// カスタム音声デバイスとステレオの同時指定を ADM 生成前に拒否することを確認する
  func testRejectsStereoWithCustomAudioDevice() {
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    configuration.audioDevice = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }

    assertConfigurationError(configuration)
  }

  /// 送信側の初期ハードミュートとステレオの同時指定を拒否することを確認する
  func testRejectsStereoSenderWithInitialMicrophoneDisabled() {
    var configuration = makeConfiguration(role: .sendonly)
    configuration.audioStereoOutputEnabled = true
    configuration.initialMicrophoneEnabled = false

    assertConfigurationError(configuration)
  }

  /// 不正な設定を検証しても共有 AudioSession category を変更しないことを確認する
  func testInvalidConfigurationDoesNotChangeCategory() {
    let audioSessionConfiguration = RTCAudioSessionConfiguration.webRTC()
    let categoryBefore = audioSessionConfiguration.category
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    configuration.audioEnabled = false

    assertConfigurationError(configuration)

    XCTAssertEqual(audioSessionConfiguration.category, categoryBefore)
  }

  /// 複数 lease の最後を解放するまで PlayAndRecord を維持し、最後に元へ戻すことを確認する
  func testAudioSessionCoordinatorMaintainsAndRestoresCategoryTemplate() throws {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let originalCategory = configuration.category
    configuration.category = AVAudioSession.Category.ambient.rawValue
    defer {
      configuration.category = originalCategory
      RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    let coordinator = AudioSessionCoordinator()
    let first = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    first.requirePlayAndRecord()
    let second = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    second.requirePlayAndRecord()

    XCTAssertEqual(coordinator.activeRequirementCount, 2)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 2)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)
    XCTAssertFalse(
      RTCAudioSessionConfiguration.webRTC() === configuration,
      "既存テンプレートを変更せず新しいオブジェクトへ差し替えること")

    first.release()
    first.release()
    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 1)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)

    let installedConfiguration = RTCAudioSessionConfiguration.webRTC()
    second.release()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 0)
    XCTAssertTrue(
      RTCAudioSessionConfiguration.webRTC() === installedConfiguration,
      "全 ADM の破棄後は SDK 所有テンプレートだけを更新すること")
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.ambient.rawValue)
  }

  /// stereo 以外の profile 同士は既存どおり同時に利用できることを確認する
  func testAudioSessionCoordinatorAllowsMultipleNonStereoProfiles() throws {
    let coordinator = AudioSessionCoordinator()
    let voiceProcessing = try coordinator.acquire(profile: .voiceProcessing)
    let custom = try coordinator.acquire(profile: .custom)

    XCTAssertEqual(coordinator.activeRequirementCount, 2)

    voiceProcessing.release()
    custom.release()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// 既存 ADM の生存中でもテンプレートを原子的に差し替えて送信接続を追加できることを確認する
  func testAudioSessionCoordinatorAllowsLateCategoryTransition() throws {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let originalCategory = configuration.category
    configuration.category = AVAudioSession.Category.ambient.rawValue
    defer {
      configuration.category = originalCategory
      RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    let coordinator = AudioSessionCoordinator()
    let receiver = try coordinator.acquire(profile: .voiceProcessing)
    let sender = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    sender.requirePlayAndRecord()

    XCTAssertEqual(coordinator.activeRequirementCount, 2)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)

    let installedConfiguration = RTCAudioSessionConfiguration.webRTC()
    receiver.release()
    sender.release()
    XCTAssertTrue(RTCAudioSessionConfiguration.webRTC() === installedConfiguration)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.ambient.rawValue)
  }

  /// 共有 template がすでに PlayAndRecord の場合は、既存の受信接続後も送信接続を許可することを確認する
  func testAudioSessionCoordinatorAllowsLateSenderWithoutCategoryTransition() throws {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let originalCategory = configuration.category
    configuration.category = AVAudioSession.Category.playAndRecord.rawValue
    defer {
      configuration.category = originalCategory
      RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    let coordinator = AudioSessionCoordinator()
    let receiver = try coordinator.acquire(profile: .voiceProcessing)
    let sender = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    sender.requirePlayAndRecord()

    XCTAssertEqual(coordinator.activeRequirementCount, 2)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 1)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)
    XCTAssertTrue(
      RTCAudioSessionConfiguration.webRTC() === configuration,
      "変更不要な場合はテンプレートを差し替えないこと")

    receiver.release()
    sender.release()
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)
  }

  /// category を要求した接続が先に終了しても、残る ADM の破棄までは復元しないことを確認する
  func testAudioSessionCoordinatorRestoresCategoryAfterAllProfilesRelease() throws {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let originalCategory = configuration.category
    configuration.category = AVAudioSession.Category.ambient.rawValue
    defer {
      configuration.category = originalCategory
      RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    let coordinator = AudioSessionCoordinator()
    let sender = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    sender.requirePlayAndRecord()
    let receiver = try coordinator.acquire(profile: .voiceProcessing)

    sender.release()
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue,
      "受信側 ADM が残る間は共有 template を復元しないこと")

    receiver.release()
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.ambient.rawValue,
      "すべての ADM を破棄した後に元の category へ復元すること")
  }

  /// 接続中にホストアプリが共有 template を差し替えた場合は、その設定を上書きしないことを確認する
  func testAudioSessionCoordinatorKeepsExternallyReplacedTemplate() throws {
    let originalConfiguration = RTCAudioSessionConfiguration.webRTC()
    defer { RTCAudioSessionConfiguration.setWebRTC(originalConfiguration) }

    let initialConfiguration = RTCAudioSessionConfiguration()
    initialConfiguration.category = AVAudioSession.Category.ambient.rawValue
    initialConfiguration.mode = AVAudioSession.Mode.default.rawValue
    initialConfiguration.sampleRate = 44_100
    RTCAudioSessionConfiguration.setWebRTC(initialConfiguration)

    let coordinator = AudioSessionCoordinator()
    let requirement = try coordinator.acquire(
      profile: .voiceProcessing,
      requiresPlayAndRecord: true)
    requirement.requirePlayAndRecord()

    let externalConfiguration = RTCAudioSessionConfiguration()
    externalConfiguration.category = AVAudioSession.Category.soloAmbient.rawValue
    externalConfiguration.mode = AVAudioSession.Mode.moviePlayback.rawValue
    externalConfiguration.sampleRate = 48_000
    RTCAudioSessionConfiguration.setWebRTC(externalConfiguration)

    requirement.release()

    XCTAssertTrue(
      RTCAudioSessionConfiguration.webRTC() === externalConfiguration,
      "ホストアプリが設定した template の同一性を維持すること")
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.soloAmbient.rawValue)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().mode,
      AVAudioSession.Mode.moviePlayback.rawValue)
    XCTAssertEqual(RTCAudioSessionConfiguration.webRTC().sampleRate, 48_000)
  }

  /// stereo profile は他の profile および 2 つ目の stereo と同時利用できないことを確認する
  func testAudioSessionCoordinatorExcludesStereoFromOtherAudioProfiles() throws {
    let coordinator = AudioSessionCoordinator()
    let voiceProcessing = try coordinator.acquire(profile: .voiceProcessing)

    assertConnectionBusy {
      _ = try coordinator.acquire(profile: .stereoRemoteIO)
    }
    voiceProcessing.release()

    let stereo = try coordinator.acquire(profile: .stereoRemoteIO)
    assertConnectionBusy {
      _ = try coordinator.acquire(profile: .stereoRemoteIO)
    }
    assertConnectionBusy {
      _ = try coordinator.acquire(profile: .voiceProcessing)
    }
    assertConnectionBusy {
      _ = try coordinator.acquire(profile: .custom)
    }

    stereo.release()
    let custom = try coordinator.acquire(profile: .custom)
    custom.release()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// Factory が通常送信接続の AudioSession lease を保持し、明示解放できることを確認する
  func testFactoryHoldsAndReleasesPlayAndRecordRequirement() throws {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    let originalCategory = configuration.category
    configuration.category = AVAudioSession.Category.ambient.rawValue
    defer {
      configuration.category = originalCategory
      RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    let coordinator = AudioSessionCoordinator()
    let factory = try NativePeerChannelFactory(
      bypassVoiceProcessing: false,
      audioSessionUsage: .voiceProcessing(requiresPlayAndRecord: true),
      audioSessionCoordinator: coordinator)

    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 1)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)

    let installedConfiguration = RTCAudioSessionConfiguration.webRTC()
    factory.releaseAudioSessionRequirement()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
    XCTAssertEqual(coordinator.activePlayAndRecordRequirementCount, 0)
    XCTAssertTrue(RTCAudioSessionConfiguration.webRTC() === installedConfiguration)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.ambient.rawValue)
  }

  /// 初期状態の disconnect では、後続の接続開始に必要な lease を失わないことを確認する
  func testInitialDisconnectKeepsAudioSessionRequirementUntilDeinit() throws {
    let coordinator = AudioSessionCoordinator()
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    var mediaChannel: MediaChannel? = try MediaChannel(
      configuration: configuration,
      audioSessionCoordinator: coordinator)

    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    mediaChannel?.disconnect(error: nil)
    XCTAssertEqual(coordinator.activeRequirementCount, 1)

    mediaChannel = nil
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// MediaChannel の最終参照解放時に native PeerConnection と lease を閉じることを確認する
  func testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement() throws {
    let coordinator = AudioSessionCoordinator()
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    var mediaChannel: MediaChannel? = try MediaChannel(
      configuration: configuration,
      audioSessionCoordinator: coordinator)
    guard let peerChannel = mediaChannel?.peerChannel else {
      XCTFail("PeerChannel が存在すること")
      return
    }
    let webRTCConfiguration = WebRTCConfiguration()
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        configuration: webRTCConfiguration,
        constraints: webRTCConfiguration.constraints,
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }
    peerChannel.nativeChannel = nativeChannel

    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    mediaChannel = nil

    XCTAssertEqual(nativeChannel.connectionState, .closed)
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// Sora を接続直後に解放しても、引数 callback と ConnectionTask が終端することを確認する
  func testConnectFinishesAfterSoraIsReleased() {
    guard let url = URL(string: "wss://127.0.0.1:1") else {
      XCTFail("テスト URL を生成できること")
      return
    }
    let configuration = Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .recvonly)
    let callbackExpectation = expectation(description: "接続失敗 callback が通知されること")
    weak var weakSora: Sora?
    var connectionTask: ConnectionTask?
    var callbackCount = 0
    var receivedError: Error?

    do {
      let sora = Sora()
      weakSora = sora
      connectionTask = sora.connect(configuration: configuration) { mediaChannel, error in
        XCTAssertNil(mediaChannel)
        callbackCount += 1
        receivedError = error
        callbackExpectation.fulfill()
      }
    }

    XCTAssertNil(weakSora, "MediaChannel の接続試行が Sora を保持しないこと")
    wait(for: [callbackExpectation], timeout: 5)
    XCTAssertEqual(callbackCount, 1)
    XCTAssertNotNil(receivedError)
    XCTAssertEqual(connectionTask?.state, .completed)
  }

  /// onAddMediaChannel から即時切断してもシグナリングを開始せず、接続試行を終端することを確認する
  func testOnAddMediaChannelCanDisconnectBeforeSignalingStarts() {
    guard let url = URL(string: "wss://127.0.0.1:1") else {
      XCTFail("テスト URL を生成できること")
      return
    }
    let configuration = Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .recvonly)
    let sora = Sora()
    let connectExpectation = expectation(description: "接続失敗 callback が通知されること")
    let removeExpectation = expectation(description: "切断したチャネルが管理対象から外れること")
    var addedChannel: MediaChannel?
    var addCount = 0
    var removeCount = 0
    var connectCount = 0
    var receivedError: Error?

    sora.handlers.onAddMediaChannel = { mediaChannel in
      addCount += 1
      addedChannel = mediaChannel
      XCTAssertEqual(mediaChannel.state, .connecting)
      mediaChannel.disconnect(error: SoraError.connectionCancelled)
    }
    sora.handlers.onRemoveMediaChannel = { mediaChannel in
      XCTAssertTrue(mediaChannel === addedChannel)
      removeCount += 1
      removeExpectation.fulfill()
    }

    let connectionTask = sora.connect(configuration: configuration) { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      connectCount += 1
      receivedError = error
      connectExpectation.fulfill()
    }

    wait(for: [connectExpectation, removeExpectation], timeout: 3)
    XCTAssertEqual(addCount, 1)
    XCTAssertEqual(removeCount, 1)
    XCTAssertEqual(connectCount, 1)
    XCTAssertNotNil(receivedError)
    XCTAssertEqual(connectionTask.state, .completed)
    XCTAssertEqual(addedChannel?.state, .disconnected)
    XCTAssertEqual(addedChannel?.signalingChannel.state, .disconnected)
    XCTAssertFalse(addedChannel?.isConnectionTimerRunning ?? true)
    XCTAssertTrue(sora.mediaChannels.isEmpty)
  }

  /// PeerChannel の処理中は切断を遅延し、実切断時に lease を解放することを確認する
  func testDelayedPeerChannelDisconnectKeepsRequirementUntilUnlock() throws {
    let coordinator = AudioSessionCoordinator()
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    let mediaChannel = try MediaChannel(
      configuration: configuration,
      audioSessionCoordinator: coordinator)
    let peerChannel = mediaChannel.peerChannel

    XCTAssertTrue(peerChannel.lock.lock())
    peerChannel.disconnect(error: nil, reason: .user)
    XCTAssertEqual(coordinator.activeRequirementCount, 1)

    peerChannel.lock.unlock()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// MediaChannel が先に解放されても PeerChannel の処理中は lease を維持することを確認する
  func testMediaChannelDeinitKeepsRequirementUntilPeerUnlock() throws {
    let coordinator = AudioSessionCoordinator()
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    var mediaChannel: MediaChannel? = try MediaChannel(
      configuration: configuration,
      audioSessionCoordinator: coordinator)
    guard let peerChannel = mediaChannel?.peerChannel else {
      XCTFail("PeerChannel が存在すること")
      return
    }

    XCTAssertTrue(peerChannel.lock.lock())
    peerChannel.disconnect(error: nil, reason: .user)
    mediaChannel = nil

    XCTAssertEqual(
      coordinator.activeRequirementCount,
      1,
      "PeerChannel と ADM が生存している間は lease を解放しないこと")

    peerChannel.lock.unlock()
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// 遅延切断では Peer の後始末前に状態と公開 callback を完了扱いにしないことを確認する
  func testMediaChannelDisconnectFinishesAfterPeerUnlock() throws {
    let coordinator = AudioSessionCoordinator()
    let hardMuteLease = VideoHardMuteLease()
    var stereoConfiguration = makeConfiguration()
    stereoConfiguration.audioStereoOutputEnabled = true
    let mediaChannel = try MediaChannel(
      configuration: stereoConfiguration,
      audioSessionCoordinator: coordinator,
      videoHardMuteLease: hardMuteLease)
    let peerChannel = mediaChannel.peerChannel
    var connectCallbackCount = 0
    var disconnectCallbackCount = 0
    var monoChannel: MediaChannel?
    var callbackError: Error?
    let disconnectExpectation = expectation(description: "Peer cleanup 後に切断 callback が届くこと")

    XCTAssertTrue(peerChannel.lock.lock())
    let connectionTask = mediaChannel.connect(
      webRTCConfiguration: WebRTCConfiguration()
    ) { _ in
      connectCallbackCount += 1
    }
    mediaChannel.handlers.onDisconnect = { _ in
      disconnectCallbackCount += 1
      do {
        monoChannel = try MediaChannel(
          configuration: self.makeConfiguration(),
          audioSessionCoordinator: coordinator)
      } catch {
        callbackError = error
      }
      disconnectExpectation.fulfill()
    }

    mediaChannel.disconnect(error: SoraError.connectionCancelled)

    XCTAssertEqual(mediaChannel.state, .disconnecting)
    XCTAssertEqual(connectionTask.state, .completed)
    XCTAssertEqual(connectCallbackCount, 0)
    XCTAssertEqual(disconnectCallbackCount, 0)
    XCTAssertEqual(coordinator.activeRequirementCount, 1)

    peerChannel.lock.unlock()

    wait(for: [disconnectExpectation], timeout: 3)

    XCTAssertEqual(mediaChannel.state, .disconnected)
    XCTAssertEqual(connectCallbackCount, 1)
    XCTAssertEqual(disconnectCallbackCount, 1)
    XCTAssertTrue(hardMuteLease.isRevoked, "公開切断 callback より前に hard mute lease を破棄すること")
    XCTAssertNil(callbackError)
    XCTAssertNotNil(monoChannel)
    XCTAssertEqual(coordinator.activeRequirementCount, 1)

    monoChannel = nil
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// 切断準備中の Peer 完了通知を保留し、準備完了時に 1 回だけ取り出すことを確認する
  func testDisconnectPreparationDefersPeerCompletionUntilFinished() {
    var preparation = MediaChannelDisconnectPreparation()
    let connectionTask = ConnectionTask()
    let error = SoraError.connectionCancelled
    let completion = MediaChannelDisconnectPreparation.Completion(
      connectionTask: connectionTask,
      error: error,
      reason: .user)

    XCTAssertTrue(preparation.begin())
    XCTAssertEqual(preparation.state, .running)
    XCTAssertEqual(preparation.receive(completion), .deferred)

    let deferredCompletion = preparation.complete()
    XCTAssertEqual(preparation.state, .finished)
    XCTAssertTrue(deferredCompletion?.connectionTask === connectionTask)
    XCTAssertEqual(deferredCompletion?.error?.localizedDescription, error.localizedDescription)
    XCTAssertEqual(preparation.receive(completion), .ready)
    XCTAssertNil(preparation.complete(), "完了通知は 2 回取り出せないこと")

    // ConnectionTask.cancel() から Peer の完了通知が先に到着した順序も確認する。
    var peerFirstPreparation = MediaChannelDisconnectPreparation()
    XCTAssertEqual(peerFirstPreparation.receive(completion), .prepare)
    XCTAssertTrue(peerFirstPreparation.complete()?.connectionTask === connectionTask)
    XCTAssertEqual(peerFirstPreparation.state, .finished)
  }

  /// 即時 cancel の終端後に接続タイマーが遅れて再始動しないことを確認する
  func testImmediateCancelDoesNotRestartConnectionTimerAfterDisconnect() throws {
    var configuration = makeConfiguration()
    configuration.connectionTimeout = 1
    let mediaChannel = try MediaChannel(configuration: configuration)
    let callbackExpectation = expectation(description: "接続 callback が終端すること")
    var callbackCount = 0

    let connectionTask = mediaChannel.connect(webRTCConfiguration: WebRTCConfiguration()) {
      error in
      callbackCount += 1
      XCTAssertNotNil(error)
      callbackExpectation.fulfill()
    }
    connectionTask.cancel()

    wait(for: [callbackExpectation], timeout: 5)
    let schedulingExpectation = expectation(description: "遅延した接続開始処理が完了すること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      schedulingExpectation.fulfill()
    }
    wait(for: [schedulingExpectation], timeout: 1)

    XCTAssertEqual(connectionTask.state, .canceled)
    XCTAssertEqual(mediaChannel.state, .disconnected)
    XCTAssertFalse(mediaChannel.isConnectionTimerRunning)
    XCTAssertEqual(callbackCount, 1)
  }

  /// 接続予約後に切断が終端した場合、遅延したタイマー開始を拒否することを確認する
  func testConnectionTimerAuthorizationRejectsStartAfterTermination() {
    var authorization = MediaChannelConnectionTimerAuthorization()

    XCTAssertEqual(authorization.state, .idle)
    authorization.authorizeConnection()
    XCTAssertEqual(authorization.state, .authorized)

    // basicConnect のタイマー開始より先に切断が終端する競合順序を決定的に再現する。
    authorization.terminate()
    XCTAssertEqual(authorization.state, .terminated)
    XCTAssertFalse(
      authorization.beginTimer(),
      "切断終端後に遅れて到着したタイマー開始は拒否されること")
    XCTAssertEqual(authorization.state, .terminated)
  }

  /// 公開 native を先に close しても PeerChannel の cleanup と lease 解放が完了することを確認する
  func testNativePeerConnectionCloseReleasesRequirement() throws {
    let coordinator = AudioSessionCoordinator()
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    let mediaChannel = try MediaChannel(
      configuration: configuration,
      audioSessionCoordinator: coordinator)
    let peerChannel = mediaChannel.peerChannel
    let webRTCConfiguration = WebRTCConfiguration()
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        configuration: webRTCConfiguration,
        constraints: webRTCConfiguration.constraints,
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }
    peerChannel.nativeChannel = nativeChannel
    var disconnectCount = 0
    let disconnectExpectation = expectation(description: "native close の切断通知が完了すること")
    peerChannel.internalHandlers.onDisconnect = { _, _ in
      disconnectCount += 1
      disconnectExpectation.fulfill()
    }

    // 別の PeerChannel 処理が進行中の状態を作り、.closed 通知だけでは cleanup を
    // 先行させないことを確認する。
    XCTAssertTrue(peerChannel.lock.lock())
    nativeChannel.close()

    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    XCTAssertEqual(disconnectCount, 0)

    peerChannel.lock.unlock()
    wait(for: [disconnectExpectation], timeout: 3)

    // libwebrtc から重複した .closed 通知が届いても cleanup が再実行されないことを確認する。
    peerChannel.peerConnection(nativeChannel, didChange: RTCPeerConnectionState.closed)

    XCTAssertEqual(coordinator.activeRequirementCount, 0)
    XCTAssertEqual(disconnectCount, 1, "重複した .closed 通知でも cleanup は 1 回であること")
  }

  /// 切断 callback から別 profile を接続するとき、古い lease が残っていないことを確認する
  func testDisconnectCallbackCanCreateDifferentAudioProfile() throws {
    let coordinator = AudioSessionCoordinator()
    var stereoConfiguration = makeConfiguration()
    stereoConfiguration.audioStereoOutputEnabled = true
    let stereoChannel = try MediaChannel(
      configuration: stereoConfiguration,
      audioSessionCoordinator: coordinator)
    var monoChannel: MediaChannel?
    var callbackError: Error?

    stereoChannel.peerChannel.internalHandlers.onDisconnect = { _, _ in
      do {
        monoChannel = try MediaChannel(
          configuration: self.makeConfiguration(),
          audioSessionCoordinator: coordinator)
      } catch {
        callbackError = error
      }
    }

    stereoChannel.peerChannel.disconnect(error: nil, reason: .user)

    XCTAssertNil(callbackError)
    XCTAssertNotNil(monoChannel)
    XCTAssertEqual(coordinator.activeRequirementCount, 1)
    monoChannel = nil
    XCTAssertEqual(coordinator.activeRequirementCount, 0)
  }

  /// 不正な設定はタスクを即時完了し、両接続ハンドラーを非同期に 1 回ずつ通知することを確認する
  func testInvalidStereoConfigurationCompletesTaskAndNotifiesAsynchronously() {
    let sora = Sora()
    var configuration = makeConfiguration(role: .sendonly)
    configuration.audioStereoOutputEnabled = true
    configuration.initialMicrophoneEnabled = false

    var argumentHandlerCount = 0
    var globalHandlerCount = 0
    var addHandlerCount = 0
    var argumentError: Error?
    var globalError: Error?
    let callbackExpectation = expectation(description: "両接続ハンドラーが通知されること")
    callbackExpectation.expectedFulfillmentCount = 2
    sora.handlers.onConnect = { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      globalHandlerCount += 1
      globalError = error
      callbackExpectation.fulfill()
    }
    sora.handlers.onAddMediaChannel = { _ in
      addHandlerCount += 1
    }

    let task = sora.connect(configuration: configuration) { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      argumentHandlerCount += 1
      argumentError = error
      callbackExpectation.fulfill()
    }

    XCTAssertEqual(task.state, .completed)
    wait(for: [callbackExpectation], timeout: 1)
    XCTAssertEqual(argumentHandlerCount, 1)
    XCTAssertEqual(globalHandlerCount, 1)
    XCTAssertEqual(addHandlerCount, 0)
    XCTAssertTrue(sora.mediaChannels.isEmpty)
    XCTAssertNotNil(argumentError)
    XCTAssertEqual(argumentError?.localizedDescription, globalError?.localizedDescription)
  }

  /// ステレオ時のハードミュートが録音停止処理へ進まず未対応エラーを返すことを確認する
  func testStereoHardMuteReturnsUnsupportedError() throws {
    var configuration = makeConfiguration()
    configuration.audioStereoOutputEnabled = true
    let mediaChannel = try MediaChannel(configuration: configuration)
    defer { mediaChannel.disconnect(error: nil) }

    guard let error = mediaChannel.setAudioHardMute(true) else {
      XCTFail("ステレオ時のハードミュートはエラーを返すこと")
      return
    }
    guard case SoraError.mediaChannelError(let reason) = error else {
      XCTFail("SoraError.mediaChannelError が返ること: \(error)")
      return
    }
    XCTAssertTrue(reason.contains("stereo playout"))
  }

  // 設定検証が configurationError を返すことを確認する
  private func assertConfigurationError(_ configuration: Configuration) {
    XCTAssertThrowsError(try MediaChannel.validate(configuration: configuration)) { error in
      guard case SoraError.configurationError = error else {
        XCTFail("SoraError.configurationError が返ること: \(error)")
        return
      }
    }
  }

  // 一時的な AudioSession profile 競合が connectionBusy になることを確認する
  private func assertConnectionBusy(_ operation: () throws -> Void) {
    XCTAssertThrowsError(try operation()) { error in
      guard case SoraError.connectionBusy = error else {
        XCTFail("SoraError.connectionBusy が返ること: \(error)")
        return
      }
    }
  }
}
