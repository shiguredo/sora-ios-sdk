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

/// Sora の接続情報がなくても、実際の Opus / RTP / ADM を通してダミーの左右音声を検証する。
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
    defer {
      sender.close()
      receiver.close()
    }
    let track = senderFactory.createNativeAudioTrack(trackId: "stereo", constraints: constraints)
    XCTAssertNotNil(sender.add(track, streamIds: ["stereo"]))

    try setDescription(try description(peer: sender, answer: false), peer: sender, local: true)
    waitForCandidates(peer: sender)
    try setDescription(try XCTUnwrap(sender.localDescription), peer: receiver, local: false)
    let answer = try description(peer: receiver, answer: true)
    // E2E の Answer と同じ受信優先指定を使い、Opus エンコーダーがモノラルへ落とさないようにする。
    let stereoAnswer = RTCSessionDescription(
      type: .answer, sdp: try StereoAudioSDP.enableStereo(in: answer.sdp))
    try setDescription(stereoAnswer, peer: receiver, local: true)
    waitForCandidates(peer: receiver)
    try setDescription(try XCTUnwrap(receiver.localDescription), peer: sender, local: false)

    let received = expectation(description: "実際の再生 PCM の左右を分離して受信できること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { received.fulfill() }
    wait(for: [received], timeout: 10)
    XCTAssertEqual(sender.connectionState, .connected)
    XCTAssertEqual(receiver.connectionState, .connected)
    XCTAssertGreaterThanOrEqual(probe.stereoDuration, 0.5, "左右を分離した再生 PCM が 0.5 秒以上あること")
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
