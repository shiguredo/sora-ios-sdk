import Foundation

public class Event {
    
    public enum EventType: String {
        case WebSocket
        case Signaling
        case PeerConnection
        case ConnectionMonitor
        case MediaPublisher
        case MediaSubscriber
        case MediaStream
        case VideoRenderer
        case VideoView
    }
    
    public enum Marker {
        case Atomic
        case Start
        case End
    }
    
    public var URL: URL
    public var mediaChannelId: String
    public var type: EventType
    public var comment: String
    public var date: Date
    
    public init(URL: URL,
                mediaChannelId: String,
                type: EventType,
                comment: String,
                date: Date = Date()) {
        self.URL = URL
        self.mediaChannelId = mediaChannelId
        self.type = type
        self.comment = comment
        self.date = date
    }
    
    public var description: String {
        get {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let desc = String(format: "[%@ %@ %@] %@: %@",
                              URL.absoluteString,
                              mediaChannelId,
                              formatter.string(from: date),
                              type.rawValue, comment)
            return desc
        }
    }
    
}

public class EventLog {
    
    public var URL: URL
    public var mediaChannelId: String
    public var events: [Event] = []
    public var isEnabled: Bool = true
    public var limit: Int? = nil
    public var debugMode: Bool = false
    
    public static var globalDebugMode: Bool = false
    
    init(URL: URL, mediaChannelId: String) {
        self.URL = URL
        self.mediaChannelId = mediaChannelId
    }
    
    public func clear() {
        events = []
    }
    
    public func mark(event: Event) {
        if isEnabled {
            if EventLog.globalDebugMode || debugMode {
                print(event.description)
            }
            if let limit = limit {
                if limit < events.count {
                    events.removeFirst()
                }
            }
            events.append(event)
            onMarkHandler?(event)
        }
    }
    
    public func markFormat(type: Event.EventType,
                           format: String,
                           arguments: CVarArg...) {
        let comment = String(format: format, arguments: arguments)
        let event = Event(URL: URL, mediaChannelId: mediaChannelId,
                          type: type, comment: comment)
        mark(event: event)
    }
    
    var onMarkHandler: ((Event) -> Void)?
    
    public func onMark(handler: @escaping (Event) -> Void) {
        onMarkHandler = handler
    }

}
