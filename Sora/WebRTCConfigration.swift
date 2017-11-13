import Foundation
import WebRTC

/**
 メディア制約を表します。
 */
public struct MediaConstraints {
    
    /// 必須の制約
    public var mandatory: [String: String] = [:]
    
    /// オプションの制約
    public var optional: [String: String] = [:]
    
    // MARK: - ネイティブ
    
    var nativeValue: RTCMediaConstraints {
        get {
            return RTCMediaConstraints(mandatoryConstraints: mandatory,
                                       optionalConstraints: optional)
        }
    }
    
}

/**
 WebRTC に関する設定です。
 */
public struct WebRTCConfiguration {
    
    // MARK: メディア制約に関する設定
    
    /// メディア制約
    public var constraints: MediaConstraints = MediaConstraints()
    
    // MARK: ICE サーバーに関する設定
    
    /// ICE サーバー情報のリスト
    public var iceServerInfos: [ICEServerInfo]
    
    /// ICE 通信ポリシー
    public var iceTransportPolicy: ICETransportPolicy = .relay

    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     */
    public init() {
        iceServerInfos = [
            ICEServerInfo(urls: [URL(string: "stun:stun.l.google.com:19302")!],
                          userName: nil,
                          credential: nil,
                          tlsSecurityPolicy: .secure)]
    }
    
    // MARK: - ネイティブ
    
    var nativeValue: RTCConfiguration {
        get {
            let config = RTCConfiguration()
            config.iceServers = iceServerInfos.map { info in
                return info.nativeValue
            }
            config.iceTransportPolicy = iceTransportPolicy.nativeValue
            return config
        }
    }
    
    var nativeConstraints: RTCMediaConstraints {
        get { return constraints.nativeValue }
    }
    
}
