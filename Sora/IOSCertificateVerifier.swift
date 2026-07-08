import Foundation
import Security
import WebRTC

/// TURN-TLS 向けにシステム CA またはユーザー指定 CA で証明書チェーンを検証する verifier です。
final class IOSCertificateVerifier: NSObject, RTCSSLCertificateVerifier {
  typealias Evaluator = ([SecCertificate]) -> Bool

  private let evaluator: Evaluator

  init(evaluator: @escaping Evaluator = IOSCertificateVerifier.evaluate) {
    self.evaluator = evaluator
    super.init()
  }

  /// ユーザー指定 CA 証明書をアンカーとして使う verifier を生成する
  ///
  /// `caCertificates` が非 nil かつ非空の場合は、指定された証明書のうち
  /// 自己署名のルート CA のみを信頼アンカーとして証明書チェーンを検証する。
  /// nil または空の場合は、既存のデフォルト evaluator と同じく
  /// システム CA による証明書チェーン検証を行う
  convenience init(caCertificates: [SecCertificate]?) {
    if let caCertificates, !caCertificates.isEmpty {
      self.init(evaluator: { chain in
        IOSCertificateVerifier.evaluate(chain, caCertificates: caCertificates)
      })
    } else {
      self.init()
    }
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
    let result = SecTrustEvaluateWithError(trust, &error)
    if !result, let error {
      let nsError = error as Error as NSError
      Logger.debug(
        type: .nativePeerChannel,
        message:
          "TURN-TLS trust evaluate error: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)"
      )
    }
    return result
  }

  /// ユーザー指定 CA 証明書をアンカーとして証明書チェーンを検証する
  private static func evaluate(
    _ certificateChain: [SecCertificate],
    caCertificates: [SecCertificate]
  ) -> Bool {
    // 自己署名証明書（ルート CA）のみをアンカーとして抽出する
    let rootAnchorCertificates = rootAnchorCertificates(from: caCertificates)
    guard !rootAnchorCertificates.isEmpty else {
      return false
    }

    let policy = SecPolicyCreateSSL(true, nil)
    var trust: SecTrust?
    let createStatus = SecTrustCreateWithCertificates(
      certificateChain as CFArray,
      policy,
      &trust)
    guard createStatus == errSecSuccess, let trust else {
      return false
    }

    let setAnchorsStatus = SecTrustSetAnchorCertificates(
      trust, rootAnchorCertificates as CFArray)
    guard setAnchorsStatus == errSecSuccess else {
      Logger.debug(
        type: .nativePeerChannel,
        message:
          "TURN-TLS SecTrustSetAnchorCertificates failed with status \(setAnchorsStatus)"
      )
      return false
    }

    let setAnchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
    guard setAnchorsOnlyStatus == errSecSuccess else {
      Logger.debug(
        type: .nativePeerChannel,
        message:
          "TURN-TLS SecTrustSetAnchorCertificatesOnly failed with status \(setAnchorsOnlyStatus)"
      )
      return false
    }

    var error: CFError?
    let result = SecTrustEvaluateWithError(trust, &error)
    if !result, let error {
      let nsError = error as Error as NSError
      Logger.debug(
        type: .nativePeerChannel,
        message:
          "TURN-TLS trust evaluate error: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)"
      )
    } else if result {
      Logger.debug(
        type: .nativePeerChannel,
        message: "TURN-TLS trust evaluate succeeded")
    }
    return result
  }

  /// 指定された証明書群から自己署名のルート CA のみを抽出する
  ///
  /// ルート CA と中間 CA のみが含まれる証明書チェーンを想定しているため、
  /// subject と issuer 比較の簡易的なチェックにより抽出する
  static func rootAnchorCertificates(from certificates: [SecCertificate]) -> [SecCertificate] {
    certificates.filter { certificate in
      guard
        let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
        let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
      else {
        return false
      }
      return subject == issuer
    }
  }
}
