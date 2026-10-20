import XCTest

@testable import Sora

/// RPC のエラー応答から `RPCErrorDetail` を作る経路のテスト。
///
/// 実 Sora を必要としない。`RPCErrorDetail.init(code:message:errorObject:)` は DataChannel で
/// 受け取ったエラー応答の辞書から `data` を `JSONValue` へ変換する唯一の経路なので、
/// ここで `data` の有無と値の型を検証する。
final class RPCErrorDetailTests: XCTestCase {
  /// 小数の期待値を作るときの locale。
  ///
  /// `Decimal(string:)` は locale に依存するため、環境によって結果が変わらないよう固定する。
  private static let posixLocale = Locale(identifier: "en_US_POSIX")

  /// JSON-RPC 2.0 のエラー応答から `error` の辞書を取り出す。
  ///
  /// DataChannel が受け取るのと同じ形にするため、`JSONSerialization` で文字列を読む。
  private func errorObject(from json: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let response = object as? [String: Any],
      let error = response["error"] as? [String: Any]
    else {
      throw SoraError.rpcDecodingError(reason: "test: error response is not an object")
    }
    return error
  }

  /// エラー応答の JSON から `RPCChannel.handleMessage` と同じ手順で詳細を作る。
  private func detail(from json: String) throws -> RPCErrorDetail {
    let errorObject = try errorObject(from: json)
    let code = try XCTUnwrap(errorObject["code"] as? Int, "code が Int であること")
    let message = try XCTUnwrap(errorObject["message"] as? String, "message が String であること")
    return RPCErrorDetail(code: code, message: message, errorObject: errorObject)
  }

  /// `error.data` に指定した断片を持つエラー応答の JSON を組み立てる。
  private func errorJSON(dataFragment: String) -> String {
    #"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"m","data":"# + dataFragment + "}}"
  }

  /// `error.data` が省略された場合は `nil` になること。
  func testDataIsNilWhenDataIsMissing() throws {
    let detail = try detail(
      from: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}"#)

    XCTAssertEqual(detail.code, -32601, "エラーコードが読み取れること")
    XCTAssertEqual(detail.message, "method not found", "エラーメッセージが読み取れること")
    XCTAssertNil(detail.data, "data key が無い場合は nil であること")
  }

  /// `error.data` が JSON の `null` の場合は `.null` になること。
  func testDataIsNullWhenDataIsJSONNull() throws {
    let detail = try detail(from: errorJSON(dataFragment: "null"))

    XCTAssertEqual(detail.data, .null, "JSON の null は .null であること")
  }

  /// `error.data` の各型が対応する case へ変換されること。
  func testDataIsConvertedForEachType() throws {
    let cases: [(fragment: String, expected: JSONValue)] = [
      ("true", .bool(true)),
      (#""text""#, .string("text")),
      ("1", .decimal(1)),
      (#"[1,"a",null]"#, .array([.decimal(1), .string("a"), .null])),
      (
        #"{"nested":{"key":"value"},"count":2}"#,
        .object(["nested": .object(["key": .string("value")]), "count": .decimal(2)])
      ),
      ("1e300", .double(1e300)),
    ]

    for item in cases {
      let detail = try detail(from: errorJSON(dataFragment: item.fragment))

      XCTAssertEqual(
        detail.data, item.expected, "data が期待する JSONValue へ変換されること: \(item.fragment)")
    }
  }

  /// 小数は `Decimal` として復元されること。
  ///
  /// `JSONSerialization` は数値トークンを `NSNumber` として経由して 17 桁の表記で直列化するため、
  /// JSON の表記と `Decimal` の値は一致しない。期待値は浮動小数リテラルではなく文字列から作る
  /// (`Decimal(0.1)` では一致しない)。
  func testDataIsDecimalForFraction() throws {
    let detail = try detail(from: errorJSON(dataFragment: "0.1"))

    XCTAssertEqual(
      detail.data,
      .decimal(Decimal(string: "0.10000000000000001", locale: Self.posixLocale)!),
      "小数は Decimal として復元されること")
  }

  /// JSON の数値として表現できない値が届いてもクラッシュせず `nil` になること。
  ///
  /// `-1e999` は `JSONSerialization.jsonObject` が `NSNumber` の `-inf` として返すため、
  /// 実サーバーの応答からもこの経路に到達する。`code` と `message` は失わない。
  func testDataIsNilWhenDataIsNotJSONValue() throws {
    let errorObject = try errorObject(from: errorJSON(dataFragment: "-1e999"))
    // 前提が変わった場合に原因が分かるよう、変換前の値が読めていることを先に確認する
    _ = try XCTUnwrap(errorObject["data"], "JSONSerialization が -1e999 を data として読めること")

    let detail = RPCErrorDetail(
      code: try XCTUnwrap(errorObject["code"] as? Int),
      message: try XCTUnwrap(errorObject["message"] as? String),
      errorObject: errorObject)

    XCTAssertEqual(detail.code, 1, "エラーコードは失われないこと")
    XCTAssertEqual(detail.message, "m", "エラーメッセージは失われないこと")
    XCTAssertNil(detail.data, "変換できない値は nil になること")
  }

  /// `data` に JSON にできない値が入っていてもクラッシュせず `nil` になること。
  ///
  /// `JSONSerialization.jsonObject` の出力には現れない値だが、防御経路の確認として渡す。
  func testDataIsNilWhenDataIsNotSerializable() {
    let detail = RPCErrorDetail(code: 1, message: "m", errorObject: ["data": Date()])

    XCTAssertEqual(detail.code, 1, "エラーコードは失われないこと")
    XCTAssertEqual(detail.message, "m", "エラーメッセージは失われないこと")
    XCTAssertNil(detail.data, "変換できない値は nil になること")
  }

  /// `JSONValue.fromJSONSerializationValue` がトップレベルの断片も変換できること。
  func testFromJSONSerializationValueConvertsFragments() throws {
    XCTAssertEqual(try JSONValue.fromJSONSerializationValue(NSNull()), .null, "null が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue(true), .bool(true), "bool が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue("text"), .string("text"), "文字列が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue(1), .decimal(1), "整数が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue(0.5), .decimal(0.5), "小数が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue(1e300), .double(1e300),
      "Decimal が表現できない指数が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue([1, "a"]),
      .array([.decimal(1), .string("a")]),
      "配列が変換されること")
    XCTAssertEqual(
      try JSONValue.fromJSONSerializationValue(["key": "value"]),
      .object(["key": .string("value")]),
      "辞書が変換されること")
  }

  /// `JSONValue.fromJSONSerializationValue` が JSON にできない値で `EncodingError` を投げること。
  func testFromJSONSerializationValueThrowsForNotJSONValue() {
    XCTAssertThrowsError(try JSONValue.fromJSONSerializationValue(Date())) { error in
      guard case EncodingError.invalidValue = error else {
        XCTFail("EncodingError.invalidValue が投げられること: \(error)")
        return
      }
    }
  }
}
