import XCTest

@testable import Sora

class RidTests: XCTestCase {
  func testRidEncodingAndDecoding() throws {
    let cases: [(Rid, String)] = [
      (.none, "\"none\""),
      (.r0, "\"r0\""),
      (.r1, "\"r1\""),
      (.r2, "\"r2\""),
    ]

    for (rid, expectedJson) in cases {
      // Encoding
      let encoder = JSONEncoder()
      let encodedData = try encoder.encode(rid)
      let encodedJson = String(data: encodedData, encoding: .utf8)
      XCTAssertEqual(encodedJson, expectedJson, "Failed encoding \(rid)")

      // Decoding
      let decoder = JSONDecoder()
      let decodedRid = try decoder.decode(Rid.self, from: expectedJson.data(using: .utf8)!)
      XCTAssertEqual(decodedRid, rid, "Failed decoding \(expectedJson)")
    }
  }

  func testDecodeInvalidRidThrowsError() throws {
    let decoder = JSONDecoder()
    let data = "\"invalid\"".data(using: .utf8)!
    XCTAssertThrowsError(try decoder.decode(Rid.self, from: data))
  }
}
