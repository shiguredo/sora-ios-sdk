import AVFoundation
import WebRTC
import XCTest

@testable import Sora

/// WebRTC の callback とテストスレッド間の値をロックで受け渡す。
///
/// `@unchecked Sendable` としているのは、可変状態が `value` だけで、その読み書きをすべて
/// `lock` で排他しているためである (WebRTC の callback は別スレッドから届く)。
private final class AudioTestResult<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  func set(_ value: Value) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// 呼び出し回数を数える。
///
/// `@unchecked Sendable` としているのは、可変状態が `count` だけで、その読み書きをすべて
/// `lock` で排他しているためである (ADM の音声スレッドから呼ばれる)。
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// ローカル接続した 2 つの PeerConnection と、接続の生存期間中テストが保持するオブジェクト
///
/// `senderFactory` / `receiverFactory` は `AudioSessionRequirement` (共有 AudioSession への要求) を
/// 保持しており、解放すると接続中でも要求が解除されるため、テストの間は明示的に保持する。
/// track は `sender.add(_:streamIds:)` が作る native の sender (RtpSender) が保持するため、
/// ここでは保持しない。
private struct ConnectedAudioPair {
  let sender: RTCPeerConnection
  let receiver: RTCPeerConnection
  let senderFactory: NativePeerChannelFactory
  let receiverFactory: NativePeerChannelFactory
}

