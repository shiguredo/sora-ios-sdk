@testable import Sora
import WebRTC
import XCTest

class SoraTests: XCTestCase {
    func testForwardingFilter() throws {
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
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(forwardingFilter)
        let got = String(data: data, encoding: .utf8)!
        
        NSLog(got)
        XCTAssert(expected == got)
    }
}
