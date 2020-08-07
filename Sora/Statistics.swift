import Foundation
import WebRTC

private extension NSObject {
    
    var rtcStringValue: String? {
        self as? String
    }
    
    var rtcUint32Value: UInt32? {
        (self as? NSNumber)?.uint32Value
    }
    
    var rtcDoubleValue: Double? {
        (self as? NSNumber)?.doubleValue
    }
    
    var rtcListValue: [String]? {
        guard let list = self as? NSArray else {
            return nil
        }
        var values: [String] = []
        for value in list {
            guard let value = value as? String else {
                return nil
            }
            values.append(value)
        }
        return values
    }
    
}

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

/*
extension Statistics: Encodable {
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(["a":"b"], forKey: .a)
    }
    
}


extension StatisticsEntry: Encodable {
    
    enum CodingKeys: CodingKey {
        case a
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(["a":"b"], forKey: .a)
    }
    
}
*/