/// Sora の接続情報がなくても、実際の Opus / RTP / ADM を通してダミー音声を検証する。
/// ICE はローカル候補だけを交換し、マイク・スピーカー・STUN / TURN サーバーを使わない。
///
/// `playoutHandler` 経路の左右分離 (`testStereoPCMThroughRealPeerConnections`)、受信あり接続での
/// AudioUnit (RemoteIO) 経路 (`testReceiverWithoutPlayoutHandlerStartsAndStopsAudioUnit`)、
/// 接続中の `terminateDevice` 後の終端性 (`testTerminateWhileConnectedStopsRecordingAndPlayout`) を
/// 検証する。
final class DummyStereoAudioLoopbackTests: XCTestCase {
  /// 実際の Opus を通して、再生 PCM の左右を分離して受信できることを確認する
  func testStereoPCMThroughRealPeerConnections() throws {
    let source = StereoSineWaveGenerator()
    let probe = StereoToneProbe()
    let senderDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { _, _ in }, pcmGenerator: source.generate)
    let receiverDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { samples, sampleRate in probe.consume(samples, sampleRate: sampleRate) },
      pcmGenerator: { data, frames, _ in
        data.assumingMemoryBound(to: Int16.self).update(repeating: 0, count: frames * 2)
      })
    let pair = try connectAudioPair(
      senderDevice: senderDevice, receiverDevice: receiverDevice, trackId: "stereo",
      enableStereo: true)
    defer {
      pair.sender.close()
      pair.receiver.close()
    }

    let received = expectation(description: "実際の再生 PCM の左右を分離して受信できること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { received.fulfill() }
    wait(for: [received], timeout: 10)
    XCTAssertEqual(pair.sender.connectionState, .connected)
    XCTAssertEqual(pair.receiver.connectionState, .connected)
    XCTAssertGreaterThanOrEqual(probe.stereoDuration, 0.5, "左右を分離した再生 PCM が 0.5 秒以上あること")
  }

  /// `playoutHandler` を渡さない受信側が AudioUnit (RemoteIO) 経路で再生を開始し、停止で終端へ戻ることを確認する
  ///
  /// ADM が `initializePlayout` を呼ぶのは受信ストリームを持つ接続だけで、送信専用接続では呼ばれない。
  /// そのため送信側から音声を送る受信ありの接続を作り、受信側の device にだけ `playoutHandler` を
  /// 渡さないことで AudioUnit 経路を通す。AudioUnit の再生 PCM は ADM の音声スレッドが device から
  /// 直接取り出すため、`playoutHandler` 経路のように呼び出し回数では観測できない。ここでは
  /// `initializePlayout` と `startPlayout` の AudioUnit 分岐が state を更新したこと
  /// (`isPlayoutInitialized` / `isPlaying`) と、`terminateDevice` が AudioUnit を停止して終端へ
  /// 戻すことを検証する。
  ///
  /// 開始の途中で停止した場合に AudioUnit を停止して巻き戻す分岐は、ADM スレッド契約の下では
  /// テストから交差を強制できないため検証しない (契約違反の呼び出しに対する防御)。
  func testReceiverWithoutPlayoutHandlerStartsAndStopsAudioUnit() throws {
    let generatorCalls = CallCounter()
    let generator = StereoSineWaveGenerator()
    let senderDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { _, _ in },
      pcmGenerator: { data, frameCount, sampleRate in
        generatorCalls.increment()
        generator.generate(data: data, frameCount: frameCount, sampleRate: sampleRate)
      })
    // 受信専用の接続なので録音は初期化されない。`initialMicrophoneEnabled` は開始時のハードミュート
    // 状態を定めるだけである。`playoutHandler` を渡さないことで AudioUnit (RemoteIO) 経路になり、
    // `initialize(with:)` が共有 AudioSession を設定する
    let receiverDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: nil,
      pcmGenerator: { data, frameCount, _ in
        data.assumingMemoryBound(to: Int16.self).update(repeating: 0, count: frameCount * 2)
      })
    let pair = try connectAudioPair(
      senderDevice: senderDevice, receiverDevice: receiverDevice, trackId: "audio-unit",
      enableStereo: false)
    defer {
      pair.sender.close()
      pair.receiver.close()
      deactivateSharedAudioSession()
    }

    // positive control: 送信側が PCM を注入している (受信ストリームが存在する) ことを確認してから、
    // 受信側の AudioUnit 経路が再生を初期化して起動するまで待つ
    let recording = expectation(
      for: NSPredicate { _, _ in
        generatorCalls.value > 0 && senderDevice.isRecording
      }, evaluatedWith: nil)
    wait(for: [recording], timeout: 10)
    let audioUnitPlayout = expectation(
      for: NSPredicate { _, _ in
        receiverDevice.isPlayoutInitialized && receiverDevice.isPlaying
      }, evaluatedWith: nil)
    wait(for: [audioUnitPlayout], timeout: 10)
    XCTAssertEqual(pair.receiver.connectionState, .connected)
    XCTAssertTrue(
      receiverDevice.isPlayoutInitialized, "受信側の isPlayoutInitialized が true であること")
    XCTAssertTrue(receiverDevice.isPlaying, "受信側の isPlaying が true であること")

    // AudioUnit は ADM の音声スレッドが動かし続けるため、呼び出し回数ではなく state が終端へ
    // 戻らないことで、停止の直前まで再生が継続していることを確認する
    let active = expectation(description: "停止の直前まで受信側の AudioUnit が動作していること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { active.fulfill() }
    wait(for: [active], timeout: 3)
    XCTAssertTrue(receiverDevice.isPlaying, "停止の直前まで受信側の isPlaying が true であること")

    // 接続を維持したまま停止する。lifecycle メソッドの呼び出しはテストスレッドのみで行う
    XCTAssertTrue(senderDevice.terminateDevice(), "送信側の terminateDevice が成功すること")
    assertTerminated(senderDevice, "送信側")
    XCTAssertTrue(receiverDevice.terminateDevice(), "AudioUnit 経路の受信側の terminateDevice が成功すること")
    assertTerminated(receiverDevice, "AudioUnit 経路の受信側")

    // 停止後に AudioUnit が再起動しないことを確認する
    let idle = expectation(description: "terminate 後に受信側の AudioUnit が再起動しないこと")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { idle.fulfill() }
    wait(for: [idle], timeout: 3)
    assertTerminated(receiverDevice, "terminate 後の AudioUnit 経路の受信側")
  }

  /// 接続中に切断スレッドから terminate しても、停止後に PCM の注入と state の更新が再開しないことを確認する
  ///
  /// `RTCAudioDevice` の lifecycle メソッドは ADM スレッドからのみ呼ぶ契約 (RTCAudioDevice.h) のため、
  /// 交差を作るために別スレッドから start / stop を呼ばない。接続確立時に ADM が開始した録音・再生を
  /// 維持したまま、SDK の切断経路 (PeerChannel) と同じくテストスレッドから `terminateDevice` を呼ぶ。
  ///
  /// ADM スレッド契約の下では、開始処理の準備中に停止を差し込む交差をテストから強制できない
  /// (開始処理も停止の後始末も同じ ADM スレッドに直列化される)。そのためここでは、
  /// 停止の直前まで注入と再生が継続していること (positive control) を確認した上で、
  /// 停止後に state が終端へ戻り、timer が発火しても注入と再生が再開しないことを検証する。
  ///
  /// 交差を強制できないため、世代不一致で差し込みを拒否する分岐 (棄却経路) は ADM スレッド契約が
  /// 守られる限り実行されない。棄却経路は契約違反の呼び出しに対する防御であり、このテストでは
  /// 検証しない。
  func testTerminateWhileConnectedStopsRecordingAndPlayout() throws {
    let generatorCalls = CallCounter()
    let playoutCalls = CallCounter()
    // 実際の Opus 符号化・復号を通すため、無音ではなく正弦波を生成する。左右の分離は検証しないため
    // stereo SDP は使わず、channelCount 2 のダミー音声を流す
    let generator = StereoSineWaveGenerator()
    let senderDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { _, _ in },
      pcmGenerator: { data, frameCount, sampleRate in
        generatorCalls.increment()
        generator.generate(data: data, frameCount: frameCount, sampleRate: sampleRate)
      })
    let receiverDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { _, _ in playoutCalls.increment() },
      pcmGenerator: { data, frameCount, _ in
        data.assumingMemoryBound(to: Int16.self).update(repeating: 0, count: frameCount * 2)
      })
    let pair = try connectAudioPair(
      senderDevice: senderDevice, receiverDevice: receiverDevice, trackId: "terminate",
      enableStereo: false)
    defer {
      pair.sender.close()
      pair.receiver.close()
    }

    let connected = expectation(
      for: NSPredicate { _, _ in
        pair.sender.connectionState == .connected && pair.receiver.connectionState == .connected
      }, evaluatedWith: nil)
    wait(for: [connected], timeout: 10)

    // positive control: 接続後に ADM が録音と再生を動かしていることを確認する
    let recording = expectation(
      for: NSPredicate { _, _ in
        generatorCalls.value > 0 && senderDevice.isRecording
      }, evaluatedWith: nil)
    let playout = expectation(
      for: NSPredicate { _, _ in
        playoutCalls.value > 0 && receiverDevice.isPlaying
      }, evaluatedWith: nil)
    wait(for: [recording, playout], timeout: 10)
    XCTAssertTrue(senderDevice.isRecording, "停止前に送信側の isRecording が true であること")
    XCTAssertTrue(receiverDevice.isPlaying, "停止前に受信側の isPlaying が true であること")

    // 停止の直前まで注入と再生が継続していることを確認する。1 回でも発火していれば通る形にすると、
    // カウンタが凍結したまま「停止後に増えない」を満たしてしまう
    let generatorCallsBefore = generatorCalls.value
    let playoutCallsBefore = playoutCalls.value
    let active = expectation(description: "停止の直前まで録音と再生が継続していること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { active.fulfill() }
    wait(for: [active], timeout: 2)
    XCTAssertGreaterThan(
      generatorCalls.value, generatorCallsBefore, "停止の直前まで送信側が PCM を注入し続けていること")
    XCTAssertGreaterThan(
      playoutCalls.value, playoutCallsBefore, "停止の直前まで受信側が PCM を再生し続けていること")

    // 接続を維持したまま停止する。lifecycle メソッドの呼び出しはテストスレッドのみで行う
    XCTAssertTrue(senderDevice.terminateDevice(), "送信側の terminateDevice が成功すること")
    XCTAssertTrue(receiverDevice.terminateDevice(), "受信側の terminateDevice が成功すること")
    assertTerminated(senderDevice, "送信側")
    assertTerminated(receiverDevice, "受信側")

    // 停止後に timer が発火しても注入・再生が再開せず、state が終端のままであることを確認する。
    // 0.02 秒 (既定の IO バッファ期間) の 25 周期分待ち、timer が生きていれば必ず発火する時間を取る
    let generatorCallsAfterTerminate = generatorCalls.value
    let playoutCallsAfterTerminate = playoutCalls.value
    let idle = expectation(description: "terminate 後に PCM の注入と再生が再開しないこと")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { idle.fulfill() }
    wait(for: [idle], timeout: 3)
    XCTAssertEqual(
      generatorCalls.value, generatorCallsAfterTerminate, "terminate 後に PCM を注入しないこと")
    XCTAssertEqual(
      playoutCalls.value, playoutCallsAfterTerminate, "terminate 後に PCM を再生しないこと")
    assertTerminated(senderDevice, "terminate 後の送信側")
    assertTerminated(receiverDevice, "terminate 後の受信側")
  }

  /// 停止後の state がすべて終端であることを確認する
  private func assertTerminated(_ device: DummyAudioDevice, _ name: String) {
    XCTAssertFalse(device.isInitialized, "\(name) の isInitialized が false であること")
    XCTAssertFalse(device.isRecording, "\(name) の isRecording が false であること")
    XCTAssertFalse(device.isRecordingInitialized, "\(name) の isRecordingInitialized が false であること")
    XCTAssertFalse(device.isPlaying, "\(name) の isPlaying が false であること")
    XCTAssertFalse(device.isPlayoutInitialized, "\(name) の isPlayoutInitialized が false であること")
    XCTAssertFalse(device.isHardMuted, "\(name) の isHardMuted が初期状態 (ミュートなし) であること")
  }

  /// AudioUnit 経路の `initialize(with:)` が設定した共有 AudioSession をテストの最後に解除する
  ///
  /// `audioSessionUsage: .custom` の接続は SDK が AudioSession を管理しないため、`playoutHandler` を
  /// 渡さない device を使ったテストが設定したままの状態を残し得る。後続のテスト (AudioSession を
  /// 管理する実接続のテスト) へ影響を残さないよう、このテストだけが非アクティブへ戻す。テストは
  /// 直列に実行されるため、接続を保持したまま実行中のテストの AudioSession を解除することはない。
  /// カテゴリーは `.playAndRecord` のまま残るが、非アクティブなので後続のテストが自分で設定できる。
  private func deactivateSharedAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      // 解除できなくてもテストの判定には影響しない (後続のテストへの影響を減らすための後始末)
    }
  }

  /// 2 つの `DummyAudioDevice` をローカルの PeerConnection で接続する
  ///
  /// `enableStereo` を true にすると E2E と同じ受信優先指定で SDP を書き換え、
  /// Opus エンコーダーがモノラルへ落とさないようにする。
  private func connectAudioPair(
    senderDevice: DummyAudioDevice,
    receiverDevice: DummyAudioDevice,
    trackId: String,
    enableStereo: Bool
  ) throws -> ConnectedAudioPair {
    let senderFactory = try NativePeerChannelFactory(
      bypassVoiceProcessing: false, audioDevice: senderDevice, audioSessionUsage: .custom)
    let receiverFactory = try NativePeerChannelFactory(
      bypassVoiceProcessing: false, audioDevice: receiverDevice, audioSessionUsage: .custom)
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    let sender = try XCTUnwrap(
      senderFactory.nativeFactory.peerConnection(
        with: configuration, constraints: constraints, delegate: nil))
    let receiver = try XCTUnwrap(
      receiverFactory.nativeFactory.peerConnection(
        with: configuration, constraints: constraints, delegate: nil))
    let track = senderFactory.createNativeAudioTrack(trackId: trackId, constraints: constraints)
    XCTAssertNotNil(sender.add(track, streamIds: [trackId]))

    try setDescription(try description(peer: sender, answer: false), peer: sender, local: true)
    waitForCandidates(peer: sender)
    try setDescription(try XCTUnwrap(sender.localDescription), peer: receiver, local: false)
    let answer = try description(peer: receiver, answer: true)
    if enableStereo {
      let stereoAnswer = RTCSessionDescription(
        type: .answer, sdp: try StereoAudioSDP.enableStereo(in: answer.sdp))
      try setDescription(stereoAnswer, peer: receiver, local: true)
    } else {
      try setDescription(answer, peer: receiver, local: true)
    }
    waitForCandidates(peer: receiver)
    try setDescription(try XCTUnwrap(receiver.localDescription), peer: sender, local: false)
    return ConnectedAudioPair(
      sender: sender, receiver: receiver, senderFactory: senderFactory,
      receiverFactory: receiverFactory)
  }

  private func description(peer: RTCPeerConnection, answer: Bool) throws -> RTCSessionDescription {
    let completed = expectation(description: "SDP を生成できること")
    let result = AudioTestResult<RTCSessionDescription>()
    let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { description, error in
      XCTAssertNil(error)
      if let description { result.set(description) }
      completed.fulfill()
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    if answer {
      peer.answer(for: constraints, completionHandler: callback)
    } else {
      peer.offer(for: constraints, completionHandler: callback)
    }
    wait(for: [completed], timeout: 5)
    return try XCTUnwrap(result.get())
  }

  private func setDescription(
    _ description: RTCSessionDescription, peer: RTCPeerConnection, local: Bool
  )
    throws
  {
    let completed = expectation(description: "SDP を適用できること")
    let failure = AudioTestResult<Error>()
    let callback: @Sendable (Error?) -> Void = { error in
      if let error { failure.set(error) }
      completed.fulfill()
    }
    if local {
      peer.setLocalDescription(description, completionHandler: callback)
    } else {
      peer.setRemoteDescription(description, completionHandler: callback)
    }
    wait(for: [completed], timeout: 5)
    if let error = failure.get() { throw error }
  }

  private func waitForCandidates(peer: RTCPeerConnection) {
    // candidate を SDP に含めてから相手へ渡し、trickle ICE の通知実装を不要にする。
    let gathered = expectation(
      for: NSPredicate { _, _ in peer.iceGatheringState == .complete }, evaluatedWith: nil)
    wait(for: [gathered], timeout: 10)
  }
}
