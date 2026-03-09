import Foundation
import WebRTC

private let tlsSecurityPolicyTable: [TLSSecurityPolicy: RTCTlsCertPolicy] =
  [.secure: .secure, .insecure: .insecureNoCheck]

/// TLS のセキュリティポリシーを表します。
public enum TLSSecurityPolicy: Sendable {
  /// サーバー証明書を確認します。
  case secure

  /// サーバー証明書を確認しません。
  case insecure

  var nativeValue: RTCTlsCertPolicy {
    tlsSecurityPolicyTable[self]!
  }
}
