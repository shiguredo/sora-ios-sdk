import WebRTC
import XCTest

@testable import Sora

class SignalingOfferEncodingTests: XCTestCase {
  private let decoder = JSONDecoder()

  // MARK: - JSON デコードテスト

  // 各 networkPriority の文字列表現が正しくデコードされることを確認する
  func testDecodeNetworkPriorityVeryLow() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "very-low"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertEqual(encoding.networkPriority, .veryLow)
  }

  func testDecodeNetworkPriorityLow() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "low"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertEqual(encoding.networkPriority, .low)
  }

  func testDecodeNetworkPriorityMedium() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "medium"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertEqual(encoding.networkPriority, .medium)
  }

  func testDecodeNetworkPriorityHigh() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "high"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertEqual(encoding.networkPriority, .high)
  }

  // networkPriority キーが存在しない場合は nil になることを確認する
  func testDecodeNetworkPriorityAbsent() throws {
    let json = """
    {"active": true, "rid": "r0"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertNil(encoding.networkPriority)
  }

  // 未知の文字列の場合は nil になることを確認する
  func testDecodeNetworkPriorityUnknown() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "unknown-value"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertNil(encoding.networkPriority)
  }

  // MARK: - rtpEncodingParameters 反映テスト

  // rtpEncodingParameters に networkPriority が正しく反映されることを確認する
  func testRtpEncodingParametersReflectsNetworkPriority() throws {
    let cases: [(String, RTCPriority)] = [
      ("very-low", .veryLow),
      ("low", .low),
      ("medium", .medium),
      ("high", .high),
    ]
    for (jsonValue, expectedPriority) in cases {
      let json = """
      {"active": true, "rid": "r0", "networkPriority": "\(jsonValue)"}
      """
      let encoding = try decoder.decode(
        SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
      let params = encoding.rtpEncodingParameters
      XCTAssertEqual(
        params.networkPriority, expectedPriority,
        "networkPriority が \(jsonValue) の場合に expectedPriority \(expectedPriority) と一致しません")
    }
  }

  // networkPriority が nil の場合は rtpEncodingParameters.networkPriority も nil になることを確認する
  func testRtpEncodingParametersWithNilNetworkPriority() throws {
    let json = """
    {"active": true, "rid": "r0"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    let params = encoding.rtpEncodingParameters
    XCTAssertNil(params.networkPriority)
  }

  // MARK: - RTCPriority 文字列表現テスト

  // RTCPriority の CustomStringConvertible が正しい文字列を返すことを確認する
  func testRTCPriorityDescription() throws {
    let cases: [(RTCPriority, String)] = [
      (.veryLow, "very-low"),
      (.low, "low"),
      (.medium, "medium"),
      (.high, "high"),
    ]
    for (priority, expected) in cases {
      XCTAssertEqual(
        priority.description, expected,
        "RTCPriority.\(priority) の description が \(expected) と一致しません")
    }
  }
}
