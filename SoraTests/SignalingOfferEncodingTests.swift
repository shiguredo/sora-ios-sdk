import XCTest
import WebRTC

@testable import Sora

final class SignalingOfferEncodingTests: XCTestCase {
  private let decoder = JSONDecoder()

  // MARK: - JSON デコードテスト

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

  func testDecodeNetworkPriorityAbsent() throws {
    let json = """
    {"active": true, "rid": "r0"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertNil(encoding.networkPriority)
  }

  func testDecodeNetworkPriorityUnknown() throws {
    let json = """
    {"active": true, "rid": "r0", "networkPriority": "unknown-value"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    XCTAssertNil(encoding.networkPriority)
  }

  // MARK: - rtpEncodingParameters 反映テスト

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

  func testRtpEncodingParametersWithNilNetworkPriority() throws {
    let json = """
    {"active": true, "rid": "r0"}
    """
    let encoding = try decoder.decode(SignalingOffer.Encoding.self, from: json.data(using: .utf8)!)
    let params = encoding.rtpEncodingParameters
    // networkPriority が nil の場合はデフォルト値が維持されること
    let defaultParams = RTCRtpEncodingParameters()
    XCTAssertEqual(params.networkPriority, defaultParams.networkPriority)
  }
}
