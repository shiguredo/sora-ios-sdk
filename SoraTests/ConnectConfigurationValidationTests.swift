import XCTest

@testable import Sora

/// 接続開始前の JSON 化可否検証と、`Sora.connect` の設定エラー通知のテスト
///
/// JSON 化できない `dataChannels` や metadata を設定したときに、プロセスが abort したり
/// 送信されないままタイムアウトを待ったりせず、接続開始前に
/// `SoraError.configurationError` として終端することを検証する。あわせて、設定エラーが
/// `connect` の呼び出しスタック外で、引数の handler と `Sora.handlers.onConnect` へ
/// 1 回ずつこの順で通知されることを検証する (実行スレッドの同一性は検証しない)。
final class ConnectConfigurationValidationTests: XCTestCase {
  /// `connect` の呼び出しスタック内で handler が同期実行されないことを検証する目印のキー
  ///
  /// 目印は呼び出し元スレッドの thread dictionary にだけ立つため、検出できるのは
  /// 「呼び出し元スレッドへ同期で戻ってくる配送」だけである。配送先の queue そのものの変更
  /// (`DispatchQueue.global()` から別の queue へ) と、別スレッドで handler を実行して `connect` が
  /// その完了を待つ退行 (別スレッド上で `sync` が実行された場合を含む) は検出できない。配送先を
  /// 固定しないのは、handler の executor 契約を「呼び出しスレッドを保証しない」としており、
  /// 実行スレッドの同一性・直列性を契約にしないためである。
  private static let connectCallStackMarkerKey = "jp.shiguredo.sora.tests.connectCallStackMarker"

