import Foundation
import WebRTC

/// :nodoc:
public class Dummy {}

/// :nodoc:
public struct SDKInfo {
    
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
            return Bundle.module
        #else
            return Bundle(for: Dummy.self)
        #endif
    }
    
    static func load() -> SDKInfo {
        let url = SDKInfo.bundle.url(forResource: "info", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try! decoder.decode(SDKInfo.self, from: data)
    }
    
    public static let shared: SDKInfo = load()

    public var version: String? {
        return SDKInfo.bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    
    public let branch: String
    
    public let revision: String
    
    public var shortRevision: String {
        return String(revision[revision.startIndex..<revision.index(
            revision.startIndex, offsetBy: 7)])
    }
    
}

/// :nodoc:
extension SDKInfo: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case branch = "branch"
        case revision = "revision"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.branch = try container.decode(String.self, forKey: .branch)
        self.revision = try container.decode(String.self, forKey: .revision)
    }
    
}

