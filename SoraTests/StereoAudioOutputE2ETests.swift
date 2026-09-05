import AVFoundation
import WebRTC
import XCTest

@testable @preconcurrency import Sora

/// WebRTC の統計オブジェクトを他スレッドへ渡さず、検証に必要な数値だけを保持する。
private struct AudioRTPCounts: Sendable {
  let packets: Int
  let bytes: Int
}

/// callback から返った数値を、テストと同じ MainActor 上で保存する。
@MainActor
private final class AudioRTPCountsResult {
  var counts: AudioRTPCounts?
}

/// ステレオ音声出力を有効にした実接続を検証します。
///
/// E2E 環境の Sora と実際の ADM を利用し、モックやスタブは使用しません。
/// 外部音声 Publisher の受信確認には TEST_STEREO_AUDIO_CHANNEL_ID を指定します。
final class StereoAudioOutputE2ETests: E2ETestBase {
  /// ステレオ有効の recvonly で接続できることを確認する
  func testConnectStereoRecvonly() throws {
    let configuration = try buildStereoConfiguration(role: .recvonly)

    guard let channel = connectAndVerify(configuration: configuration) else {
      return
    }
    disconnectAndVerify(channel: channel)
  }

  /// 外部 Publisher の音声をステレオ有効の recvonly で実際に受信することを確認する
  func testReceiveStereoAudioFromExternalPublisher() throws {
    guard
      let channelId = ProcessInfo.processInfo.environment["TEST_STEREO_AUDIO_CHANNEL_ID"],
      !channelId.isEmpty
    else {
      throw XCTSkip(
        "TEST_STEREO_AUDIO_CHANNEL_ID が未設定のため外部音声 Publisher の受信確認をスキップします")
    }
    var configuration = try buildStereoConfiguration(role: .recvonly)
    configuration.channelId = channelId

    guard
      let channel = connectAndVerify(configuration: configuration, requiresReceivingAudio: true)
    else {
      return
    }
    defer { disconnectAndVerify(channel: channel) }
    verifyInboundAudio(channel: channel)
    try verifyActiveStereoAudioSession()
  }

  /// ステレオ有効の sendonly で入力初期化待ちを残さず接続できることを確認する
  func testConnectStereoSendonly() throws {
    let configuration = try buildStereoConfiguration(role: .sendonly)

    guard let channel = connectAndVerify(configuration: configuration) else {
      return
    }
    defer { disconnectAndVerify(channel: channel) }
    XCTAssertFalse(channel.peerChannel.isAudioInputInitialized)
    XCTAssertTrue(channel.senderStream?.hasAudioTrack == true)
    verifyOutboundAudio(channel: channel)
    try verifyActiveStereoAudioSession()
  }

  /// ステレオ有効の sendrecv で入力初期化待ちを残さず接続できることを確認する
  func testConnectStereoSendrecv() throws {
    let configuration = try buildStereoConfiguration(role: .sendrecv)

    guard let channel = connectAndVerify(configuration: configuration) else {
      return
    }
    defer { disconnectAndVerify(channel: channel) }
    XCTAssertFalse(channel.peerChannel.isAudioInputInitialized)
    XCTAssertTrue(channel.senderStream?.hasAudioTrack == true)
    verifyOutboundAudio(channel: channel)
    try verifyActiveStereoAudioSession()
  }

  /// ステレオ送信接続の切断後に同じ設定で再接続して音声を送信できることを確認する
  func testReconnectStereoSendonly() throws {
    let categoryBefore = RTCAudioSessionConfiguration.webRTC().category
    let configuration = try buildStereoConfiguration(role: .sendonly)

    guard let firstChannel = connectAndVerify(configuration: configuration) else {
      return
    }
    defer { disconnectAndVerify(channel: firstChannel) }
    verifyOutboundAudio(channel: firstChannel)
    try verifyActiveStereoAudioSession()
    disconnectAndVerify(channel: firstChannel)
    XCTAssertEqual(RTCAudioSessionConfiguration.webRTC().category, categoryBefore)

    guard let secondChannel = connectAndVerify(configuration: configuration) else {
      return
    }
    defer { disconnectAndVerify(channel: secondChannel) }
    verifyOutboundAudio(channel: secondChannel)
    try verifyActiveStereoAudioSession()
    disconnectAndVerify(channel: secondChannel)
    XCTAssertEqual(RTCAudioSessionConfiguration.webRTC().category, categoryBefore)
  }

