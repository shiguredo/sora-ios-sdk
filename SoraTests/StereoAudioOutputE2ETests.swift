import WebRTC
import XCTest

@testable @preconcurrency import Sora

/// 実際の Sora、Opus、RTP、ADM を使い、ダミー音声のステレオ送受信を検証する。
/// マイク・スピーカー・外部 Publisher は使わず、再生 PCM の左右の分離まで確認する。
/// カスタムデバイスの経路であり、ネイティブ RemoteIO の実機再生を検証するものではない。
final class StereoAudioOutputE2ETests: E2ETestBase {
  func testSendonlyDummyStereoAudio() throws {
    try verifyStereoPair(senderRole: .sendonly)
  }

  func testSendrecvDummyStereoAudio() throws {
    try verifyStereoPair(senderRole: .sendrecv)
  }

  /// 切断後にデバイスを作り直し、同じチャンネルで再び左右を分離して受信できることを確認する。
  func testReconnectDummyStereoAudio() throws {
    let channelId = buildChannelId(unique: true)
    try verifyStereoPair(senderRole: .sendonly, channelId: channelId)
    try verifyStereoPair(senderRole: .sendonly, channelId: channelId)
  }

  /// ダミーデバイス経路のハードミュートで送信が停止し、解除後に再開することを確認する。
  /// ネイティブ VPIO のマイクインジケーター制御を検証するテストではない。
  func testMonoDummyHardMuteStopsAndRestartsOutboundAudio() throws {
    var configuration = try buildConfiguration(role: .sendonly)
    configuration.channelId = buildChannelId(unique: true)
    configuration.videoEnabled = false
    configuration.audioEnabled = true
    let generator = SineWaveGenerator(frequency: 440)
    configuration.audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true,
      playoutHandler: { _, _ in },
      pcmGenerator: generator.generate)
    guard let channel = connect(configuration: configuration) else { return }
    defer { disconnectAndVerify(channel: channel) }
    guard let initial = audioCounts(channel: channel, delay: 2) else { return }
    XCTAssertGreaterThan(initial.bytes, 0, "ダミー音声が送信されること")
    XCTAssertNil(channel.setAudioHardMute(true))
    // ミュート直前のパケットが統計へ反映されるまで待ってから比較する。
    guard let mutedStart = audioCounts(channel: channel, delay: 1),
      let mutedEnd = audioCounts(channel: channel, delay: 2)
    else { return }
    XCTAssertEqual(mutedStart.bytes, mutedEnd.bytes, "ミュート中は送信 byte が増えないこと")
    XCTAssertEqual(mutedStart.packets, mutedEnd.packets, "ミュート中は送信 packet が増えないこと")
    XCTAssertNil(channel.setAudioHardMute(false))
    guard let resumed = audioCounts(channel: channel, delay: 2) else { return }
    XCTAssertGreaterThan(resumed.bytes, mutedEnd.bytes, "解除後は送信 byte が増えること")
    XCTAssertGreaterThan(resumed.packets, mutedEnd.packets, "解除後は送信 packet が増えること")
  }

  private func verifyStereoPair(senderRole: Role, channelId: String? = nil) throws {
    let channelId = channelId ?? buildChannelId(unique: true)
    let senderProbe = StereoToneProbe()
    let receiverProbe = StereoToneProbe()
    let senderConfiguration = try configuration(
      role: senderRole, channelId: channelId, probe: senderProbe)
    guard let sender = connect(configuration: senderConfiguration) else { return }
    defer { disconnectAndVerify(channel: sender) }
    // sendrecv では双方が配信し、双方向の再生 PCM を確認する。
    let receiverConfiguration = try configuration(
      role: senderRole == .sendrecv ? .sendrecv : .recvonly,
      channelId: channelId, probe: receiverProbe)
    guard let receiver = connect(configuration: receiverConfiguration) else { return }
    defer { disconnectAndVerify(channel: receiver) }

    let received = expectation(description: "ステレオ音声の再生データが届くこと")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { received.fulfill() }
    wait(for: [received], timeout: 10)
    XCTAssertEqual(sender.state, .connected, "音声送信中に接続が切断されていないこと")
    XCTAssertEqual(receiver.state, .connected, "音声受信中に接続が切断されていないこと")
    XCTAssertGreaterThanOrEqual(
      receiverProbe.stereoDuration, 0.5, "左右の異なる音声を 0.5 秒以上分離して受信すること")
    if senderRole == .sendrecv {
      XCTAssertGreaterThanOrEqual(
        senderProbe.stereoDuration, 0.5, "逆方向も左右を分離して受信すること")
    }
    XCTAssertTrue(receiver.configuration.requiresStereoAudioSDP)
    XCTAssertNil(receiver.peerChannel.nativePeerChannelFactory.audioDeviceModule)
    let sdp = try XCTUnwrap(receiver.native?.localDescription?.sdp)
    XCTAssertEqual(
      try StereoAudioSDP.enableStereo(in: sdp), sdp,
      "実際に設定した Answer のすべての受信 Opus が stereo=1 であること")
  }

  private func configuration(role: Role, channelId: String, probe: StereoToneProbe) throws
    -> Configuration
  {
    var configuration = try buildConfiguration(role: role)
    configuration.channelId = channelId
    configuration.videoEnabled = false
    configuration.audioEnabled = true
    configuration.audioCodec = .opus
    configuration.audioOpusParams = ["stereo": true]
    let generator = StereoSineWaveGenerator()
    configuration.audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2,
      playoutHandler: { samples, sampleRate in probe.consume(samples, sampleRate: sampleRate) },
      pcmGenerator: generator.generate)
    return configuration
  }

  private func connect(configuration: Configuration) -> MediaChannel? {
    let connected = expectation(description: "ダミー音声接続が完了すること")
    var connectedChannel: MediaChannel?
    _ = sora?.connect(configuration: configuration) { channel, error in
      if let error { XCTFail("接続に失敗した: \(error)") }
      connectedChannel = channel
      connected.fulfill()
    }
    wait(for: [connected], timeout: 35)
    XCTAssertNotNil(connectedChannel, "接続済みの MediaChannel が存在すること")
    return connectedChannel
  }

  private struct AudioRTPCounts: Sendable {
    let packets: Int
    let bytes: Int
  }

  @MainActor
  private final class AudioRTPCountsResult {
    var counts: AudioRTPCounts?
  }

  private func audioCounts(channel: MediaChannel, delay: TimeInterval) -> AudioRTPCounts? {
    let completed = expectation(description: "音声 RTP 統計を取得できること")
    let box = AudioRTPCountsResult()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      // WebRTC スレッドでは数値だけを取り出し、非 Sendable な統計オブジェクトは渡さない。
      channel.getStats { @Sendable result in
        let counts = result.map { stats -> AudioRTPCounts? in
          guard
            let entry = stats.entries.first(where: {
              $0.type == "outbound-rtp" && ($0.values["kind"] as? NSString) == "audio"
            })
          else { return nil }
          return AudioRTPCounts(
            packets: (entry.values["packetsSent"] as? NSNumber)?.intValue ?? 0,
            bytes: (entry.values["bytesSent"] as? NSNumber)?.intValue ?? 0)
        }
        DispatchQueue.main.async {
          defer { completed.fulfill() }
          switch counts {
          case .success(let value):
            XCTAssertNotNil(value, "音声の送信統計が存在すること")
            box.counts = value
          case .failure(let error):
            XCTFail("音声統計の取得に失敗した: \(error)")
          }
        }
      }
    }
    wait(for: [completed], timeout: delay + 10)
    return box.counts
  }
}
