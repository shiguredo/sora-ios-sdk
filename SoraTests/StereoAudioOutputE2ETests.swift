import AVFoundation
import WebRTC
import XCTest

@testable @preconcurrency import Sora

/// ステレオ音声出力を有効にした実接続を検証します。
///
/// E2E 環境の Sora と実際の ADM を利用し、モックやスタブは使用しません。
/// 外部音声 Publisher の受信確認には TEST_STEREO_AUDIO_CHANNEL_ID を指定します。
final class StereoAudioOutputE2ETests: E2ETestBase {
  /// ステレオ有効の recvonly で接続できることを確認する
  func testConnectStereoRecvonly() throws {
    let configuration = try buildStereoConfiguration(role: .recvonly)

    guard let channel = try connectAndVerify(configuration: configuration) else {
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

    guard let channel = try connectAndVerify(configuration: configuration) else {
      return
    }
    verifyInboundAudio(channel: channel)
    disconnectAndVerify(channel: channel)
  }

  /// ステレオ有効の sendonly で入力初期化待ちを残さず接続できることを確認する
  func testConnectStereoSendonly() throws {
    let configuration = try buildStereoConfiguration(role: .sendonly)

    guard let channel = try connectAndVerify(configuration: configuration) else {
      return
    }
    XCTAssertFalse(channel.peerChannel.isAudioInputInitialized)
    XCTAssertTrue(channel.senderStream?.hasAudioTrack == true)
    verifyOutboundAudio(channel: channel)
    disconnectAndVerify(channel: channel)
  }

  /// ステレオ有効の sendrecv で入力初期化待ちを残さず接続できることを確認する
  func testConnectStereoSendrecv() throws {
    let configuration = try buildStereoConfiguration(role: .sendrecv)

    guard let channel = try connectAndVerify(configuration: configuration) else {
      return
    }
    XCTAssertFalse(channel.peerChannel.isAudioInputInitialized)
    XCTAssertTrue(channel.senderStream?.hasAudioTrack == true)
    verifyOutboundAudio(channel: channel)
    disconnectAndVerify(channel: channel)
  }

  /// ステレオ送信接続の切断後に同じ設定で再接続して音声を送信できることを確認する
  func testReconnectStereoSendonly() throws {
    let categoryBefore = RTCAudioSessionConfiguration.webRTC().category
    let configuration = try buildStereoConfiguration(role: .sendonly)

    guard let firstChannel = try connectAndVerify(configuration: configuration) else {
      return
    }
    verifyOutboundAudio(channel: firstChannel)
    disconnectAndVerify(channel: firstChannel)
    XCTAssertEqual(RTCAudioSessionConfiguration.webRTC().category, categoryBefore)

    guard let secondChannel = try connectAndVerify(configuration: configuration) else {
      return
    }
    verifyOutboundAudio(channel: secondChannel)
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
    _ = outboundAudioCounts(channel: channel, delay: 1)
    guard let mutedStart = outboundAudioCounts(channel: channel, delay: 0),
      let mutedEnd = outboundAudioCounts(channel: channel, delay: 2)
    else {
      disconnectAndVerify(channel: channel)
      return
    }
    XCTAssertEqual(
      mutedEnd.packetsSent,
      mutedStart.packetsSent,
      "ハードミュート中は音声 packet が増加しないこと")
    XCTAssertEqual(
      mutedEnd.bytesSent,
      mutedStart.bytesSent,
      "ハードミュート中は音声 byte が増加しないこと")

    XCTAssertNil(channel.setAudioHardMute(false), "モノラル時にハードミュートを解除できること")
    guard let resumed = outboundAudioCounts(channel: channel, delay: 2) else {
      disconnectAndVerify(channel: channel)
      return
    }
    XCTAssertGreaterThan(
      resumed.packetsSent,
      mutedEnd.packetsSent,
      "ハードミュート解除後は音声 packet が再び増加すること")
    XCTAssertGreaterThan(
      resumed.bytesSent,
      mutedEnd.bytesSent,
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

  /// 接続し、ADM、AudioSession category、ローカル Answer SDP を確認する
  private func connectAndVerify(configuration: Configuration) throws -> MediaChannel? {
    // SDK の接続が実 AVAudioSession を変更するため、E2ETestBase の tearDown で復元する。
    audioSessionActivatedByTest = true
    guard let channel = connect(configuration: configuration, name: "ステレオ接続") else {
      return nil
    }

    XCTAssertEqual(channel.native?.connectionState, .connected)
    XCTAssertEqual(
      RTCAudioSessionConfiguration.webRTC().category,
      AVAudioSession.Category.playAndRecord.rawValue)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
    XCTAssertEqual(AVAudioSession.sharedInstance().mode, .default)
    let audioSession = AVAudioSession.sharedInstance()
    let usesBluetoothHFP = audioSession.currentRoute.outputs.contains {
      $0.portType == .bluetoothHFP
    }
    if usesBluetoothHFP {
      XCTAssertEqual(audioSession.outputNumberOfChannels, 1, "Bluetooth HFP はモノラルであること")
    } else {
      guard audioSession.maximumOutputNumberOfChannels >= 2 else {
        disconnectAndVerify(channel: channel)
        throw XCTSkip("現在の音声出力経路が 2 ch 出力に対応していないためスキップします")
      }
      XCTAssertEqual(audioSession.outputNumberOfChannels, 2, "ステレオ対応経路では 2 ch であること")
    }
    XCTAssertTrue(
      channel.peerChannel.nativePeerChannelFactory.audioDeviceModule?.stereoPlayoutEnabled()
        == true)

    guard let localSDP = channel.native?.localDescription?.sdp else {
      XCTFail("ローカル Answer SDP が存在すること")
      return channel
    }
    let requiresReceivingAudio: Bool
    switch configuration.role {
    case .sendonly:
      requiresReceivingAudio = false
    case .recvonly, .sendrecv:
      requiresReceivingAudio = true
    }
    XCTAssertTrue(
      hasStereoOpus(in: localSDP, requiresReceivingAudio: requiresReceivingAudio),
      "受信方向を持つ Opus の fmtp に stereo=1 が存在すること")
    return channel
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
    let statsExpectation = expectation(description: "音声 RTP が送信されること")

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      channel.getStats { result in
        DispatchQueue.main.async {
          defer { statsExpectation.fulfill() }
          guard case .success(let stats) = result else {
            if case .failure(let error) = result {
              XCTFail("音声統計の取得に失敗した: \(error)")
            }
            return
          }

          let outbound = stats.entries.first {
            $0.type == "outbound-rtp"
              && ($0.values["kind"] as? NSString) == "audio"
          }
          XCTAssertNotNil(outbound, "outbound audio stats が存在すること")
          XCTAssertGreaterThan(
            (outbound?.values["bytesSent"] as? NSNumber)?.intValue ?? 0,
            0,
            "音声の bytesSent が 0 より大きいこと")
          XCTAssertGreaterThan(
            (outbound?.values["packetsSent"] as? NSNumber)?.intValue ?? 0,
            0,
            "音声の packetsSent が 0 より大きいこと")
        }
      }
    }

    wait(for: [statsExpectation], timeout: 15)
  }

  /// inbound-rtp (audio) で外部 Publisher の RTP packet と byte を受信することを確認する
  private func verifyInboundAudio(channel: MediaChannel) {
    let statsExpectation = expectation(description: "外部 Publisher の音声 RTP を受信すること")

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      channel.getStats { result in
        DispatchQueue.main.async {
          defer { statsExpectation.fulfill() }
          guard case .success(let stats) = result else {
            if case .failure(let error) = result {
              XCTFail("音声統計の取得に失敗した: \(error)")
            }
            return
          }

          let inbound = stats.entries.first {
            $0.type == "inbound-rtp"
              && ($0.values["kind"] as? NSString) == "audio"
          }
          XCTAssertNotNil(inbound, "inbound audio stats が存在すること")
          XCTAssertGreaterThan(
            (inbound?.values["bytesReceived"] as? NSNumber)?.intValue ?? 0,
            0,
            "音声の bytesReceived が 0 より大きいこと")
          XCTAssertGreaterThan(
            (inbound?.values["packetsReceived"] as? NSNumber)?.intValue ?? 0,
            0,
            "音声の packetsReceived が 0 より大きいこと")
        }
      }
    }

    wait(for: [statsExpectation], timeout: 15)
  }

  /// 指定時間後の outbound-rtp (audio) の packet 数と byte 数を取得する
  private func outboundAudioCounts(
    channel: MediaChannel,
    delay: TimeInterval
  ) -> (packetsSent: Int, bytesSent: Int)? {
    let statsExpectation = expectation(description: "音声 RTP 統計を取得できること")
    var counts: (packetsSent: Int, bytesSent: Int)?

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      channel.getStats { result in
        DispatchQueue.main.async {
          defer { statsExpectation.fulfill() }
          guard case .success(let stats) = result else {
            if case .failure(let error) = result {
              XCTFail("音声統計の取得に失敗した: \(error)")
            }
            return
          }
          guard
            let outbound = stats.entries.first(where: {
              $0.type == "outbound-rtp"
                && ($0.values["kind"] as? NSString) == "audio"
            })
          else {
            XCTFail("outbound audio stats が存在すること")
            return
          }
          counts = (
            packetsSent: (outbound.values["packetsSent"] as? NSNumber)?.intValue ?? 0,
            bytesSent: (outbound.values["bytesSent"] as? NSNumber)?.intValue ?? 0
          )
        }
      }
    }

    wait(for: [statsExpectation], timeout: delay + 10)
    return counts
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
      // sendonly では受信音声が存在せず、ステレオ受信指定も不要となる。
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
