import Foundation
import WebRTC

private let tlsSecurityPolicyTable: [TLSSecurityPolicy: RTCTlsCertPolicy] =
  [.secure: .secure, .insecure: .insecureNoCheck]

/// TLS のセキュリティポリシーを表します。
@available(*, deprecated, message: "2027 年中に廃止予定です。Configuration.insecure を使用してください")
public enum TLSSecurityPolicy: Sendable {
  /// サーバー証明書を確認します。
  @available(*, deprecated, message: "2027 年中に廃止予定です。Configuration.insecure のデフォルト値 false と同等です")
  case secure

  /// サーバー証明書を確認しません。
  @available(*, deprecated, message: "2027 年中に廃止予定です。Configuration.insecure = true を使用してください")
  case insecure

  var nativeValue: RTCTlsCertPolicy {
    // Dictionary の定義上、全 case が網羅されているため安全
    // swiftlint:disable:next force_unwrapping
    tlsSecurityPolicyTable[self]!
  }
}
