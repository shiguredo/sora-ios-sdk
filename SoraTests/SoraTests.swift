@testable import Sora
import WebRTC
import XCTest

func assert(_ input: Encodable, _ jsonString: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(input)
    let result = String(data: data, encoding: .utf8)!
    NSLog(result)
    XCTAssert(result == jsonString)
}

class SoraTests: XCTestCase {
    func testEncodeForwardingFilter_必須項目のみ() throws {
        let forwardingFilter = ForwardingFilter(
            action: .allow,
            rules: [[
                ForwardingFilterRule(
                    field: .connectionId,
                    operator: .isNotIn,
                    values: ["ham"]
                ),
                ForwardingFilterRule(
                    field: .connectionId,
                    operator: .isIn,
                    values: ["spam"]
                ),
            ],
            [
                ForwardingFilterRule(
                    field: .connectionId,
                    operator: .isNotIn,
                    values: ["egg"]
                ),
            ]]
        )

        let expected = """
        {
          "action" : "allow",
          "rules" : [
            [
              {
                "field" : "connection_id",
                "operator" : "is_not_in",
                "values" : [
                  "ham"
                ]
              },
              {
                "field" : "connection_id",
                "operator" : "is_in",
                "values" : [
                  "spam"
                ]
              }
            ],
            [
              {
                "field" : "connection_id",
                "operator" : "is_not_in",
                "values" : [
                  "egg"
                ]
              }
            ]
          ]
        }
        """

        try assert(forwardingFilter, expected)
    }

    func testEncodeForwardingFilter_metadataがArray() throws {
        let forwardingFilter = ForwardingFilter(
            action: .allow,
            rules: [[
                ForwardingFilterRule(
                    field: .connectionId,
                    operator: .isNotIn,
                    values: ["egg"]
                ),
            ]],
            version: "5",
            metadata: [1, 2]
        )

        let expected = """
        {
          "action" : "allow",
          "metadata" : [
            1,
            2
          ],
          "rules" : [
            [
              {
                "field" : "connection_id",
                "operator" : "is_not_in",
                "values" : [
                  "egg"
                ]
              }
            ]
          ],
          "version" : "5"
        }
        """

        try assert(forwardingFilter, expected)
    }
}
