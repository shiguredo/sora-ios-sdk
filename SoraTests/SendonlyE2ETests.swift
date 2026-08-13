import XCTest

@testable @preconcurrency import Sora

/// sendonly ダミー映像・音声テスト
final class SendonlyE2ETests: E2ETestBase {
  /// sendonly で DummyVideoCapturer を使ってダミー映像を送信できることを確認する
  func testSendonlyDummyVideo() throws {
    var config = try buildConfiguration(role: .sendonly)
    // 接続時の物理カメラ自動起動を抑止し、senderStream 生成後にダミー映像を流す
    config.initialCameraEnabled = false
    // この E2E はダミー映像送信の確認に限定し、音声初期化による不安定要因を避ける
    config.audioEnabled = false
    let expectation = self.expectation(description: "sendonly でダミー映像を送信できること")
    var capturer: DummyVideoCapturer?

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      guard let channel = mediaChannel, let stream = channel.senderStream else {
        XCTFail("senderStream が nil")
        expectation.fulfill()
        return
      }
      let currentCapturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
      currentCapturer.stream = stream
      currentCapturer.start()
      capturer = currentCapturer
      // connect コールバックの実行スレッドに依存させず、main RunLoop 上で 2 秒待機してから
      // ダミー映像送信の継続と WebRTC 統計情報を確認する
      DispatchQueue.main.async {
        [channel, currentCapturer, expectation] in
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
          channel.getStats { result in
            defer { expectation.fulfill() }
            XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")
            XCTAssertNotNil(channel.senderStream, "senderStream が維持されていること")
            XCTAssertTrue(currentCapturer.isRunning, "DummyVideoCapturer が動作中であること")
            XCTAssertGreaterThan(currentCapturer.frameCount, 0, "ダミー映像フレームが送信されていること")

            guard case .success(let stats) = result else {
              // getStats の failure は接続状態の遷移 (切断・チャンネル再生成等) が原因のため、
              // エラー詳細を含めて出力する
              if case .failure(let error) = result {
                XCTFail("getStats に失敗した : \(error)")
              } else {
                XCTFail("getStats に失敗した")
              }
              return
            }

            let videoOutbound = stats.entries.first {
              $0.type == "outbound-rtp"
                && ($0.values["kind"] as? NSString) == "video"
            }
            XCTAssertNotNil(videoOutbound, "outbound video stats が存在すること")
            let bytesSent = videoOutbound?.values["bytesSent"] as? NSNumber
            let packetsSent = videoOutbound?.values["packetsSent"] as? NSNumber
            XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
            XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
            XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が 0 より大きいこと")
            XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が 0 より大きいこと")
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }

    wait(for: [expectation], timeout: 90)
    capturer?.stop()
    // 切断
    if let channel = sora?.mediaChannels.first {
      disconnectAndVerify(channel: channel)
    }
  }

  /// sendonly で DummyAudioDevice を使ってダミー音声を送信できることを確認する
  func testSendonlyDummyAudio() throws {
    var config = try buildConfiguration(role: .sendonly)
    // この E2E はダミー音声送信の確認に限定し、映像は無効にする
    config.videoEnabled = false
    config.audioEnabled = true
    // 440Hz 正弦波を生成するダミー音声デバイスを注入する
    let sineWaveGenerator = SineWaveGenerator(frequency: 440)
    config.audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true,
      pcmGenerator: { data, frameCount, sampleRate in
        sineWaveGenerator.generate(data: data, frameCount: frameCount, sampleRate: sampleRate)
      })
    // DummyAudioDevice.initialize(with:) が接続試行時に AVAudioSession を有効化するため、
    // tearDown での復元対象とする
    audioSessionActivatedByTest = true
    let expectation = self.expectation(description: "sendonly でダミー音声を送信できること")

    _ = sora?.connect(configuration: config) { mediaChannel, error in
      if let error {
        XCTFail("接続に失敗した: \(error)")
        expectation.fulfill()
        return
      }
      guard let channel = mediaChannel else {
        XCTFail("メディアチャネルが nil")
        expectation.fulfill()
        return
      }
      // connect コールバックの実行スレッドに依存させず、main RunLoop 上で 2 秒待機してから
      // ダミー音声送信の継続と WebRTC 統計情報を確認する
      DispatchQueue.main.async { [channel, expectation] in
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
          channel.getStats { result in
            defer { expectation.fulfill() }
            XCTAssertEqual(channel.native?.connectionState, .connected, "接続状態が connected であること")

            guard case .success(let stats) = result else {
              // getStats の failure は接続状態の遷移 (切断・チャンネル再生成等) が原因のため、
              // エラー詳細を含めて出力する
              if case .failure(let error) = result {
                XCTFail("getStats に失敗した : \(error)")
              } else {
                XCTFail("getStats に失敗した")
              }
              return
            }

            // 音声コーデック (OPUS) が確定していることを確認する (sora-js-sdk の E2E と同様)
            let audioCodec = stats.entries.first {
              $0.type == "codec"
                && ($0.values["mimeType"] as? NSString) == "audio/opus"
            }
            XCTAssertNotNil(audioCodec, "audio codec stats が存在すること")

            let audioOutbound = stats.entries.first {
              $0.type == "outbound-rtp"
                && ($0.values["kind"] as? NSString) == "audio"
            }
            XCTAssertNotNil(audioOutbound, "outbound audio stats が存在すること")
            let bytesSent = audioOutbound?.values["bytesSent"] as? NSNumber
            let packetsSent = audioOutbound?.values["packetsSent"] as? NSNumber
            XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
            XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
            XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が 0 より大きいこと")
            XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が 0 より大きいこと")
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }

    wait(for: [expectation], timeout: 90)
    // 切断
    if let channel = sora?.mediaChannels.first {
      disconnectAndVerify(channel: channel)
    }
  }
}
