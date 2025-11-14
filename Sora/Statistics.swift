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
