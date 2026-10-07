import Foundation
import WebRTC

/// WebRTC の統計情報を SDK から扱いやすい形にしたコンテナーです。
public class Statistics {
  /// 収集時刻 (μs)
  public var timestamp: CFTimeInterval

  /// 統計エントリーの一覧
  public var entries: [StatisticsEntry] = []

  init(contentsOf report: RTCStatisticsReport) {
    timestamp = report.timestamp_us
    for (_, statistics) in report.statistics {
      let entry = StatisticsEntry(contentsOf: statistics)
      entries.append(entry)
    }
  }

  /// JSON へシリアライズしやすい形式を返します。
  public var jsonObject: Any {
    let json = NSMutableArray()
    for entry in entries {
      var map: [String: Any] = [:]
      map["id"] = entry.id
      map["type"] = entry.type
      map["timestamp"] = entry.timestamp
      map.merge(entry.values, uniquingKeysWith: { a, _ in a })
      json.add(map as NSDictionary)
    }
    return json
  }
}

/// 単一の WebRTC 統計エントリーを表します。
public class StatisticsEntry {
  /// エントリー ID
  public var id: String

  /// 統計種別
  public var type: String

  /// 測定時刻 (μs)
  public var timestamp: CFTimeInterval

  /// 生の統計値
  public var values: [String: NSObject]

  init(contentsOf statistics: RTCStatistics) {
    id = statistics.id
    type = statistics.type
    timestamp = statistics.timestamp_us
    values = statistics.values
  }
}

// MARK: - snapshot

/// WebRTC の統計情報を actor / Task 境界へ渡せるようにした、immutable で deep Sendable な snapshot です。
///
/// `Statistics` と property の名前と構成を揃えていますが、値は `JSONValue` で保持するため
/// Objective-C の object graph (`NSObject` / `NSDictionary` / `NSArray` / `Any`) を含みません。
/// `Statistics.jsonObject` に相当する property は持ちません (`values` の `JSONValue` が `Encodable` の
/// ため、必要に応じて利用者が直列化します)。
/// `Statistics` の instance を写したものではなく、`RTCPeerConnection.statistics` の完了 block で
/// `RTCStatisticsReport` から直接変換します (`Statistics` を経由しません)。
/// `MediaChannel.getStatsSnapshot(handler:)` が handler へ渡し、`MediaChannel.getStatsSnapshot()` が
/// 返します。値を組み立てる public な init は持ちません (SDK が生成した値を読むための型です)。
public struct StatisticsSnapshot: Sendable {
  /// 収集時刻 (μs)
  public let timestamp: CFTimeInterval

  /// 統計エントリーの一覧
  public let entries: [StatisticsEntrySnapshot]

  /// テストから snapshot を組み立てます。
  ///
  /// SDK は ``init(contentsOf:)`` から組み立てるため、この init はテスト専用です。
  /// - parameter timestamp: 収集時刻 (μs)
  /// - parameter entries: 統計エントリーの一覧
  init(timestamp: CFTimeInterval, entries: [StatisticsEntrySnapshot]) {
    self.timestamp = timestamp
    self.entries = entries
  }

  /// `RTCStatisticsReport` から snapshot を組み立てます。
  ///
  /// `report.statistics` は辞書のため `entries` の順序は保証しません。
  /// 値の変換に失敗した場合は `SoraError.mediaChannelError(reason:)` を throw します。
  /// - parameter report: libwebrtc が返した統計レポート
  init(contentsOf report: RTCStatisticsReport) throws {
    timestamp = report.timestamp_us
    entries = try report.statistics.map { try StatisticsEntrySnapshot(contentsOf: $0.value) }
  }
}

/// 単一の WebRTC 統計エントリーを actor / Task 境界へ渡せるようにした、immutable で deep Sendable な
/// snapshot です。
///
/// `StatisticsEntry` と property の名前を揃え、`values` だけを `[String: JSONValue]` に変えています。
public struct StatisticsEntrySnapshot: Sendable {
  /// エントリー ID
  public let id: String

  /// 統計種別
  public let type: String

  /// 測定時刻 (μs)
  public let timestamp: CFTimeInterval

  /// 生の統計値
  public let values: [String: JSONValue]

  /// テストから entry を組み立てます。
  ///
  /// SDK は ``init(contentsOf:)`` から組み立てるため、この init はテスト専用です。
  /// - parameter id: エントリー ID
  /// - parameter type: 統計種別
  /// - parameter timestamp: 測定時刻 (μs)
  /// - parameter values: 生の統計値
  init(id: String, type: String, timestamp: CFTimeInterval, values: [String: JSONValue]) {
    self.id = id
    self.type = type
    self.timestamp = timestamp
    self.values = values
  }

  /// `RTCStatistics` から entry を組み立てます。
  ///
  /// 値の変換に失敗した場合は `SoraError.mediaChannelError(reason:)` を throw します。
  /// - parameter statistics: libwebrtc が返した統計エントリー
  init(contentsOf statistics: RTCStatistics) throws {
    id = statistics.id
    type = statistics.type
    timestamp = statistics.timestamp_us
    values = try Self.jsonValues(from: statistics.values)
  }

  /// libwebrtc が返した `[String: NSObject]` の統計値を `JSONValue` へ変換します。
  ///
  /// 変換は `JSONValue.fromJSONSerializationValue(_:)` へ委譲します。この関数は
  /// `JSONSerialization.isValidJSONObject` で直列化の前に検証するため、`Date` や `-inf` の
  /// `NSNumber` のように `JSONSerialization` が JSON として受理しない値を渡しても、捕捉できない
  /// NSException でプロセスを終了させず捕捉可能な error として扱えます。同じ検証を省いて
  /// `JSONSerialization.data(withJSONObject:)` を直接呼ばないこと。
  ///
  /// 変換できない値を含む場合は該当の値を silent drop せず、呼び出し全体を
  /// `SoraError.mediaChannelError(reason:)` として失敗させます。
  /// - parameter values: libwebrtc が返した統計値
  static func jsonValues(from values: [String: NSObject]) throws -> [String: JSONValue] {
    let converted: JSONValue
    do {
      converted = try JSONValue.fromJSONSerializationValue(values)
    } catch {
      throw SoraError.mediaChannelError(reason: "statistics values are not JSON values")
    }
    guard case .object(let object) = converted else {
      // 辞書を渡しているため `fromJSONSerializationValue(_:)` は必ず `.object` を返すが、case の
      // 取り出しには分岐が必要なため、到達しても成功として扱わない (`JSONValue` 側の同型の防御と
      // 同じ考え方)。
      throw SoraError.mediaChannelError(reason: "statistics values are not a JSON object")
    }
    return object
  }
}
