import Foundation
import Security
import WebRTC

/// TURN-TLS の証明書検証を行うクラスです。
final class TURNTLSCertificateVerifier: NSObject, RTCSSLCertificateVerifier {
  /// カスタム CA 証明書（オプション）
  private let caCertificate: SecCertificate?

  /// 初期化します。
  /// - Parameter caCertificate: カスタム CA 証明書。nil の場合は iOS のシステム証明書ストアを使用します。
  init(caCertificate: SecCertificate? = nil) {
    self.caCertificate = caCertificate
    super.init()
  }

  /// 証明書を検証します。
  /// - Parameter certificate: サーバーから受信した証明書データ
  /// - Returns: 証明書が有効な場合は true、無効な場合は false
  func verify(_ certificate: Data) -> Bool {
    Logger.debug(type: .peerChannel, message: "TURNTLSCertificateVerifier: start verify")
    guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else {
      Logger.debug(
        type: .peerChannel,
        message: "SecCertificateCreateWithData failed: \(certificate.base64EncodedString())")
      return false
    }

    var trust: SecTrust?
    let policy = SecPolicyCreateBasicX509()
    let status = SecTrustCreateWithCertificates(cert, policy, &trust)

    guard status == errSecSuccess, let trust = trust else {
      Logger.debug(
        type: .peerChannel, message: "SecTrustCreateWithCertificates failed: \(status)")
      return false
    }

    // カスタム CA 証明書が指定されている場合は、それを使用して検証
    Logger.debug(
      type: .peerChannel, message: "TURNTLSCertificateVerifier.caCertificate: \(String(describing: caCertificate))")
    if let caCertificate = caCertificate {
      let anchorCertificates = [caCertificate] as CFArray
      SecTrustSetAnchorCertificates(trust, anchorCertificates)
      // システムの証明書ストアを使用しない
      SecTrustSetAnchorCertificatesOnly(trust, true)
    }

    var error: CFError?
    let result = SecTrustEvaluateWithError(trust, &error)

    Logger.debug(
      type: .peerChannel,
      message: "SecTrustEvaluateWithError: \(result), error: \(String(describing: error))")
    return result
  }
}
