import XCTest

@testable import Sora

/// PeerChannel 経由の connect メッセージのエンコードに関するテスト
///
/// - Configuration から SignalingConnect への写像 (makeSignalingConnect) を経由して、
///   connect メッセージの JSON に spotlight 設定が正しく反映されることを検証する
/// - 新旧 API (isSpotlightEnabled / spotlightEnabled) の JSON 出力の等価性を検証する
final class PeerChannelConnectEncodingTests: XCTestCase {

  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() throws -> URL {
    guard let url = URL(string: "wss://example.com") else {
      throw XCTSkip("failed to create test URL")
    }
    return url
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() throws -> Configuration {
    let url = try makeTestURL()
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
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

  // SignalingConnect を connect メッセージとしてエンコードし、 JSON を返す
  private func encodeConnect(_ connect: SignalingConnect) throws -> [String: Any] {
    let encoder = JSONEncoder()
    let data = try encoder.encode(Signaling.connect(connect))
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("JSON に変換できない")
      return [:]
    }
    return json
  }

  // Configuration から PeerChannel を経由して connect JSON を取得する
  private func encodeConnect(from config: Configuration) throws -> [String: Any] {
    let peerChannel = makePeerChannel(config: config)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    return try encodeConnect(connect)
  }

  // isSpotlightEnabled = true の場合、 connect JSON に spotlight: true が含まれることを検証する
  func testIsSpotlightEnabledProducesSpotlightJSON() throws {
    var config = try makeConfiguration()
    config.isSpotlightEnabled = true

    let json = try encodeConnect(from: config)

    XCTAssertEqual(json["spotlight"] as? Bool, true)
  }

  // isSpotlightEnabled = false の場合、 connect JSON に spotlight キーが含まれないことを検証する
  func testIsSpotlightEnabledFalseOmitsSpotlightJSON() throws {
    var config = try makeConfiguration()
    config.isSpotlightEnabled = false

    let json = try encodeConnect(from: config)

    XCTAssertNil(json["spotlight"], "spotlight キーが含まれてはいけない")
  }

  // デフォルトの場合、 connect JSON に spotlight キーが含まれないことを検証する
  func testSpotlightDefaultOmitsSpotlightJSON() throws {
    let config = try makeConfiguration()

    let json = try encodeConnect(from: config)

    XCTAssertNil(json["spotlight"], "spotlight キーが含まれてはいけない")
  }

  // 新旧 API のどちらで spotlight を有効化しても、 connect JSON の spotlight 出力が等価であることを検証する
  func testSpotlightOutputEquivalentBetweenNewAndOldAPI() throws {
    // 新 API (isSpotlightEnabled)
    var configNew = try makeConfiguration()
    configNew.isSpotlightEnabled = true

    // 旧 API (spotlightEnabled)
    var configOld = try makeConfiguration()
    configOld.spotlightEnabled = .enabled

    let jsonNew = try encodeConnect(from: configNew)
    let jsonOld = try encodeConnect(from: configOld)

    // 新 API で spotlight が true になっていることを確認する
    XCTAssertEqual(jsonNew["spotlight"] as? Bool, true)
    // 新旧 API の出力が等価であることを確認する
    XCTAssertEqual(jsonNew["spotlight"] as? Bool, jsonOld["spotlight"] as? Bool)
  }

  // spotlightNumber / spotlightFocusRid / spotlightUnfocusRid を併用しても新旧 API の出力が等価であることを検証する
  func testSpotlightRelatedParamsEquivalentBetweenNewAndOldAPI() throws {
    // 新 API (isSpotlightEnabled)
    var configNew = try makeConfiguration()
    configNew.isSpotlightEnabled = true
    configNew.spotlightNumber = 3
    configNew.spotlightFocusRid = .r0
    configNew.spotlightUnfocusRid = .r1

    // 旧 API (spotlightEnabled)
    var configOld = try makeConfiguration()
    configOld.spotlightEnabled = .enabled
    configOld.spotlightNumber = 3
    configOld.spotlightFocusRid = .r0
    configOld.spotlightUnfocusRid = .r1

    let jsonNew = try encodeConnect(from: configNew)
    let jsonOld = try encodeConnect(from: configOld)

    // 新 API で spotlight 関連パラメーターが正しくエンコードされることを確認する
    XCTAssertEqual(jsonNew["spotlight"] as? Bool, true)
    XCTAssertEqual(jsonNew["spotlight_number"] as? Int, 3)
    XCTAssertEqual(jsonNew["spotlight_focus_rid"] as? String, "r0")
    XCTAssertEqual(jsonNew["spotlight_unfocus_rid"] as? String, "r1")
    // 新旧 API の出力が等価であることを確認する
    XCTAssertEqual(jsonNew["spotlight"] as? Bool, jsonOld["spotlight"] as? Bool)
    XCTAssertEqual(jsonNew["spotlight_number"] as? Int, jsonOld["spotlight_number"] as? Int)
    XCTAssertEqual(
      jsonNew["spotlight_focus_rid"] as? String,
      jsonOld["spotlight_focus_rid"] as? String)
    XCTAssertEqual(
      jsonNew["spotlight_unfocus_rid"] as? String,
      jsonOld["spotlight_unfocus_rid"] as? String)
  }
}