  /// 既定のモノラル経路でハードミュート中の音声送信が停止し、解除後に再開することを確認する
  func testMonoHardMuteStopsAndRestartsOutboundAudio() throws {
    var configuration = try buildConfiguration(role: .sendonly)
    configuration.channelId = buildChannelId(unique: true)
    configuration.videoEnabled = false
    configuration.audioEnabled = true
    configuration.audioStereoOutputEnabled = false
    configuration.initialMicrophoneEnabled = true

    guard let channel = connect(configuration: configuration, name: "モノラル接続") else {
      return
    }
    verifyOutboundAudio(channel: channel)
    XCTAssertNil(channel.setAudioHardMute(true), "モノラル時にハードミュートできること")

    // ミュート直前に生成済みの RTP packet が統計へ反映されるまで待ってから比較する。
    _ = audioCounts(channel: channel, delay: 1)
    guard let mutedStart = audioCounts(channel: channel, delay: 0),
      let mutedEnd = audioCounts(channel: channel, delay: 2)
    else {
      disconnectAndVerify(channel: channel)
      return
    }
    XCTAssertEqual(
      mutedEnd.packets,
      mutedStart.packets,
      "ハードミュート中は音声 packet が増加しないこと")
    XCTAssertEqual(
      mutedEnd.bytes,
      mutedStart.bytes,
      "ハードミュート中は音声 byte が増加しないこと")

    XCTAssertNil(channel.setAudioHardMute(false), "モノラル時にハードミュートを解除できること")
    guard let resumed = audioCounts(channel: channel, delay: 2) else {
      disconnectAndVerify(channel: channel)
      return
    }
    XCTAssertGreaterThan(
      resumed.packets,
      mutedEnd.packets,
      "ハードミュート解除後は音声 packet が再び増加すること")
    XCTAssertGreaterThan(
      resumed.bytes,
      mutedEnd.bytes,
      "ハードミュート解除後は音声 byte が再び増加すること")
    disconnectAndVerify(channel: channel)
  }

  /// ステレオ接続用の Configuration を構築する
  private func buildStereoConfiguration(role: Role) throws -> Configuration {
    var configuration = try buildConfiguration(role: role)
    configuration.channelId = buildChannelId(unique: true)
    configuration.videoEnabled = false
    configuration.audioEnabled = true
    configuration.audioCodec = .opus
    configuration.audioStereoOutputEnabled = true
    configuration.initialMicrophoneEnabled = true
    return configuration
  }

  /// 接続し、ADM、AudioSession template、ローカル Answer SDP を確認する
  private func connectAndVerify(
    configuration: Configuration,
    requiresReceivingAudio: Bool = false
  ) -> MediaChannel? {
    // SDK の接続が実 AVAudioSession を変更するため、E2ETestBase の tearDown で復元する。
    audioSessionActivatedByTest = true
    guard let channel = connect(configuration: configuration, name: "ステレオ接続") else {
      return nil
    }

    XCTAssertEqual(channel.native?.connectionState, .connected)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)
    XCTAssertTrue(
      channel.peerChannel.nativePeerChannelFactory.audioDeviceModule?.stereoPlayoutEnabled()
        == true)

