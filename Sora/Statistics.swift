import Foundation
import WebRTC

/// :nodoc:
public class Statistics {
    
    public var timestamp: CFTimeInterval
    public var entries: [RTCLegacyStatsReport] = []
    
    init(contentsOf report: RTCLegacyStatsReport) {
        timestamp = report.timestamp
        entries.append(report)
    }
    
    public var jsonObject: Any {
        let json = NSMutableArray()
        for entry in entries {
            var map: [String: Any] = [:]
            map["id"] = entry.reportId
            map["type"] = entry.type
            map["timestamp"] = entry.timestamp
            map.merge(entry.values, uniquingKeysWith: { a, b in a })
            json.add(map as NSDictionary)
        }
        return json
    }

}
