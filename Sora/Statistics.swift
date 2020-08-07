import Foundation
import WebRTC

/// :nodoc:
public class Statistics {
    
    public var timestamp: CFTimeInterval
    public var entries: [StatisticsEntry] = []
    
    init(contentsOf report: RTCStatisticsReport) {
        timestamp = report.timestamp_us
        for (_, statistics) in report.statistics {
            let entry = StatisticsEntry(contentsOf: statistics)
            entries.append(entry)
        }
    }
    
    public var jsonObject: Any {
        let json = NSMutableArray()
        for entry in entries {
            var map: [String: Any] = [:]
            map["id"] = entry.id
            map["type"] = entry.type
            map["timestamp"] = entry.timestamp
            map.merge(entry.values, uniquingKeysWith: { a, b in a })
            json.add(map as NSDictionary)
        }
        return json
    }

}

/// :nodoc:
public class StatisticsEntry {
    
    public var id: String
    public var type: String
    public var timestamp: CFTimeInterval
    public var values: [String: NSObject]
    
    init(contentsOf statistics: RTCStatistics) {
        id = statistics.id
        type = statistics.type
        timestamp = statistics.timestamp_us
        values = statistics.values
    }
    
}
