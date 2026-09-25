import WebRTC
import XCTest

@testable import Sora

/// WebRTC の callback とテストスレッド間の値をロックで受け渡す。
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

/// 呼び出し回数を数える。ADM の音声スレッドから呼ばれるためロックで保護する。
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
/// factory (ADM を所有する) と track は PeerConnection 側からも参照されるが、
/// テストの意図を明確にするため戻り値として保持する。
private struct ConnectedAudioPair {
  let sender: RTCPeerConnection
  let receiver: RTCPeerConnection
  let senderFactory: NativePeerChannelFactory
  let receiverFactory: NativePeerChannelFactory
  let track: RTCAudioTrack
}

/// Sora の接続情報がなくても、実際の Opus / RTP / ADM を通してダミー音声を検証する。
/// ICE はローカル候補だけを交換し、マイク・スピーカー・STUN / TURN サーバーを使わない。
final class DummyStereoAudioLoopbackTests: XCTestCase {
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

  /// 接続中に切断スレッドから terminate しても、停止後に PCM の注入と state の更新が再開しないことを確認する
  ///
  /// `RTCAudioDevice` の lifecycle メソッドは ADM スレッドからのみ呼ぶ契約 (RTCAudioDevice.h) のため、
  /// 交差を作るために別スレッドから start / stop を呼ばない。接続確立時に ADM が開始した録音・再生を
  /// 維持したまま、SDK の切断経路 (PeerChannel) と同じくテストスレッドから `terminateDevice` を呼ぶ。
  ///
  /// ADM スレッド契約の下では、開始処理の準備中に停止を差し込む交差をテストから強制できない
  /// (開始処理も停止の後始末も同じ ADM スレッドに直列化される)。そのためここでは、
  /// 停止前に注入と再生が実際に起きていること (positive control) を確認した上で、
  /// 停止後に state が終端へ戻り、timer が発火しても注入と再生が再開しないことを検証する。
  func testTerminateWhileConnectedStopsRecordingAndPlayout() throws {
    let generatorCalls = CallCounter()
    let playoutCalls = CallCounter()
    // 実際に音声が流れるよう、無音ではなく左右で周波数の異なる正弦波を生成する
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

    // positive control: 停止の前に、ADM が録音と再生を実際に動かしていることを確認する
    let recording = expectation(
      for: NSPredicate { _, _ in
        generatorCalls.value > 0 && senderDevice.isRecording
      }, evaluatedWith: nil)
    let playout = expectation(
      for: NSPredicate { _, _ in
        playoutCalls.value > 0 && receiverDevice.isPlaying
      }, evaluatedWith: nil)
    wait(for: [recording, playout], timeout: 10)
    XCTAssertGreaterThan(generatorCalls.value, 0, "停止前に送信側が PCM を注入していること")
    XCTAssertGreaterThan(playoutCalls.value, 0, "停止前に受信側が PCM を再生していること")
    XCTAssertTrue(senderDevice.isRecording, "停止前に送信側の isRecording が true であること")
    XCTAssertTrue(receiverDevice.isPlaying, "停止前に受信側の isPlaying が true であること")

    // 接続を維持したまま停止する。lifecycle メソッドの呼び出しはテストスレッドのみで行う
    XCTAssertTrue(senderDevice.terminateDevice(), "送信側の terminateDevice が成功すること")
    XCTAssertTrue(receiverDevice.terminateDevice(), "受信側の terminateDevice が成功すること")
    XCTAssertFalse(senderDevice.isInitialized, "terminate 直後に送信側の isInitialized が false であること")
    XCTAssertFalse(senderDevice.isRecording, "terminate 直後に送信側の isRecording が false であること")
    XCTAssertFalse(
      senderDevice.isRecordingInitialized,
      "terminate 直後に送信側の isRecordingInitialized が false であること")
    XCTAssertFalse(
      receiverDevice.isInitialized, "terminate 直後に受信側の isInitialized が false であること")
    XCTAssertFalse(receiverDevice.isPlaying, "terminate 直後に受信側の isPlaying が false であること")
    XCTAssertFalse(
      receiverDevice.isPlayoutInitialized,
      "terminate 直後に受信側の isPlayoutInitialized が false であること")

    // 停止後に timer が発火しても注入・再生が再開せず、state が終端のままであることを確認する
    let generatorCallsAfterTerminate = generatorCalls.value
    let playoutCallsAfterTerminate = playoutCalls.value
    let idle = expectation(description: "terminate 後に PCM の注入と再生が再開しないこと")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { idle.fulfill() }
    wait(for: [idle], timeout: 2)
    XCTAssertEqual(
      generatorCalls.value, generatorCallsAfterTerminate, "terminate 後に PCM を注入しないこと")
    XCTAssertEqual(
      playoutCalls.value, playoutCallsAfterTerminate, "terminate 後に PCM を再生しないこと")
    XCTAssertFalse(senderDevice.isRecording, "terminate 後に送信側の isRecording が true に戻らないこと")
    XCTAssertFalse(receiverDevice.isPlaying, "terminate 後に受信側の isPlaying が true に戻らないこと")
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
      receiverFactory: receiverFactory, track: track)
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
