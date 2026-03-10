import Foundation
import Security
import WebRTC

final class IOSCertificateVerifier: NSObject, RTCSSLCertificateVerifier {
  typealias Evaluator = ([SecCertificate]) -> Bool

  private let evaluator: Evaluator

  init(evaluator: @escaping Evaluator = IOSCertificateVerifier.evaluate) {
    self.evaluator = evaluator
    super.init()
  }

  // `RTCSSLCertificateVerifier` の必須要件を満たすために実装する。
  // `verifyChain` が利用できる libwebrtc では、通常はこちらは使われない想定。
  func verify(_ derCertificate: Data) -> Bool {
    return verifyChain([derCertificate])
  }

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
    let policy = SecPolicyCreateSSL(false, nil)
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
