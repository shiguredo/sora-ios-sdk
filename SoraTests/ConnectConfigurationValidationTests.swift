import XCTest

@testable import Sora

/// 接続開始前の JSON 化可否検証のテスト
///
/// JSON 化できない `dataChannels` や metadata を設定したときに、プロセスが abort したり
/// 送信されないままタイムアウトを待ったりせず、接続開始前に
/// `SoraError.configurationError` として終端することを検証する。
final class ConnectConfigurationValidationTests: XCTestCase {
  // テスト用の Configuration を構築する
  private func makeConfiguration(role: Role = .sendrecv) -> Configuration {
    Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: role)
  }

  // configurationError の理由を検証する
  //
  // `message` は入力の種類を特定するために使う (ループ内の失敗箇所を判別できるようにする)。
  private func assertConfigurationError(
    _ configuration: Configuration,
    reason expected: String?,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try MediaChannel(configuration: configuration), message, file: file, line: line
    ) { error in
      guard case SoraError.configurationError(let reason) = error else {
        XCTFail("\(message): SoraError.configurationError が返ること: \(error)", file: file, line: line)
        return
      }
      if let expected {
        XCTAssertEqual(reason, expected, message, file: file, line: line)
      }
    }
  }

  /// 非有限値の metadata が接続開始前に configurationError になることを確認する
  func testNonFiniteMetadataIsRejectedBeforeConnect() {
    struct Metadata: Encodable {
      let value: Double
    }
    struct DecimalMetadata: Encodable {
      let value: Decimal
    }

    var doubleNaN = makeConfiguration()
    doubleNaN.signalingConnectMetadata = Metadata(value: .nan)
    assertConfigurationError(
      doubleNaN, reason: "signaling connect metadata could not be encoded",
      message: "signalingConnectMetadata の Double.nan")

    var doubleInfinity = makeConfiguration()
    doubleInfinity.signalingConnectNotifyMetadata = Metadata(value: .infinity)
    assertConfigurationError(
      doubleInfinity, reason: "signaling notify metadata could not be encoded",
      message: "signalingConnectNotifyMetadata の Double.infinity")

    // Decimal の NaN は JSONEncoder が throw せず不正な JSON を出力するため、
    // 再パースで検出する
    var decimalNaN = makeConfiguration()
    decimalNaN.signalingConnectMetadata = DecimalMetadata(value: .quietNaN)
    assertConfigurationError(
      decimalNaN, reason: "signaling connect metadata could not be encoded",
      message: "signalingConnectMetadata の Decimal.quietNaN")
  }

  /// JSON 化できない dataChannels がプロセスを abort させず configurationError になることを確認する
  ///
  /// 入力一覧は `ConnectionConfigurationSnapshotTests` の `invalidDataChannelsInputs()` と共通で、
  /// 変換の単体テストと同じ入力を使う。
  func testInvalidDataChannelsIsRejectedWithoutAbort() {
    for (label, value) in invalidDataChannelsInputs() {
      var configuration = makeConfiguration()
      configuration.dataChannels = value
      assertConfigurationError(
        configuration, reason: "data channels are not JSON-serializable",
        message: label)
    }
  }

  /// JSON 化できる dataChannels は検証を通ることを確認する
  func testValidDataChannelsIsAccepted() throws {
    let validInputs: [(String, Any)] = [
      ("辞書", ["x": 1] as [String: Any]),
      ("配列", [1, 2, 3]),
      ("数値", 1),
      ("null", NSNull()),
      ("Bool", true),
      ("Substring", "abc" as Substring),
      ("入れ子の Optional.none", ["a": Optional<Int>.none as Any]),
    ]

    for (label, value) in validInputs {
      var configuration = makeConfiguration()
      configuration.dataChannels = value
      XCTAssertNoThrow(
        try MediaChannel(configuration: configuration),
        "\(label) は JSON 化できるため接続開始前に終端しない")
    }
  }

  /// JSON 化可否の検証が audio の組合せ制約より先に評価されることを確認する
  func testJSONValidationRunsBeforeAudioConstraints() {
    var configuration = makeConfiguration()
    // audio の組合せ制約違反
    configuration.audioStereoOutputEnabled = true
    configuration.audioEnabled = false
    // JSON 化できない dataChannels
    configuration.dataChannels = Data([0x01])

    assertConfigurationError(
      configuration, reason: "data channels are not JSON-serializable",
      message: "audio の組合せ制約違反と JSON 化できない dataChannels")
  }

  /// Sora.connect が JSON 化できない設定を既存の設定エラー経路で通知することを確認する
  func testSoraConnectNotifiesConfigurationError() {
    let sora = Sora()
    var configuration = makeConfiguration(role: .sendonly)
    configuration.dataChannels = Data([0x01])

    var argumentError: Error?
    var globalError: Error?
    var addMediaChannelCount = 0
    let callbackExpectation = expectation(description: "両接続ハンドラーが通知されること")
    callbackExpectation.expectedFulfillmentCount = 2
    sora.handlers.onConnect = { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      globalError = error
      callbackExpectation.fulfill()
    }
    sora.handlers.onAddMediaChannel = { _ in
      addMediaChannelCount += 1
    }

    let task = sora.connect(configuration: configuration) { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      argumentError = error
      callbackExpectation.fulfill()
    }
    XCTAssertEqual(task.state, .completed, "設定エラーはタスクを即時完了する")

    wait(for: [callbackExpectation], timeout: 5)
    guard let argumentError, case SoraError.configurationError(let reason) = argumentError else {
      XCTFail(
        "接続 handler に SoraError.configurationError が届くこと: \(String(describing: argumentError))")
      return
    }
    XCTAssertEqual(reason, "data channels are not JSON-serializable")
    XCTAssertEqual(addMediaChannelCount, 0, "接続エラー時はチャネルを登録しない")
    XCTAssertNotNil(globalError, "Sora.handlers.onConnect にも通知する")
  }

  /// Sora.connect が NaN を含む metadata を既存の設定エラー経路で通知することを確認する
  ///
  /// `dataChannels` の検証と同じ経路で、encode に失敗する metadata も接続開始前に終端し、
  /// 接続タイムアウトを待たないことを固定する。
  func testSoraConnectNotifiesMetadataConfigurationError() {
    struct Metadata: Encodable {
      let value: Double
    }
    let sora = Sora()
    var configuration = makeConfiguration(role: .sendonly)
    configuration.signalingConnectMetadata = Metadata(value: .nan)

    var argumentError: Error?
    var globalError: Error?
    var addMediaChannelCount = 0
    let callbackExpectation = expectation(description: "両接続ハンドラーが通知されること")
    callbackExpectation.expectedFulfillmentCount = 2
    sora.handlers.onConnect = { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      globalError = error
      callbackExpectation.fulfill()
    }
    sora.handlers.onAddMediaChannel = { _ in
      addMediaChannelCount += 1
    }

    let task = sora.connect(configuration: configuration) { mediaChannel, error in
      XCTAssertNil(mediaChannel)
      argumentError = error
      callbackExpectation.fulfill()
    }
    XCTAssertEqual(task.state, .completed, "設定エラーはタスクを即時完了する")

    wait(for: [callbackExpectation], timeout: 5)
    guard let argumentError, case SoraError.configurationError(let reason) = argumentError else {
      XCTFail(
        "接続 handler に SoraError.configurationError が届くこと: \(String(describing: argumentError))"
      )
      return
    }
    XCTAssertEqual(reason, "signaling connect metadata could not be encoded")
    XCTAssertEqual(addMediaChannelCount, 0, "接続エラー時はチャネルを登録しない")
    XCTAssertNotNil(globalError, "Sora.handlers.onConnect にも通知する")
  }
}
