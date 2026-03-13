import Foundation
import Security
import WebRTC

/// TURN-TLS 向けに iOS のシステム CA で証明書チェーンを検証する verifier です。
final class IOSCertificateVerifier: NSObject, RTCSSLCertificateVerifier {
  typealias Evaluator = ([SecCertificate]) -> Bool

  private let evaluator: Evaluator

  init(evaluator: @escaping Evaluator = IOSCertificateVerifier.evaluate) {
    self.evaluator = evaluator
    super.init()
  }

  // `RTCSSLCertificateVerifier` の必須要件を満たすために実装する。
  // `verifyChain` が利用できる場合こちらは使われない。
  func verify(_ derCertificate: Data) -> Bool {
    return verifyChain([derCertificate])
  }

  // libwebrtc 側から Objective-C の `verifyChain:` selector として呼べるように `@objc` を付与する。
  @objc func verifyChain(_ derCertificateChain: [Data]) -> Bool {
    let certificateChain = derCertificateChain.compactMap { derCertificate in
      SecCertificateCreateWithData(nil, derCertificate as CFData)
    }

    guard !certificateChain.isEmpty else {
      return false
    }

    guard certificateChain.count == derCertificateChain.count else {
      return false
    }

    return evaluator(certificateChain)
  }

  private static func evaluate(_ certificateChain: [SecCertificate]) -> Bool {
    // TURN サーバーの証明書をサーバー用途として検証する。
    // ただし、 RTCSSLCertificateVerifier からは接続先ホスト名を受け取れないため、
    // serverName を指定したホスト名検証は行えない。
    // libwebrtc の TURN-TLS 向け OpenSSLAdapter 経路でも、ホスト名は SNI には使われるが、
    // 証明書の SAN / CN 照合には使われていない。
    // そのため、ここでは libwebrtc の既存挙動に合わせて、
    // iOS のシステム CA による証明書チェーン検証のみを行う。
    let policy = SecPolicyCreateSSL(true, nil)
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(
      certificateChain as CFArray,
      policy,
      &trust)

    guard status == errSecSuccess, let trust else {
      return false
    }

    var error: CFError?
    return SecTrustEvaluateWithError(trust, &error)
  }
}