    guard let localSDP = channel.native?.localDescription?.sdp else {
      XCTFail("ローカル Answer SDP が存在すること")
      return channel
    }
    // 空のチャンネルでは recvonly / sendrecv にも受信 audio section はまだ存在しない。
    // 外部 Publisher の受信テストだけは存在自体を必須にし、それ以外も存在する全節を検証する。
    XCTAssertTrue(
      hasStereoOpus(in: localSDP, requiresReceivingAudio: requiresReceivingAudio),
      "受信方向を持つ Opus の fmtp に stereo=1 が存在すること")
    return channel
  }

  /// RTP の送受信後に、実際に稼働した AudioSession の category と出力経路を確認する
  private func verifyActiveStereoAudioSession() throws {
    // 接続完了だけでは音声入出力が始まっていないため、実 category は RTP 確認後に検証する。
    let audioSession = AVAudioSession.sharedInstance()
    XCTAssertEqual(audioSession.category, .playAndRecord)
    XCTAssertEqual(audioSession.mode, .default)
    let usesBluetoothHFP = audioSession.currentRoute.outputs.contains {
      $0.portType == .bluetoothHFP
    }
    if usesBluetoothHFP {
      XCTAssertEqual(audioSession.outputNumberOfChannels, 1, "Bluetooth HFP はモノラルであること")
    } else {
      guard audioSession.maximumOutputNumberOfChannels >= 2 else {
        throw XCTSkip("現在の音声出力経路が 2 ch 出力に対応していないためスキップします")
      }
      XCTAssertEqual(audioSession.outputNumberOfChannels, 2, "ステレオ対応経路では 2 ch であること")
    }
  }

  /// 指定した設定で接続し、接続済みの MediaChannel を返す
  private func connect(configuration: Configuration, name: String) -> MediaChannel? {
    let connectExpectation = expectation(description: "\(name)が完了すること")
    var connectedChannel: MediaChannel?

    _ = sora?.connect(configuration: configuration) { mediaChannel, error in
      if let error {
        XCTFail("\(name)に失敗した: \(error)")
        connectExpectation.fulfill()
        return
      }
      connectedChannel = mediaChannel
      connectExpectation.fulfill()
    }

    wait(for: [connectExpectation], timeout: 35)
    guard let channel = connectedChannel else {
      XCTFail("接続済みの MediaChannel が存在すること")
      return nil
    }
    return channel
  }

  /// outbound-rtp (audio) で実際に RTP packet と byte が送信されることを確認する
  private func verifyOutboundAudio(channel: MediaChannel) {
    guard let counts = audioCounts(channel: channel, delay: 2) else {
      return
    }
    XCTAssertGreaterThan(counts.bytes, 0, "音声の bytesSent が 0 より大きいこと")
    XCTAssertGreaterThan(counts.packets, 0, "音声の packetsSent が 0 より大きいこと")
  }

  /// inbound-rtp (audio) で外部 Publisher の RTP packet と byte を受信することを確認する
  private func verifyInboundAudio(channel: MediaChannel) {
    guard let counts = audioCounts(channel: channel, receiving: true, delay: 2) else {
      return
    }
    XCTAssertGreaterThan(counts.bytes, 0, "音声の bytesReceived が 0 より大きいこと")
    XCTAssertGreaterThan(counts.packets, 0, "音声の packetsReceived が 0 より大きいこと")
  }

  /// 指定時間後の audio RTP の packet 数と byte 数を取得する
  private func audioCounts(
    channel: MediaChannel,
    receiving: Bool = false,
    delay: TimeInterval
  ) -> AudioRTPCounts? {
    let statsExpectation = expectation(description: "音声 RTP 統計を取得できること")
    let resultBox = AudioRTPCountsResult()

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      // WebRTC スレッドで呼ばれる入口には MainActor の隔離を継承させない。
      channel.getStats { @Sendable result in
        let counts = result.map { stats -> AudioRTPCounts? in
          let type = receiving ? "inbound-rtp" : "outbound-rtp"
          guard
            let entry = stats.entries.first(where: {
              $0.type == type && ($0.values["kind"] as? NSString) == "audio"
            })
          else {
            return nil
          }
          return AudioRTPCounts(
            packets: (entry.values[receiving ? "packetsReceived" : "packetsSent"] as? NSNumber)?
              .intValue
              ?? 0,
            bytes: (entry.values[receiving ? "bytesReceived" : "bytesSent"] as? NSNumber)?.intValue
              ?? 0)
        }
        // 非 Sendable の Statistics は渡さず、数値または Error のみを main queue へ戻す。
        DispatchQueue.main.async {
          defer { statsExpectation.fulfill() }
          switch counts {
          case .success(let counts):
            XCTAssertNotNil(counts, "audio RTP stats が存在すること")
            resultBox.counts = counts
          case .failure(let error):
            XCTFail("音声統計の取得に失敗した: \(error)")
          }
        }
      }
    }

    wait(for: [statsExpectation], timeout: delay + 10)
    return resultBox.counts
  }

  /// 受信方向を持つ audio section の Opus payload に対応する fmtp が stereo=1 を含むか確認する
  private func hasStereoOpus(in sdp: String, requiresReceivingAudio: Bool) -> Bool {
    let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    let firstMediaLineIndex = lines.firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
    let sessionDirection = direction(in: Array(lines[..<firstMediaLineIndex])) ?? "a=sendrecv"
    var sections: [[String]] = []
    var section: [String] = []

    for line in lines {
      if line.hasPrefix("m="), !section.isEmpty {
        sections.append(section)
        section = []
      }
      section.append(line)
    }
    sections.append(section)

    let receivingAudioSections = sections.filter { section in
      guard let mediaLine = section.first, mediaLine.hasPrefix("m=audio ") else {
        return false
      }
      let components = mediaLine.split(whereSeparator: { $0.isWhitespace })
      let port = components.count >= 2 ? components[1].split(separator: "/").first : nil
      let mediaDirection = direction(in: section) ?? sessionDirection
      let canReceive = mediaDirection == "a=sendrecv" || mediaDirection == "a=recvonly"
      return port != nil && port != "0" && canReceive
    }
    guard !receivingAudioSections.isEmpty else {
      // 送信専用や Publisher のいない接続では、受信音声が存在しないことを許容する。
      return !requiresReceivingAudio
    }

    return receivingAudioSections.allSatisfy { section in
      guard let mediaLine = section.first else {
        return false
      }
      let mediaPayloadTypes = Set(
        mediaLine.split(whereSeparator: { $0.isWhitespace }).dropFirst(3).map(String.init))
      var opusPayloadTypes: Set<String> = []
      var stereoPayloadTypes: Set<String> = []

      for line in section.dropFirst() {
        if line.hasPrefix("a=rtpmap:") {
          let components = line.dropFirst("a=rtpmap:".count).split {
            $0.isWhitespace
          }
          if components.count >= 2, components[1].lowercased() == "opus/48000/2",
            mediaPayloadTypes.contains(String(components[0]))
          {
            opusPayloadTypes.insert(String(components[0]))
          }
          continue
        }
        guard line.hasPrefix("a=fmtp:") else {
          continue
        }
        let components = line.dropFirst("a=fmtp:".count).split(
          maxSplits: 1,
          whereSeparator: { $0.isWhitespace })
        guard components.count == 2 else {
          continue
        }
        let parameters = components[1].split(separator: ";").map {
          String($0).trimmingCharacters(in: .whitespaces).lowercased()
        }
        if parameters.contains("stereo=1") {
          stereoPayloadTypes.insert(String(components[0]))
        }
      }

      return !opusPayloadTypes.isEmpty && opusPayloadTypes.isSubset(of: stereoPayloadTypes)
    }
  }

  /// SDP 節に明示された送受信方向を返す
  private func direction(in lines: [String]) -> String? {
    lines.lazy.map { $0.lowercased() }.first {
      $0 == "a=sendrecv" || $0 == "a=sendonly" || $0 == "a=recvonly" || $0 == "a=inactive"
    }
  }
}
