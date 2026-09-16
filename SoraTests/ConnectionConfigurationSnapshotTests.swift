import AVFoundation
import XCTest

@testable import Sora

/// 参照型のメタデータ
///
/// connection 開始後に in-place で変更しても snapshot が影響を受けないことを確認する。
private final class MutableMetadata: Encodable {
  var value: Int

  init(value: Int) {
    self.value = value
  }

  private enum CodingKeys: String, CodingKey {
    case value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(value, forKey: .value)
  }
}

/// `null` を encode するメタデータ
private struct NullMetadata: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encodeNil()
  }
}

/// keyed container に何も書かないメタデータ
///
/// `SignalingConnect.encode(to:)` は `superEncoder` で子コンテナを作ってから値を
/// encode するため、何も書かない `Encodable` は `{}` として出力される。変換が同じ結果に
/// なることを確認するために使う。
private struct EmptyMetadata: Encodable {
  func encode(to encoder: Encoder) throws {}
}

/// 単一の値を包むテスト用の Encodable
private struct ValueBox<Value: Encodable>: Encodable {
  let v: Value
}

/// JSON 化できない `dataChannels` の入力一覧
///
/// 変換の単体テストと `MediaChannel` 経由の検証テストで同じ入力を使うため、ここに置く。
/// `SoraTests` の他のテストファイルからも使うため internal とする。
///
/// `[(String, Any)]` は `Sendable` ではないため Swift 6 言語モードではグローバル / static な
/// 値として保持できない。そのため定数ではなく関数とする。
func invalidDataChannelsInputs() -> [(label: String, value: Any)] {
  [
    ("Data", Data([0x01])),
    ("Date", Date()),
    ("Set", Set([1, 2])),
    ("URL", URL(string: "https://example.com")!),
    ("非 String キーの辞書", [1: "a"] as [Int: Any]),
    ("Double.nan", Double.nan),
    ("Double.infinity", Double.infinity),
    ("Decimal.quietNaN", Decimal.quietNaN),
    ("入れ子の NaN", ["a": Double.nan] as [String: Any]),
  ]
}

