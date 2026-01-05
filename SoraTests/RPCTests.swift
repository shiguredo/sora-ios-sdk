import WebRTC
import XCTest

@testable import Sora

class RPCTests: XCTestCase {
  override func setUp() {
    super.setUp()
  }

  override func tearDown() {
    super.tearDown()
  }

  // MARK: - SimulcastRequestRid Codable Tests

  func testSimulcastRequestRidDecodeInvalidValue() throws {
    let decoder = JSONDecoder()

    // Test that decoding invalid value throws error
    let invalidData = "\"invalid\"".data(using: .utf8)!
    XCTAssertThrowsError(try decoder.decode(SimulcastRequestRid.self, from: invalidData)) {
      error in
      // Verify it's a decoding error
      XCTAssertTrue(error is DecodingError)
    }
  }

  func testRequestSimulcastRidResultDecode() throws {
    let decoder = JSONDecoder()

    // Test decoding RequestSimulcastRidResult with rid field
    let json = """
      {
        "channel_id": "test-channel",
        "receiver_connection_id": "receiver-123",
        "rid": "r1",
        "sender_connection_id": "sender-456"
      }
      """
    let data = json.data(using: .utf8)!
    let result = try decoder.decode(RequestSimulcastRidResult.self, from: data)

    XCTAssertEqual(result.channelId, "test-channel")
    XCTAssertEqual(result.receiverConnectionId, "receiver-123")
    XCTAssertEqual(result.rid, .r1)
    XCTAssertEqual(result.senderConnectionId, "sender-456")
  }

  func testRequestSimulcastRidResultDecodeWithoutSenderConnectionId() throws {
    let decoder = JSONDecoder()

    // Test decoding RequestSimulcastRidResult without optional sender_connection_id
    let json = """
      {
        "channel_id": "test-channel",
        "receiver_connection_id": "receiver-123",
        "rid": "r0"
      }
      """
    let data = json.data(using: .utf8)!
    let result = try decoder.decode(RequestSimulcastRidResult.self, from: data)

    XCTAssertEqual(result.channelId, "test-channel")
    XCTAssertEqual(result.receiverConnectionId, "receiver-123")
    XCTAssertEqual(result.rid, .r0)
    XCTAssertNil(result.senderConnectionId)
  }

  func testRequestSimulcastRidParamsEncode() throws {
    let encoder = JSONEncoder()

    // Test encoding RequestSimulcastRidParams
    let params = RequestSimulcastRidParams(rid: .r2, senderConnectionId: "sender-123")
    let data = try encoder.encode(params)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertEqual(json["rid"] as? String, "r2")
    XCTAssertEqual(json["sender_connection_id"] as? String, "sender-123")
  }

  func testRequestSimulcastRidParamsEncodeWithoutSenderConnectionId() throws {
    let encoder = JSONEncoder()

    // Test encoding RequestSimulcastRidParams without optional senderConnectionId
    let params = RequestSimulcastRidParams(rid: .none)
    let data = try encoder.encode(params)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertEqual(json["rid"] as? String, "none")
    XCTAssertNil(json["sender_connection_id"])
  }
}
