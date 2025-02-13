import Foundation
import WebRTC

/// ICE Candidate を表します。
public final class ICECandidate: Equatable {
  // MARK: 比較
  /// オブジェクト同士を比較します。
  /// 双方の URL と SDP 文字列が等しければ ``true`` を返します。
  public static func == (lhs: ICECandidate, rhs: ICECandidate) -> Bool {
    lhs.url == rhs.url && lhs.sdp == rhs.sdp
  }
  // MARK: プロパティ
  /// URL
  public var url: URL?
  /// SDP 文字列
  public var sdp: String
  // MARK: 初期化
  /// 初期化します。
  public init(url: URL?, sdp: String) {
    self.url = url
    self.sdp = sdp
  }
  init(nativeICECandidate: RTCIceCandidate) {
    if let urlStr = nativeICECandidate.serverUrl {
      url = URL(string: urlStr)
    }
    sdp = nativeICECandidate.sdp
  }
}

/// :nodoc:
extension ICECandidate: Codable {
  public convenience init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let sdp = try container.decode(String.self)
    self.init(url: nil, sdp: sdp)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(sdp)
  }
}
