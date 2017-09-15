import Foundation
import WebRTC
import Unbox

public class Message {
    
    public enum MessageType: String {
        case connect = "connect"
        case offer = "offer"
        case answer = "answer"
        case candidate = "candidate"
        case ping = "ping"
        case pong = "pong"
        case notify = "notify"
        case update = "update"
        case snapshot = "snapshot"
    }
    
    public var type: MessageType?
    public var data: [String: Any]
    
    public init(type: MessageType, data: [String: Any] = [:]) {
        self.type = type
        self.data = data
    }
    
    static func fromJSONData(_ data: Any) -> Message? {
        let base: Data!
        if data is Data {
            base = data as? Data
        } else if let data = data as? String {
            if let data = data.data(using: String.Encoding.utf8) {
                base = data
            } else {
                return nil
            }
        } else {
            return nil
        }
        
        do {
            let j = try JSONSerialization.jsonObject(with: base, options: JSONSerialization.ReadingOptions(rawValue: 0))
            return fromJSONObject(j as Any)
        } catch _ {
            return nil
        }
    }
    
    static func fromJSONObject(_ j: Any) -> Message? {
        if let j = j as? [String: Any] {
            if let type = j["type"] as? String {
                if let type = MessageType(rawValue: type) {
                    return Message(type: type, data: j)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    func JSON() -> [String: Any] {
        var json: [String: Any] = self.data
        json["type"] = type?.rawValue
        return json
    }
    
    func JSONRepresentation() -> String {
        let j = JSON()
        let data = try! JSONSerialization.data(withJSONObject: j,
                                               options:
            JSONSerialization.WritingOptions(rawValue: 0))
        return NSString(data: data,
                        encoding: String.Encoding.utf8.rawValue) as String!
    }
    
    public var description: String {
        get { return JSONRepresentation() }
    }
    
}

extension Message : Messageable {
    
    public func message() -> Message {
        return self
    }

}

public protocol Messageable {

    func message() -> Message
    
}

protocol JSONEncodable {
    
    func encode() -> Any
    
}

enum Enable<T: JSONEncodable>: JSONEncodable {
    
    case `default`(T)
    case enable(T)
    case disable
    
    func encode() -> Any {
        switch self {
        case .default(let value):
            return value.encode()
        case .enable(let value):
            return value.encode()
        case .disable:
            return "false" as Any
        }
    }
    
}

extension Role: JSONEncodable {
    
    func encode() -> Any {
        switch self {
        case .publisher:
            return "upstream" as Any
        case .subscriber:
            return "downstream" as Any
        }
    }
    
}

enum SignalingVideoCodec: String, UnboxableEnum {
    
    case VP8 = "VP8"
    case VP9 = "VP9"
    case H264 = "H264"
    
}

enum SignalingAudioCodec: String, UnboxableEnum {
    
    case Opus = "OPUS"
    case PCMU = "PCMU"
    
}

struct SignalingVideo {
    
    var bit_rate: Int?
    var codec_type: SignalingVideoCodec?
    
}

extension SignalingVideo: JSONEncodable {
    
    func encode() -> Any {
        var data: [String: Any] = [:]
        if let codec_type = codec_type {
            data["codec_type"] = codec_type.rawValue
        }
        if let value = bit_rate {
            data["bit_rate"] = value.description
        }
        return data as Any
    }
    
}

struct SignalingAudio {
    
    var codec_type: SignalingAudioCodec?
    
}

extension SignalingAudio: JSONEncodable {
    
    func encode() -> Any {
        var data: [String: Any] = [:]
        if let codec_type = codec_type {
            data["codec_type"] = codec_type.rawValue
        }
        return data as Any!
    }
    
}

struct SignalingConnect {
    
    var role: Role
    var channel_id: String
    var metadata: String?
    var mediaOption: MediaOption
    var multistream: Bool
    
    init(role: Role, channel_id: String, metadata: String? = nil,
         multistream: Bool = false, mediaOption: MediaOption) {
        self.role = role
        self.channel_id = channel_id
        self.metadata = metadata
        self.multistream = multistream
        self.mediaOption = mediaOption
        
        // スナップショットの設定
        if mediaOption.snapshotEnabled {
            mediaOption.videoCodec = .VP8
            mediaOption.videoEnabled = true
            mediaOption.audioEnabled = true
        }
    }

}

extension SignalingConnect: Messageable {
    
    func message() -> Message {
        var data: [String : Any] = ["role": role.encode(),
                                    "channel_id": channel_id]
        if let value = metadata {
            data["metadata"] = value
        }
        if multistream {
            data["multistream"] = true
            data["plan_b"] = true
        }
        
        if !mediaOption.videoEnabled {
            data["video"] = false
        } else {
            var video: [String: Any] = [:]
            switch mediaOption.videoCodec {
            case .default:
                break
            case .VP8:
                video["codec_type"] = SignalingVideoCodec.VP8.rawValue
            case .VP9:
                video["codec_type"] = SignalingVideoCodec.VP9.rawValue
            case .H264:
                video["codec_type"] = SignalingVideoCodec.H264.rawValue
            }
            
            if mediaOption.snapshotEnabled {
                video["snapshot"] = true
            }
            
            if let bitRate = mediaOption.bitRate {
                video["bit_rate"] = bitRate
            }
            
            if !video.isEmpty {
                data["video"] = video
            }
        }
        
        if !mediaOption.audioEnabled {
            data["audio"] = false
        } else {
            var audio: [String: Any] = [:]
            switch mediaOption.audioCodec {
            case .default:
                break
            case .Opus:
                audio["codec_type"] = SignalingAudioCodec.Opus.rawValue
            case .PCMU:
                audio["codec_type"] = SignalingAudioCodec.PCMU.rawValue
            }
            
            if !audio.isEmpty {
                data["audio"] = audio
            }
        }
        
        return Message(type: .connect, data: data as [String : Any])
    }
    
}

struct SignalingOffer {
    
    struct Configuration {
        
        struct IceServer {
            var urls: [String]
            var credential: String
            var username: String
        }
        
        var iceServers: [IceServer]
        var iceTransportPolicy: String
        
    }
    
    var client_id: String
    var sdp: String
    var config: Configuration?

    func sessionDescription() -> RTCSessionDescription {
        return RTCSessionDescription(type: RTCSdpType.offer, sdp: sdp)
    }
    
}

extension SignalingOffer: Unboxable {
    
    init(unboxer: Unboxer) throws {
        client_id = try unboxer.unbox(key: "client_id")
        sdp = try unboxer.unbox(key: "sdp")
        config = unboxer.unbox(key: "config")
    }
    
}

extension SignalingOffer.Configuration: Unboxable {
    
    init(unboxer: Unboxer) throws {
        iceServers = try unboxer.unbox(key: "iceServers")
        iceTransportPolicy = try unboxer.unbox(key: "iceTransportPolicy")
    }
    
}

extension SignalingOffer.Configuration.IceServer: Unboxable {

    init(unboxer: Unboxer) throws {
        urls = try unboxer.unbox(key: "urls")
        credential = try unboxer.unbox(key: "credential")
        username = try unboxer.unbox(key: "username")
    }
    
}

struct SignalingAnswer {
    
    var sdp: String
    
}

extension SignalingAnswer: Messageable {

    func message() -> Message {
        return Message(type: .answer, data: ["sdp": sdp as Any])
    }
    
}

extension SignalingVideo: Unboxable {
    
    init(unboxer: Unboxer) throws {
        bit_rate = unboxer.unbox(key: "bit_rate")
        codec_type = unboxer.unbox(key: "codec_type")
    }
    
}

extension SignalingAudio: Unboxable {
    
    init(unboxer: Unboxer) throws {
        codec_type = unboxer.unbox(key: "codec_type")
    }
    
}

struct SignalingICECandidate {
    
    var candidate: String
    
}

extension SignalingICECandidate: Messageable {
    
    func message() -> Message {
        return Message(type: .candidate,
                       data: ["candidate": candidate as Any])
    }
    
}

struct SignalingPong {
}

extension SignalingPong: Messageable {
    
    func message() -> Message {
        return Message(type: .pong)
    }
    
}

public enum SignalingEventType: String, UnboxableEnum {
    
    case connectionCreated = "connection.created"
    case connectionUpdated = "connection.updated"
    case connectionDestroyed = "connection.destroyed"
    
}

enum SignalingRole: String, UnboxableEnum {
    
    case upstream
    case downstream
    
    func connectionRole() -> Role {
        switch self {
        case .upstream:
            return .publisher
        case .downstream:
            return .subscriber
        }
    }
    
}

public struct SignalingNotify {
    
    public var eventType: SignalingEventType
    public var role: Role
    public var connectionTime: Int
    public var numberOfConnections: Int
    public var numberOfPublishers: Int
    public var numberOfSubscribers: Int

}

extension SignalingNotify: Unboxable {
    
    public init(unboxer: Unboxer) throws {
        eventType = try unboxer.unbox(key: "event_type")
        let sigRole: SignalingRole = try unboxer.unbox(key: "role")
        role = sigRole.connectionRole()
        connectionTime = try unboxer.unbox(key: "minutes")
        numberOfConnections = try unboxer.unbox(key: "channel_connections")
        numberOfPublishers = try unboxer.unbox(key: "channel_upstream_connections")
        numberOfSubscribers = try unboxer.unbox(key: "channel_downstream_connections")
    }
    
}

struct SignalingUpdateOffer {
    
    var sdp: String
 
    func sessionDescription() -> RTCSessionDescription {
        return RTCSessionDescription(type: RTCSdpType.offer, sdp: sdp)
    }
    
}

extension SignalingUpdateOffer: Unboxable {
    
    public init(unboxer: Unboxer) throws {
        sdp = try unboxer.unbox(key: "sdp")
    }
    
}

struct SignalingUpdateAnswer {
    
    var sdp: String
    
}

extension SignalingUpdateAnswer: Messageable {
    
    func message() -> Message {
        return Message(type: .update, data: ["sdp": sdp as Any])
    }
    
}

public struct SignalingSnapshot {
    
    public var mediaChannelId: String
    public var base64EncodedString: String
    
}

extension SignalingSnapshot: Unboxable {
    
    public init(unboxer: Unboxer) throws {
        mediaChannelId = try unboxer.unbox(key: "channel_id")
        base64EncodedString = try unboxer.unbox(key: "base64ed_webp")
    }
    
}
