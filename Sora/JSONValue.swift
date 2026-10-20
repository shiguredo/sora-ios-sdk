import Foundation

/// JSON の値を表す値型です。
///
/// 接続設定の snapshot と RPC のエラー詳細が、`Encodable` の値や `JSONSerialization` が返した
/// 値をそのまま保持しないようにするために使います。`Sendable` な値だけで構成されるため、
/// actor / Task 境界を越えて受け渡せます。
///
/// 数値の復元は変換の経路で変わります。`init(from:)` は `Decimal` を `Double` より先に判定する
/// ため JSON の数値トークンの精度を保ちます。`JSONSerialization` を通る経路
/// (`RPCErrorDetail.data` など) は `NSNumber` を経由するため、小数は `Double` の値が
/// `Decimal` として入ります (実測では `0.1` が `.decimal(0.10000000000000001)` になります)。
/// `Decimal` が表現できる範囲を超える指数の値 (`1e300` など) だけが `.double` になります。
///
/// `Equatable` は case 込みで比較するため、`.decimal(1)` と `.double(1.0)` は等しくありません。
/// `encode(to:)` した値を `init(from:)` で戻すと `.double(1.0)` は `.decimal(1)` になるため、
/// encode と decode は対称ではありません。NaN (`.decimal(Decimal.nan)` / `.double(.nan)`) は
/// 自分自身とも等しくなりません。
public enum JSONValue: Sendable, Equatable {
  /// null
  case null

  /// bool
  case bool(Bool)

  /// 整数または小数
  ///
  /// 整数トークンも `Decimal` として読むため、`Int64` / `UInt64` の case は持ちません。
  /// (`Decimal` は 38 桁の仮数を持ち、`UInt64.max` の 20 桁を含みます)。
  case decimal(Decimal)

  /// `Decimal` が表現できる範囲を超える指数の値です。
  case double(Double)

  /// 文字列
  case string(String)

  /// 配列
  case array([JSONValue])

  /// 辞書
  case object([String: JSONValue])
}

extension JSONValue: Encodable {
  /// `singleValueContainer` へ書きます。
  ///
  /// `keyedContainer` を作ると `SignalingConnect.encode(to:)` の `superEncoder` と
  /// 二重のコンテナになり `"metadata": {"metadata": ...}` のようになるため、
  /// `singleValueContainer` を使います。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .decimal(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension JSONValue: Decodable {
  /// JSON のトークンを `JSONValue` へ読み込みます。
  ///
  /// `Double` より先に `Decimal` を試すことで数値トークンの精度を保ちます。
  /// `Decimal` が表現できない指数の値は `Double` へ落ちます。
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    if let value = try? container.decode(Decimal.self) {
      self = .decimal(value)
      return
    }
    if let value = try? container.decode(Double.self) {
      self = .double(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
      return
    }
    if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
      return
    }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "unsupported JSON value"))
  }
}

// MARK: 変換

/// `JSONValue` の変換で使うキーです。
///
/// トップレベルの断片 (文字列・数値・bool・null) を `JSONSerialization` で直列化するために、
/// 値はこの key を持つ辞書へ包んでから扱います。
private enum JSONValueKey: String, CodingKey {
  case value
}

/// `Encodable` の値を keyed container へ入れて encode するためのラッパーです。
///
/// `SignalingConnect.encode(to:)` は metadata などを `superEncoder` 経由で
/// 入れ子のコンテナへ書くため、トップレベルに何も書かない `Encodable` は `{}` に
/// なります。同じ結果にするため、変換でも keyed container へ入れてから encode します
/// (トップレベルに直接 encode すると失敗します)。
private struct JSONValueBox: Encodable {
  let value: Encodable

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: JSONValueKey.self)
    try container.encode(value, forKey: .value)
  }
}

extension JSONValue {
  /// `Encodable` の値を `JSONValue` へ変換します。
  ///
  /// `JSONEncoder` で JSON にしたあと `JSONDecoder` で読み直すため、値は接続開始時に
  /// 確定します。`JSONSerialization.jsonObject` は `Decimal` を `NSNumber` (Double) として
  /// 返して Double の精度で表現できない値が変わるため、変換には使いません。
  ///
  /// encode 済みの `Data` を保持して送信時に `superEncoder` へ渡す案は採りません。
  /// `Data` は base64 文字列として JSON に載るため、signaling JSON が壊れます。
  /// - parameter value: 変換する値
  /// - parameter errorReason: 変換に失敗したときの `SoraError.configurationError` の理由
  static func from(_ value: Encodable, errorReason: String) throws -> JSONValue {
    let data: Data
    do {
      data = try JSONEncoder().encode(JSONValueBox(value: value))
    } catch {
      throw SoraError.configurationError(reason: errorReason)
    }
    do {
      let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
      guard let converted = object[JSONValueKey.value.rawValue] else {
        throw SoraError.configurationError(reason: errorReason)
      }
      return converted
    } catch {
      throw SoraError.configurationError(reason: errorReason)
    }
  }

  /// `dataChannels` のような `Any` の値を `JSONValue` へ変換します。
  ///
  /// `JSONSerialization` が受理する型 (`String` / `Substring` / `NSNull` / `NSNumber` /
  /// `NSDecimalNumber` / `Optional.none` / 配列 / 辞書) をそのまま扱うため、受理条件を
  /// 自前の型判定で再実装しません。変換は `fromJSONSerializationValue(_:)` に委ね、
  /// 失敗を `SoraError.configurationError` へ写します。
  /// - parameter value: 変換する値
  /// - parameter errorReason: 変換に失敗したときの `SoraError.configurationError` の理由
  static func fromDataChannels(_ value: Any, errorReason: String) throws -> JSONValue {
    do {
      return try fromJSONSerializationValue(value)
    } catch {
      throw SoraError.configurationError(reason: errorReason)
    }
  }

  /// `JSONSerialization` が返した値を `JSONValue` へ変換します。
  ///
  /// 値がトップレベルで文字列・数値・bool・null の場合でも直列化できるよう、
  /// `JSONValueKey.value` の key を持つ辞書へ包んでから `JSONSerialization` へ渡します
  /// (`JSONSerialization.isValidJSONObject` はトップレベルの断片に対して false を返すため、
  /// 包まずに検証すると弾かれます)。
  ///
  /// `JSONSerialization.data(withJSONObject:)` は JSON にできない値 (`Date` など) や、
  /// JSON の数値として表現できない値 (`{"data": -1e999}` を `JSONSerialization.jsonObject` が
  /// `NSNumber` の `-inf` として返した場合など) を渡すと、捕捉できない NSException を送出して
  /// プロセスを終了させるため、直列化の前に `isValidJSONObject` で検証します。この検証で
  /// 弾かれた値には `EncodingError.invalidValue` を投げ、`JSONSerialization` と `JSONDecoder` が
  /// 投げた error はそのまま伝播させます (SDK 固有のエラー写像を持ち込みません)。
  /// - parameter value: 変換する値
  static func fromJSONSerializationValue(_ value: Any) throws -> JSONValue {
    let object: [String: Any] = [JSONValueKey.value.rawValue: value]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(
          codingPath: [],
          debugDescription: "the value is not a JSON value"))
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
    // 包んだ key は必ず存在するが、取り出しの失敗を force unwrap で握り潰さない
    guard let converted = decoded[JSONValueKey.value.rawValue] else {
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(
          codingPath: [],
          debugDescription: "the converted value is missing"))
    }
    return converted
  }
}