/// 接続設定の snapshot と `JSONValue` への変換のテスト
///
/// snapshot が接続開始時の値を凍結すること、`JSONValue` への変換が現行の signaling JSON と
/// 同じ値になることを検証する。
final class ConnectionConfigurationSnapshotTests: XCTestCase {
  // テスト用の Configuration を構築する
  private func makeConfiguration(role: Role = .sendrecv) -> Configuration {
    Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: role)
  }

  // snapshot から PeerChannel を構築する
  //
  // connect JSON の生成と、変更前の経路を再現するテストの両方で使う。
  private func makePeerChannel(snapshot: ConnectionConfigurationSnapshot) throws -> PeerChannel {
    let signalingChannel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: WebSocketChannelHandlers())
    let nativeFactory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
  }

  // snapshot から connect JSON を生成する
  private func connectData(from snapshot: ConnectionConfigurationSnapshot) throws -> Data {
    let peerChannel = try makePeerChannel(snapshot: snapshot)
    let connect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    return try JSONEncoder().encode(Signaling.connect(connect))
  }

  // Configuration から直接 connect JSON を生成する
  private func connectData(from configuration: Configuration) throws -> Data {
    try connectData(from: ConnectionConfigurationSnapshot(configuration: configuration))
  }

  // 変更前の SignalingChannel.send の data_channels マージ処理を再現する
  private func legacyConnectData(
    _ connect: SignalingConnect,
    dataChannels: Any
  ) throws -> Data {
    let data = try JSONEncoder().encode(Signaling.connect(connect))
    guard var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SoraError.configurationError(reason: "test: connect message is not an object")
    }
    jsonObject["data_channels"] = dataChannels
    return try JSONSerialization.data(withJSONObject: jsonObject)
  }

  // connect JSON の指定キーの部分木を、キー順を正規化した文字列で返す
  //
  // JSONSerialization を通すと Double の精度で表現できない Decimal が壊れるため、
  // JSONDecoder で JSONValue へ読み直してから encode する。`JSONValue.object` は
  // `Dictionary` のため順序を持たず、複数キーのゴールデンは `.sortedKeys` で正規化する。
  private func subtree(_ data: Data, key: String) throws -> String? {
    guard let value = try jsonValue(data, key: key) else {
      return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: try encoder.encode(ValueBox(v: value)), encoding: .utf8)
  }

  // connect JSON の指定キーの値を JSONValue として返す
  private func jsonValue(_ data: Data, key: String) throws -> JSONValue? {
    try JSONDecoder().decode([String: JSONValue].self, from: data)[key]
  }

  /// 参照型のメタデータを in-place で変更しても snapshot と送信 JSON が変化しないことを確認する
  func testReferenceTypeMetadataIsFrozen() throws {
    var configuration = makeConfiguration()
    let metadata = MutableMetadata(value: 1)
    configuration.signalingConnectMetadata = metadata

    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
    let before = try connectData(from: snapshot)

    // value type の property 再代入は元々接続側へ伝播しない
    configuration.channelId = "changed"
    // reference type の in-place 変更は snapshot の凍結対象
    metadata.value = 2

    let after = try connectData(from: snapshot)
    XCTAssertEqual(
      try subtree(before, key: "metadata"), try subtree(after, key: "metadata"),
      "snapshot 生成後に元のメタデータを変更しても送信 JSON は変化しない")
    XCTAssertEqual(
      try subtree(after, key: "metadata"), "{\"v\":{\"value\":1}}",
      "snapshot は接続開始時の値を保持する")
  }

  /// metadata が nil のときはキーを出力せず、null を encode する値は null を出力することを確認する
  func testMetadataNilAndNull() throws {
    var configuration = makeConfiguration()
    XCTAssertNil(
      try subtree(try connectData(from: configuration), key: "metadata"),
      "metadata が nil のときはキーを出力しない")

    configuration.signalingConnectMetadata = NullMetadata()
    XCTAssertEqual(
      try subtree(try connectData(from: configuration), key: "metadata"), "{\"v\":null}",
      "null を encode する metadata は null を出力する")
  }

  /// dataChannels が非 nil のとき metadata の Decimal が利用者入力どおりになることを確認する
  ///
  /// 変更前は connect message 全体を JSONSerialization で再直列化していたため、
  /// Double の精度で表現できない Decimal の値が壊れていた。
  func testMetadataDecimalIsPreservedWhenDataChannelsIsSet() throws {
    struct Metadata: Encodable {
      let value: Decimal
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectMetadata = Metadata(
      value: Decimal(string: "1.0000000000000001")!)
    configuration.dataChannels = ["x": 1]

    let data = try connectData(from: configuration)
    XCTAssertEqual(
      try subtree(data, key: "metadata"), "{\"v\":{\"value\":1.0000000000000001}}",
      "Decimal の値が壊れない")

    // 変更前の経路では値が壊れることを記録しておく
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
    let peerChannel = try makePeerChannel(snapshot: snapshot)
    var legacyConnect = peerChannel.makeSignalingConnect(sdp: nil, redirect: nil)
    legacyConnect.metadata = configuration.signalingConnectMetadata
    let legacyData = try legacyConnectData(legacyConnect, dataChannels: ["x": 1])
    XCTAssertEqual(
      try subtree(legacyData, key: "metadata"), "{\"v\":{\"value\":1}}",
      "変更前の経路では Decimal の値が壊れていた")
  }

  /// dataChannels の受理と出力が変更前の経路と同じ値になることを確認する
  func testDataChannelsMatchesLegacyPath() throws {
    let snapshotInputs: [(String, Any)] = [
      ("Bool", true),
      ("Int8(1)", Int8(1)),
      ("UInt8.max", UInt8.max),
      ("UInt64.max", UInt64.max),
      ("Int64.max", Int64.max),
      ("Float(0.1)", Float(0.1)),
      ("Double(0.1)", Double(0.1)),
      ("Decimal 17 桁", Decimal(string: "1.0000000000000001")!),
      ("Decimal 21 桁", Decimal(string: "12345678901234567890.5")!),
      ("Substring", "abc" as Substring),
      ("Optional.none", Optional<String>.none as Any),
      ("NSNull", NSNull()),
      ("入れ子", ["a": [1, "x", NSNull()]] as [String: Any]),
    ]

    for (label, value) in snapshotInputs {
      var configuration = makeConfiguration()
      configuration.dataChannels = value
      let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
      let data = try connectData(from: snapshot)
      let peerChannel = try makePeerChannel(snapshot: snapshot)
      let legacyData = try legacyConnectData(
        peerChannel.makeSignalingConnect(sdp: nil, redirect: nil), dataChannels: value)

      XCTAssertEqual(
        try subtree(data, key: "data_channels"),
        try subtree(legacyData, key: "data_channels"),
        "\(label) の data_channels が変更前の経路と同じになる")
    }
  }

  /// dataChannels の指数表記は表記が変わっても同じ値になることを確認する
  func testDataChannelsExponentNotationKeepsValue() throws {
    var configuration = makeConfiguration()
    configuration.dataChannels = Double(1e-07)
    let data = try connectData(from: configuration)

    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
    let peerChannel = try makePeerChannel(snapshot: snapshot)
    let legacyData = try legacyConnectData(
      peerChannel.makeSignalingConnect(sdp: nil, redirect: nil), dataChannels: Double(1e-07))

    // 指数表記は展開される (生の JSON で表記を固定する)
    let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(
      raw.contains("0.000000099999999999999995"),
      "指数表記の data_channels は展開される: \(raw)")
    XCTAssertEqual(
      try jsonValue(data, key: "data_channels"),
      try jsonValue(legacyData, key: "data_channels"),
      "指数表記が変わっても値は同じ")
  }

  /// dataChannels の NSNull が null として出力されることを確認する
  func testDataChannelsNullIsSent() throws {
    var configuration = makeConfiguration()
    configuration.dataChannels = NSNull()
    let data = try connectData(from: configuration)
    XCTAssertEqual(try subtree(data, key: "data_channels"), "{\"v\":null}")
  }

  /// JSON 化できない dataChannels がプロセスを abort させず configurationError になることを確認する
  func testInvalidDataChannelsThrowsConfigurationError() throws {
    // 入力一覧は `ConnectConfigurationValidationTests` の拒否テストと共通
    for (label, value) in invalidDataChannelsInputs() {
      var configuration = makeConfiguration()
      configuration.dataChannels = value
      XCTAssertThrowsError(
        try ConnectionConfigurationSnapshot(configuration: configuration), label
      ) { error in
        guard case SoraError.configurationError(let reason) = error else {
          XCTFail("\(label): SoraError.configurationError が返ること: \(error)")
          return
        }
        XCTAssertEqual(reason, "data channels are not JSON-serializable", label)
      }
    }
  }

  /// 非有限値の metadata が configurationError になることを確認する
  func testInvalidMetadataThrowsConfigurationError() throws {
    struct Metadata: Encodable {
      let value: Double
    }
    struct DecimalMetadata: Encodable {
      let value: Decimal
    }

    var doubleNaN = makeConfiguration()
    doubleNaN.signalingConnectMetadata = Metadata(value: .nan)
    XCTAssertThrowsError(try ConnectionConfigurationSnapshot(configuration: doubleNaN)) { error in
      guard case SoraError.configurationError(let reason) = error else {
        XCTFail("SoraError.configurationError が返ること: \(error)")
        return
      }
      XCTAssertEqual(reason, "signaling connect metadata could not be encoded")
    }

    // Decimal の NaN は JSONEncoder が throw せず不正な JSON を出力するため、
    // 変換では decode の失敗として検出する
    var decimalNaN = makeConfiguration()
    decimalNaN.signalingConnectMetadata = DecimalMetadata(value: .quietNaN)
    XCTAssertThrowsError(try ConnectionConfigurationSnapshot(configuration: decimalNaN)) {
      error in
      guard case SoraError.configurationError(let reason) = error else {
        XCTFail("SoraError.configurationError が返ること: \(error)")
        return
      }
      XCTAssertEqual(reason, "signaling connect metadata could not be encoded")
    }
  }

  /// codec 別 params が connect message に載る条件を満たすときだけ保持されることを確認する
  func testCodecParamsFollowEncodeConditions() throws {
    struct Params: Encodable {
      let value: Int
    }

    // videoCodec が一致しないときは保持しない
    var otherCodec = makeConfiguration()
    otherCodec.videoCodec = .h264
    otherCodec.videoVp9Params = Params(value: 1)
    otherCodec.videoH264Params = Params(value: 2)
    let otherCodecSnapshot = try ConnectionConfigurationSnapshot(configuration: otherCodec)
    XCTAssertNil(otherCodecSnapshot.videoVp9Params)
    XCTAssertNotNil(otherCodecSnapshot.videoH264Params)

    // videoEnabled が false のときは保持しない
    var videoDisabled = makeConfiguration()
    videoDisabled.videoEnabled = false
    videoDisabled.videoCodec = .vp9
    videoDisabled.videoVp9Params = Params(value: 1)
    XCTAssertNil(
      try ConnectionConfigurationSnapshot(configuration: videoDisabled).videoVp9Params)

    // audioEnabled が false、または codec が一致しないときは保持しない
    var audioDisabled = makeConfiguration()
    audioDisabled.audioEnabled = false
    audioDisabled.audioCodec = .opus
    audioDisabled.audioOpusParams = Params(value: 1)
    XCTAssertNil(
      try ConnectionConfigurationSnapshot(configuration: audioDisabled).audioOpusParams)

    var audioOtherCodec = makeConfiguration()
    audioOtherCodec.audioCodec = .pcmu
    audioOtherCodec.audioOpusParams = Params(value: 1)
    XCTAssertNil(
      try ConnectionConfigurationSnapshot(configuration: audioOtherCodec).audioOpusParams)
  }

  /// ICE サーバーの TURN-TLS ポリシーが snapshot で維持されることを確認する
  func testICEServerSnapshotKeepsTURNTLSBehaviour() {
    let verified = ICEServerSnapshot(
      urls: ["turns:example.com"], username: "user", credential: "credential",
      isTLSInsecure: false)
    XCTAssertTrue(verified.usesVerifiedTURNTLS)
    XCTAssertEqual(verified.nativeValue(insecure: false).tlsCertPolicy, .secure)
    XCTAssertEqual(verified.nativeValue(insecure: true).tlsCertPolicy, .insecureNoCheck)

    let stunOnly = ICEServerSnapshot(
      urls: ["stun:example.com"], username: nil, credential: nil, isTLSInsecure: false)
    XCTAssertFalse(stunOnly.usesVerifiedTURNTLS)
    XCTAssertEqual(stunOnly.nativeValue(insecure: false).tlsCertPolicy, .secure)

    let insecure = ICEServerSnapshot(
      urls: ["turns:example.com"], username: nil, credential: nil, isTLSInsecure: true)
    XCTAssertFalse(insecure.usesVerifiedTURNTLS)
    XCTAssertEqual(insecure.nativeValue(insecure: false).tlsCertPolicy, .insecureNoCheck)
  }

  /// ForwardingFilter の metadata が nil と null で区別されることを確認する
  func testForwardingFilterMetadataNilAndNull() throws {
    let config = makeConfiguration()

    var nilMetadata = ForwardingFilter(rules: [])
    XCTAssertNil(try ConnectionConfigurationSnapshot(configuration: config).forwardingFilter)

    nilMetadata.metadata = NullMetadata()
    var withNull = config
    withNull.forwardingFilter = nilMetadata
    let snapshot = try ConnectionConfigurationSnapshot(configuration: withNull)
    let filter = try XCTUnwrap(snapshot.forwardingFilter)
    XCTAssertEqual(filter.metadata, .null)

    let restored = filter.forwardingFilter()
    let encoded = try JSONEncoder().encode(restored)
    XCTAssertTrue(
      String(data: encoded, encoding: .utf8)?.contains("\"metadata\":null") == true,
      "null の metadata はキー省略にならない")
  }

  /// metadata が scalar の場合と、keyed container に何も書かない場合の出力を確認する
  ///
  /// `SignalingConnect.encode(to:)` は `superEncoder` を呼んでから値を encode するため、
  /// 何も書かない `Encodable` は `{}` として出力される (キーごと省略されてはならない)。
  func testMetadataScalarAndEmptyObject() throws {
    var scalar = makeConfiguration()
    scalar.signalingConnectMetadata = 42
    XCTAssertEqual(
      try subtree(try connectData(from: scalar), key: "metadata"), "{\"v\":42}",
      "scalar の metadata はそのまま出力される")

    var empty = makeConfiguration()
    empty.signalingConnectMetadata = EmptyMetadata()
    XCTAssertEqual(
      try subtree(try connectData(from: empty), key: "metadata"), "{\"v\":{}}",
      "何も書かない Encodable は {} として出力される")
  }

  /// metadata の指数表記が展開されても値が変わらないことを確認する
  func testMetadataExponentNotationKeepsValue() throws {
    struct Metadata: Encodable {
      let value: Double
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectMetadata = Metadata(value: 1e-07)

    let data = try connectData(from: configuration)
    XCTAssertEqual(
      try subtree(data, key: "metadata"), "{\"v\":{\"value\":0.0000001}}",
      "指数表記は展開される")
    XCTAssertEqual(
      try jsonValue(data, key: "metadata"),
      .object(["value": .decimal(Decimal(string: "1e-07")!)]),
      "展開後も値は 1e-07 と同一")
  }

  /// metadata の `-0.0` は `0` になり符号が失われることを確認する
  ///
  /// 変換は数値トークンを `Decimal` として読み直すため、`Double` の `-0.0` が持つ符号は
  /// 保持されない。JSON の数値としては等価であり、意図的な変更として期待値を固定する。
  func testMetadataNegativeZeroLosesSign() throws {
    struct Metadata: Encodable {
      let value: Double
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectMetadata = Metadata(value: -0.0)

    XCTAssertEqual(
      try subtree(try connectData(from: configuration), key: "metadata"),
      "{\"v\":{\"value\":0}}",
      "-0.0 は 0 になり符号が失われる")
  }

  /// metadata の 64 bit 境界の整数が Double を経由せず精度を保つことを確認する
  func testMetadataIntegerBoundariesKeepPrecision() throws {
    struct Metadata: Encodable {
      let signed: Int64
      let unsigned: UInt64
      let byte: UInt8
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectMetadata = Metadata(
      signed: .max, unsigned: .max, byte: 1)

    XCTAssertEqual(
      try subtree(try connectData(from: configuration), key: "metadata"),
      "{\"v\":{\"byte\":1,\"signed\":9223372036854775807,\"unsigned\":18446744073709551615}}",
      "64 bit の整数はそのまま出力される")
  }

  /// signalingConnectNotifyMetadata が metadata と同じ変換で出力され、nil のときはキーを
  /// 省略することを確認する
  func testNotifyMetadataIsEncodedAndOmitted() throws {
    struct NotifyMetadata: Encodable {
      let value: Decimal
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectNotifyMetadata = NotifyMetadata(
      value: Decimal(string: "1.0000000000000001")!)

    XCTAssertEqual(
      try subtree(try connectData(from: configuration), key: "signaling_notify_metadata"),
      "{\"v\":{\"value\":1.0000000000000001}}",
      "notify metadata の Decimal は Double の精度に丸められない")

    XCTAssertNil(
      try jsonValue(
        try connectData(from: makeConfiguration()), key: "signaling_notify_metadata"),
      "notify metadata が nil のときはキーを出力しない")
  }

  /// metadata と dataChannels の Decimal が Double の精度に依存せず、利用者入力どおりに
  /// 出力されることを確認する
  func testDecimalPrecisionIsPreservedInMetadataAndDataChannels() throws {
    struct Metadata: Encodable {
      let unrepresentable: Decimal
      let exact: Decimal
    }
    var configuration = makeConfiguration()
    configuration.signalingConnectMetadata = Metadata(
      unrepresentable: Decimal(string: "9005713213483.4526")!,
      exact: Decimal(string: "0.10000000000000001")!)
    configuration.dataChannels = Decimal(string: "9005713213483.4526")!

    let data = try connectData(from: configuration)
    XCTAssertEqual(
      try subtree(data, key: "metadata"),
      "{\"v\":{\"exact\":0.10000000000000001,\"unrepresentable\":9005713213483.4526}}",
      "metadata の Decimal は利用者入力どおりに出力される")
    XCTAssertEqual(
      try subtree(data, key: "data_channels"), "{\"v\":9005713213483.4526}",
      "dataChannels の Decimal は利用者入力どおりに出力される")
  }

  /// dataChannels の Float が現行と同じ表記で出力されることを確認する
  ///
  /// `JSONSerialization` は Float を Double の精度へ広げて書くため、`Float(0.1)` は
  /// `0.10000000149011612` になる。新旧経路の等価比較だけでは両辺が同時に変わった場合に
  /// 検出できないため、期待値を文字列で固定する。
  func testDataChannelsFloatNotationIsPreserved() throws {
    var configuration = makeConfiguration()
    configuration.dataChannels = Float(0.1)

    XCTAssertEqual(
      try subtree(try connectData(from: configuration), key: "data_channels"),
      "{\"v\":0.10000000149011612}",
      "Float(0.1) は 0.10000000149011612 として出力される")
  }

  /// ForwardingFilter の metadata が nil のときキーを省略し、他のフィールドがそのまま
  /// 復元されることを確認する
  func testForwardingFilterFieldsAreRestored() throws {
    var configuration = makeConfiguration()
    configuration.forwardingFilter = ForwardingFilter(
      name: "filter",
      priority: 1,
      action: .block,
      rules: [
        [
          ForwardingFilterRule(
            field: .connectionId, operator: .isIn, values: ["connection-1"])
        ]
      ],
      version: "2025.1")
    configuration.forwardingFilters = [
      ForwardingFilter(
        name: "list-filter",
        action: .allow,
        rules: [
          [
            ForwardingFilterRule(
              field: .kind, operator: .isNotIn, values: ["spotlight"])
          ]
        ])
    ]

    let data = try connectData(from: configuration)
    XCTAssertEqual(
      try jsonValue(data, key: "forwarding_filter"),
      .object([
        "name": .string("filter"),
        "priority": .decimal(1),
        "action": .string("block"),
        "rules": .array([
          .array([
            .object([
              "field": .string("connection_id"),
              "operator": .string("is_in"),
              "values": .array([.string("connection-1")]),
            ])
          ])
        ]),
        "version": .string("2025.1"),
      ]),
      "metadata が nil のときキーを省略し、他のフィールドはそのまま復元される")
    XCTAssertEqual(
      try jsonValue(data, key: "forwarding_filters"),
      .array([
        .object([
          "name": .string("list-filter"),
          "action": .string("allow"),
          "rules": .array([
            .array([
              .object([
                "field": .string("kind"),
                "operator": .string("is_not_in"),
                "values": .array([.string("spotlight")]),
              ])
            ])
          ]),
        ])
      ]),
      "forwardingFilters も metadata を省略して復元される")
  }

  /// connect message に載らない codec 別 params は encode できなくても検証しないことを
  /// 確認する
  ///
  /// `SignalingConnect.encode(to:)` は `videoEnabled` / `audioEnabled` の分岐の内側で、
  /// かつ codec が一致するときだけ params を書く。検証条件が encode 条件より厳しいと、
  /// 現行で無視されている値が新たに configurationError になる。
  func testUnusedCodecParamsAcceptUnencodableValues() throws {
    struct Params: Encodable {
      let value: Double
    }

    // codec が一致しない params は connect message に載らない
    var otherCodec = makeConfiguration()
    otherCodec.videoCodec = .h264
    otherCodec.videoVp9Params = Params(value: .nan)
    otherCodec.audioCodec = .pcmu
    otherCodec.audioOpusParams = Params(value: .nan)
    let otherCodecSnapshot = try ConnectionConfigurationSnapshot(configuration: otherCodec)
    XCTAssertNil(otherCodecSnapshot.videoVp9Params)
    XCTAssertNil(otherCodecSnapshot.audioOpusParams)

    // videoEnabled / audioEnabled が false のときの params も connect message に載らない
    var disabled = makeConfiguration()
    disabled.videoEnabled = false
    disabled.videoCodec = .vp9
    disabled.videoVp9Params = Params(value: .nan)
    disabled.audioEnabled = false
    disabled.audioCodec = .opus
    disabled.audioOpusParams = Params(value: .nan)
    let disabledSnapshot = try ConnectionConfigurationSnapshot(configuration: disabled)
    XCTAssertNil(disabledSnapshot.videoVp9Params)
    XCTAssertNil(disabledSnapshot.audioOpusParams)
  }

  /// CameraSettings が接続開始時の値で凍結されることを確認する
  func testCameraSettingsAreFrozen() throws {
    var configuration = makeConfiguration()
    configuration.cameraSettings = CameraSettings(
      resolution: .hd1080p, frameRate: 15, position: .back, isEnabled: false)

    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)

    // value type の property 再代入は元々接続側へ伝播しない
    configuration.cameraSettings = CameraSettings()

    XCTAssertFalse(snapshot.cameraSettings.isEnabled)
    XCTAssertEqual(snapshot.cameraSettings.resolution.width, 1920)
    XCTAssertEqual(snapshot.cameraSettings.resolution.height, 1080)
    XCTAssertEqual(snapshot.cameraSettings.frameRate, 15)
    XCTAssertEqual(snapshot.cameraSettings.position, .back)
  }

  /// ICEServerInfo からの変換が TURN-TLS の検証ポリシーを写し取ることを確認する
  ///
  /// snapshot の memberwise init ではなく、production が使う `ICEServerInfo` からの変換を
  /// 検証する。insecure のフィクスチャを作るためだけに非推奨の initializer を使う。
  func testICEServerSnapshotCopiesPolicyFromICEServerInfo() {
    let verified = ICEServerSnapshot(
      ICEServerInfo(urls: ["turns:example.com"], userName: "user", credential: "credential"))
    XCTAssertFalse(verified.isTLSInsecure)
    XCTAssertTrue(verified.usesVerifiedTURNTLS)

    let insecure = ICEServerSnapshot(
      ICEServerInfo(
        urls: ["turns:example.com"],
        userName: "user",
        credential: "credential",
        tlsSecurityPolicy: .insecure))
    XCTAssertTrue(insecure.isTLSInsecure)
    XCTAssertFalse(insecure.usesVerifiedTURNTLS)
    XCTAssertEqual(insecure.nativeValue(insecure: false).tlsCertPolicy, .insecureNoCheck)
  }
}
