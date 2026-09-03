import XCTest

@testable import Sora

/// SignalingConnect の audio.opus_params のエンコードに関するテスト
///
/// Configuration.audioOpusParams → SignalingConnect 経由で type: connect の
/// audio.opus_params が正しく JSON にエンコードされることを検証する。
final class SignalingConnectTests: XCTestCase {

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    let url = URL(string: "wss://example.com")!
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
  }

  // SignalingConnect を connect メッセージとしてエンコードし、JSON を返す
  private func encodeConnect(_ connect: SignalingConnect) throws -> [String: Any] {
    let encoder = JSONEncoder()
    let data = try encoder.encode(Signaling.connect(connect))
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("JSON に変換できない")
      return [:]
    }
    return json
  }

  // JSON から audio コンテナを取り出す
  private func audioContainer(from json: [String: Any]) -> [String: Any]? {
    json["audio"] as? [String: Any]
  }

  // テスト用の Opus params 構造体
  private struct TestOpusParams: Encodable {
    let minptime: Int
    let stereo: Bool
  }

  /// audioOpusParams が nil の場合、audio.opus_params キーが存在しないことを確認する
  func testOpusParamsNilProducesNoOpusParams() throws {
    let config = makeConfiguration()
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    let json = try encodeConnect(connect)

    let audio = audioContainer(from: json)
    if let audio {
      XCTAssertNil(audio["opus_params"], "opus_params が nil の場合は含まれないこと")
    }
  }

  /// audioOpusParams に具体的な Encodable 型を設定した場合、
  /// audio.opus_params がエンコードされることを確認する
  /// (opus_params を送信するには audioCodec = .opus の明示が必須である)
  func testOpusParamsEncoded() throws {
    var config = makeConfiguration()
    config.audioCodec = .opus
    config.audioOpusParams = TestOpusParams(minptime: 10, stereo: true)
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    let json = try encodeConnect(connect)

    guard let audio = audioContainer(from: json) else {
      XCTFail("audio コンテナが存在すること")
      return
    }
    XCTAssertEqual(audio["codec_type"] as? String, "OPUS", "codec_type が OPUS であること")
    guard let opusParams = audio["opus_params"] as? [String: Any] else {
      XCTFail("opus_params が存在すること")
      return
    }
    XCTAssertEqual(opusParams["minptime"] as? Int, 10, "minptime が正しくエンコードされること")
    XCTAssertEqual(opusParams["stereo"] as? Bool, true, "stereo が正しくエンコードされること")
  }

  /// audioCodec が .default の場合、audioOpusParams を設定しても
  /// opus_params は送信されない (codec_type を明示しないとオーディオフォーマットが
  /// 確定されず、Sora サーバーに invalid_audio_format で拒否されるため)
  func testOpusParamsNotSentWithDefaultCodec() throws {
    var config = makeConfiguration()
    // audioCodec = .default (Opus) のまま audioOpusParams のみ設定
    config.audioOpusParams = TestOpusParams(minptime: 10, stereo: false)
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    let json = try encodeConnect(connect)

    let audio = audioContainer(from: json)
    if let audio {
      XCTAssertNil(audio["opus_params"], ".default の場合は opus_params が含まれないこと")
    }
  }

  /// audioCodec が .pcmu の場合、audioOpusParams を設定しても
  /// audio.opus_params が JSON に含まれないことを確認する
  func testOpusParamsNotSentWithPCMU() throws {
    var config = makeConfiguration()
    config.audioCodec = .pcmu
    config.audioOpusParams = TestOpusParams(minptime: 10, stereo: true)
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    let json = try encodeConnect(connect)

    let audio = audioContainer(from: json)
    if let audio {
      XCTAssertNil(audio["opus_params"], ".pcmu の場合は opus_params が含まれないこと")
    }
  }

  /// audioEnabled = false の場合、audioOpusParams を設定しても
  /// audio コンテナが生成されずキーが存在しないことを確認する
  func testOpusParamsNotSentWithAudioDisabled() throws {
    var config = makeConfiguration()
    config.audioEnabled = false
    config.audioOpusParams = TestOpusParams(minptime: 10, stereo: true)
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    let json = try encodeConnect(connect)

    let audio = audioContainer(from: json)
    XCTAssertNil(audio, "audioEnabled = false の場合は audio コンテナが生成されないこと")
  }

  // PeerChannel を実際に構築する
  private func makePeerChannel(config: Configuration) -> PeerChannel {
    let signalingChannel = SignalingChannel(configuration: config)
    let nativeFactory = NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      configuration: config,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
  }
}