  /// 設定エラー通知を待つ上限
  ///
  /// 通知は `DispatchQueue.global()` への 1 回の dispatch で行われるため通常はミリ秒で完了する。
  /// この値は失敗時に待つ上限を与えるだけで、負荷の高い CI でも偽陽性を出さないよう余裕を持たせる。
  private static let connectNotificationTimeout: TimeInterval = 5

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
    reason expected: String,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try MediaChannel(configuration: configuration), message, file: file, line: line
    ) { error in
      guard let reason = configurationErrorReason(of: error) else {
        XCTFail("\(message): SoraError.configurationError が返ること: \(error)", file: file, line: line)
        return
      }
      XCTAssertEqual(reason, expected, message, file: file, line: line)
    }
  }

  // configurationError の reason を取り出す
  //
  // 期待する error が届かない場合に早期 return せず、後続の検証をすべて実行できるようにするため、
  // 判定と取り出しだけを行う (configurationError 以外なら nil を返す)。
  private func configurationErrorReason(of error: Error?) -> String? {
    guard let error, case SoraError.configurationError(let reason) = error else {
      return nil
    }
    return reason
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

  // Sora.connect の設定エラー通知を検証する
  //
  // 引数の handler と `Sora.handlers.onConnect` の両方へ、同じ reason の
  // `SoraError.configurationError` が `connect` の呼び出しスタック外で 1 回ずつ届くことを確認する。
  // この検証は接続開始前の検証失敗 (設定エラー経路) の回帰条件であり、handler を呼び出しスタック内で
  // 同期呼び出しする他の経路 (`MediaChannel.connect` の busy ガード) には適用しない。
  //
  // `message` は入力の種類を特定するために使う (失敗箇所を判別できるようにする)。
  private func assertConnectNotifiesConfigurationError(
    _ configuration: Configuration,
    reason expected: String,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let sora = Sora()
    var argumentHandlerError: Error?
    var onConnectError: Error?
    var argumentHandlerCount = 0
    var onConnectHandlerCount = 0
    var addMediaChannelCount = 0
    // expectation は handler ごとに分ける (timeout 時にどちらが通知されなかったかを判別するため)。
    let argumentCallbackExpectation = expectation(
      description: "\(message): 引数の handler が通知されること")
    let onConnectCallbackExpectation = expectation(
      description: "\(message): Sora.handlers.onConnect が通知されること")
    sora.handlers.onConnect = { mediaChannel, error in
      XCTAssertNil(
        Thread.current.threadDictionary[Self.connectCallStackMarkerKey],
        "\(message): Sora.handlers.onConnect は connect の呼び出しスタック内で同期実行されないこと",
        file: file, line: line)
      XCTAssertNil(
        mediaChannel, "\(message): Sora.handlers.onConnect には mediaChannel を渡さないこと",
        file: file, line: line)
      onConnectHandlerCount += 1
      // 2 回目の呼び出しはここで検出する。fulfill は 1 回目だけにして、expectation の over-fulfill
      // (XCTest の API violation・テストバンドルの異常終了) を起こさない。
      XCTAssertEqual(
        onConnectHandlerCount, 1, "\(message): Sora.handlers.onConnect は 1 回だけ呼ばれること",
        file: file, line: line)
      if onConnectHandlerCount == 1 {
        onConnectError = error
        onConnectCallbackExpectation.fulfill()
      }
    }
    sora.handlers.onAddMediaChannel = { _ in
      addMediaChannelCount += 1
    }

    // 呼び出し元スレッドの目印を立ててから接続し、戻った直後に消す。`defer` は wait の後まで
    // 目印を残して handler が常に目印を見てしまうため使わない。
    Thread.current.threadDictionary[Self.connectCallStackMarkerKey] = true
    // 目印の検証が空振りしていないこと (同一スレッドから目印が見えること) を確認する。
    XCTAssertNotNil(
      Thread.current.threadDictionary[Self.connectCallStackMarkerKey],
      "\(message): 目印が同一スレッドから見えること", file: file, line: line)
    let task = sora.connect(configuration: configuration) { mediaChannel, error in
      XCTAssertNil(
        Thread.current.threadDictionary[Self.connectCallStackMarkerKey],
        "\(message): 引数の handler は connect の呼び出しスタック内で同期実行されないこと",
        file: file, line: line)
      XCTAssertNil(
        mediaChannel, "\(message): 引数の handler には mediaChannel を渡さないこと", file: file, line: line)
      argumentHandlerCount += 1
      XCTAssertEqual(
        argumentHandlerCount, 1, "\(message): 引数の handler は 1 回だけ呼ばれること",
        file: file, line: line)
      if argumentHandlerCount == 1 {
        argumentHandlerError = error
        argumentCallbackExpectation.fulfill()
      }
    }
    Thread.current.threadDictionary.removeObject(forKey: Self.connectCallStackMarkerKey)
    XCTAssertEqual(
      task.state, .completed, "\(message): 設定エラーはタスクを即時完了する", file: file, line: line)

    wait(
      for: [argumentCallbackExpectation, onConnectCallbackExpectation],
      timeout: Self.connectNotificationTimeout)
    // 期待する error が届かない場合でも以降の検証をすべて実行し、1 回のテスト実行でどの handler に
    // 何が届いたかを報告する。呼び出し回数は handler 内の assert が検証している。
    let argumentReason = configurationErrorReason(of: argumentHandlerError)
    let onConnectReason = configurationErrorReason(of: onConnectError)
    XCTAssertNotNil(
      argumentReason,
      "\(message): 引数の handler に SoraError.configurationError が届くこと: \(String(describing: argumentHandlerError))",
      file: file, line: line)
    // onConnect 側にも error が届いたことを個別に確認する (両方が nil の場合、次の等式比較だけでは
    // 通ってしまうため)。
    XCTAssertNotNil(
      onConnectReason,
      "\(message): Sora.handlers.onConnect に SoraError.configurationError が届くこと: \(String(describing: onConnectError))",
      file: file, line: line)
    XCTAssertEqual(
      argumentReason, expected,
      "\(message): 引数の handler に届く reason: \(String(describing: argumentHandlerError))",
      file: file, line: line)
    XCTAssertEqual(
      onConnectReason, argumentReason,
      "\(message): 両方のハンドラーに同じ reason が届くこと: \(String(describing: onConnectError))",
      file: file, line: line)
    // 設定エラー経路ではチャネル登録が起きない
    XCTAssertEqual(
      addMediaChannelCount, 0, "\(message): 接続エラー時はチャネルを登録しない", file: file, line: line)
  }

  /// Sora.connect が JSON 化できない dataChannels を既存の設定エラー経路で通知することを確認する
  func testSoraConnectNotifiesConfigurationError() {
    var configuration = makeConfiguration(role: .sendonly)
    configuration.dataChannels = Data([0x01])
    assertConnectNotifiesConfigurationError(
      configuration,
      reason: "data channels are not JSON-serializable",
      message: "JSON 化できない dataChannels")
  }

  /// Sora.connect が NaN を含む metadata を既存の設定エラー経路で通知することを確認する
  ///
  /// `dataChannels` の検証と同じ経路で、encode に失敗する metadata も接続開始前に終端し、
  /// 接続タイムアウトを待たないことを固定する。
  func testSoraConnectNotifiesMetadataConfigurationError() {
    struct Metadata: Encodable {
      let value: Double
    }
    var configuration = makeConfiguration(role: .sendonly)
    configuration.signalingConnectMetadata = Metadata(value: .nan)
    assertConnectNotifiesConfigurationError(
      configuration,
      reason: "signaling connect metadata could not be encoded",
      message: "NaN を含む signalingConnectMetadata")
  }

  /// 設定エラー通知の順序 (引数の handler → `Sora.handlers.onConnect`) を確認する
  ///
  /// 引数の handler の末尾で呼び出し済みであることを記録し、`Sora.handlers.onConnect` の先頭で
  /// その記録を読む。この検証は 2 つの通知が同じ block (同じスレッド) から順に配送されることを
  /// 前提にする。別々の block へ分ける変更が入ると順序を決定的に検出できず flaky になるため、
  /// その場合は lock で保護した記録へ書き換える。
  ///
  /// このテストは順序と呼び出し回数だけを検証し、`error` と `mediaChannel` の内容は
  /// `assertConnectNotifiesConfigurationError` 側で検証する。handler ごとに expectation を
  /// 分けているため、どちらかが呼ばれない場合はその description 付きで timeout になり、余分に
  /// 呼ばれた場合は handler 内の回数の assert で失敗する (expectation の over-fulfill は起こさない)。
  func testSoraConnectNotifiesConfigurationErrorInOrder() {
    let sora = Sora()
    var configuration = makeConfiguration(role: .sendonly)
    configuration.dataChannels = Data([0x01])

    var argumentHandlerCount = 0
    var onConnectHandlerCount = 0
    var argumentHandlerCalled = false
    var onConnectObservedArgumentHandler = false
    let argumentCallbackExpectation = expectation(description: "引数の handler が通知されること")
    let onConnectCallbackExpectation = expectation(description: "Sora.handlers.onConnect が通知されること")
    sora.handlers.onConnect = { _, _ in
      onConnectHandlerCount += 1
      XCTAssertEqual(onConnectHandlerCount, 1, "Sora.handlers.onConnect は 1 回だけ呼ばれること")
      // この時点で引数の handler が呼び出し済みであることを記録する
      onConnectObservedArgumentHandler = argumentHandlerCalled
      if onConnectHandlerCount == 1 {
        onConnectCallbackExpectation.fulfill()
      }
    }

    let task = sora.connect(configuration: configuration) { _, _ in
      argumentHandlerCount += 1
      XCTAssertEqual(argumentHandlerCount, 1, "引数の handler は 1 回だけ呼ばれること")
      argumentHandlerCalled = true
      if argumentHandlerCount == 1 {
        argumentCallbackExpectation.fulfill()
      }
    }
    XCTAssertEqual(task.state, .completed, "設定エラーはタスクを即時完了する")

    wait(
      for: [argumentCallbackExpectation, onConnectCallbackExpectation],
      timeout: Self.connectNotificationTimeout)
    XCTAssertTrue(argumentHandlerCalled, "引数の handler が呼ばれること")
    XCTAssertTrue(
      onConnectObservedArgumentHandler,
      "Sora.handlers.onConnect は引数の handler より後に呼ばれること")
  }
}
