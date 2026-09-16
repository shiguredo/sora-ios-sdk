import Foundation

/// JSON の値を表す internal な値型です。
///
/// `Configuration` が保持する `Encodable` や `Any` の値を接続開始時に写し取り、
/// 接続開始後に利用者所有の可変値を参照しないようにするために使います。
///
/// `Decimal` を `Double` より先に判定するため、整数と小数を `Decimal` の精度で保ちます。
enum JSONValue: Sendable, Equatable {
  /// null
  case null

  /// bool
  case bool(Bool)

  /// 小数
  ///
  /// 整数トークンも `Decimal` として読むため、`Int64` / `UInt64` の case は持たない
  /// (`Decimal` は 38 桁の仮数を持ち、`UInt64.max` の 20 桁を含む)。
  case decimal(Decimal)

  /// 浮動小数
  case double(Double)

  /// 文字列
  case string(String)

  /// 配列
  case array([JSONValue])

  /// 辞書
  case object([String: JSONValue])
}

/// :nodoc:
extension JSONValue: Encodable {
  /// `singleValueContainer` へ書きます。
  ///
  /// `keyedContainer` を作ると `SignalingConnect.encode(to:)` の `superEncoder` と
  /// 二重のコンテナになり `"metadata": {"metadata": ...}` のようになるため、
  /// `singleValueContainer` を使います。
  func encode(to encoder: Encoder) throws {
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

/// :nodoc:
extension JSONValue: Decodable {
  /// JSON のトークンを `JSONValue` へ読み込みます。
  ///
  /// `Double` より先に `Decimal` を試すことで数値トークンの精度を保ちます。
  /// `Decimal` が表現できない指数の値は `Double` へ落ちます。
  init(from decoder: Decoder) throws {
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
private enum JSONValueKey: String, CodingKey {
  case value
  case dataChannels = "data_channels"
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
  /// 自前の型判定で再実装しません。`data_channels` を代入した辞書を経由するので、
  /// 取り出した内側の値を返します。
  /// - parameter value: 変換する値
  /// - parameter errorReason: 変換に失敗したときの `SoraError.configurationError` の理由
  static func fromDataChannels(_ value: Any, errorReason: String) throws -> JSONValue {
    let object: [String: Any] = [JSONValueKey.dataChannels.rawValue: value]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw SoraError.configurationError(reason: errorReason)
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: object)
    } catch {
      throw SoraError.configurationError(reason: errorReason)
    }
    do {
      let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
      guard let converted = decoded[JSONValueKey.dataChannels.rawValue] else {
        throw SoraError.configurationError(reason: errorReason)
      }
      return converted
    } catch {
      throw SoraError.configurationError(reason: errorReason)
    }
  }
}
