import XCTest

@testable import Sora

class SignalingOfferTests: XCTestCase {
  func testDecodeSimulcastRpcRids() throws {
    let testCases: [(simulcastRpcRids: [String], expectedRids: [Rid]?, shouldThrow: Bool)] = [
      (["r0", "r1", "r2"], [.r0, .r1, .r2], false),
      (["none"], [.none], false),
      ([], [], false),
      (["invalid"], nil, true),
    ]

    for (simulcastRpcRids, expectedRids, shouldThrow) in testCases {
      let json: String
      if simulcastRpcRids.isEmpty {
        json = """
        {
          "type": "offer",
          "client_id": "client123",
          "connection_id": "conn123",
          "sdp": "v=0\\r\\no=- 1 1 IN IP4 127.0.0.1\\r\\n",
          "simulcast_rpc_rids": []
        }
        """
      } else {
        let ridsJson = simulcastRpcRids.map { "\"\($0)\"" }.joined(separator: ", ")
        json = """
        {
          "type": "offer",
          "client_id": "client123",
          "connection_id": "conn123",
          "sdp": "v=0\\r\\no=- 1 1 IN IP4 127.0.0.1\\r\\n",
          "simulcast_rpc_rids": [\(ridsJson)]
        }
        """
      }

      let data = json.data(using: .utf8)!
      let decoder = JSONDecoder()

      if shouldThrow {
        XCTAssertThrowsError(try decoder.decode(SignalingOffer.self, from: data))
      } else {
        let offer = try decoder.decode(SignalingOffer.self, from: data)
        XCTAssertEqual(offer.simulcastRpcRids, expectedRids)
      }
    }
  }

  func testDecodeSimulcastRpcRidsNotPresent() throws {
    let json = """
    {
      "type": "offer",
      "client_id": "client123",
      "connection_id": "conn123",
      "sdp": "v=0\\r\\no=- 1 1 IN IP4 127.0.0.1\\r\\n"
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    let offer = try decoder.decode(SignalingOffer.self, from: data)

    XCTAssertNil(offer.simulcastRpcRids)
  }
}
