# TURN-TLS でユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-turn-tls-ca-certificate

## 目的

企業内で自前のプライベート CA を利用している環境では、TURN-TLS (`turns:`) サーバーの証明書がシステム CA で検証できず、TURN-TLS 経由のメディア通信が確立できない。ユーザーが指定した CA 証明書を用いて TURN-TLS サーバー証明書を検証できるようにし、こうした環境でも TURN-TLS で通信できるようにする。

本 issue は TURN-TLS 経路の証明書検証実装に限定する。

## 依存関係

本 issue の検証処理は、ユーザーが CA 証明書を指定する公開 API (`0022-add-user-ca-certificate`) から CA 証明書を受け取り、検証アンカーとして利用する。`0022-add-user-ca-certificate` の公開 API 追加を前提とする。

## 優先度根拠

- 自前 CA を利用する企業ユーザーからの要望であり、対応しないと当該環境では TURN-TLS 経由の通信が成立しない。
- システム CA を利用する通常環境では既に TURN-TLS 通信ができており緊急性は限定的なため High ではなく Medium とする。

## 現状

TURN-TLS の証明書検証は、`IOSCertificateVerifier` が `RTCSSLCertificateVerifier` を実装して行っている。`verifyChain(_:)` で libwebrtc から DER 証明書チェーンを受け取り、`evaluate(_:)` で `SecPolicyCreateSSL` と `SecTrustCreateWithCertificates` から `SecTrust` を構築し、`SecTrustEvaluateWithError` で検証する。

```swift
// Sora/IOSCertificateVerifier.swift:39-60
private static func evaluate(_ certificateChain: [SecCertificate]) -> Bool {
  // TURN サーバーの証明書をサーバー用途として検証する。
  // ただし、 RTCSSLCertificateVerifier からは接続先ホスト名を受け取れないため、
  // serverName を指定したホスト名検証は行えない。
  // ...
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
```

この verifier は `usesVerifiedTURNTLS` が真の場合 (`turns:` を含み `tlsSecurityPolicy` が `.secure` の場合) に、`createCertificateVerifier` から `RTCPeerConnection` 生成時に渡される。

```swift
// Sora/NativePeerChannelFactory.swift:109-117
private func createCertificateVerifier(
  configuration: WebRTCConfiguration
) -> RTCSSLCertificateVerifier? {
  if configuration.usesVerifiedTURNTLS {
    return IOSCertificateVerifier()
  }

  return nil
}
```

現状はシステム CA による検証のみであり、`SecTrustCreateWithCertificates` で構築した `SecTrust` にユーザー指定の CA をアンカーとして設定する処理は無い。なお `RTCSSLCertificateVerifier` からは接続先ホスト名を受け取れないため、ホスト名検証は行っていない。

## 設計方針

- `IOSCertificateVerifier` を拡張し、ユーザー指定の CA 証明書をアンカーとして用いた検証を行えるようにする。
- ユーザー指定の CA 証明書が無い場合は、現状どおりシステム CA による検証 (既定の `SecTrust` 評価) を行う。後方互換性を維持する。
- ユーザー指定の CA 証明書がある場合は、`SecTrustSetAnchorCertificates` で指定 CA をアンカーに設定したうえで `SecTrustEvaluateWithError` で検証する。`SecTrustSetAnchorCertificatesOnly` の扱い (システム CA も併用するか、指定 CA のみとするか) を方針として決める。
- ホスト名検証は引き続き行わない。libwebrtc の TURN-TLS 向け OpenSSLAdapter 経路でも証明書の SAN / CN 照合は行われておらず、既存挙動に合わせる。
- ユーザー指定 CA が `IOSCertificateVerifier` に渡るよう、`createCertificateVerifier` および `IOSCertificateVerifier` の初期化を CA 証明書を受け取れるよう変更する。
- 本 issue では検証処理の実装に限定する。

## 完了条件

- ユーザー指定の CA 証明書 (中間証明書を含むチェーン構成を含む) で署名された TURN-TLS サーバー証明書に対し、TURN-TLS 通信ができること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で TURN-TLS 通信ができること (後方互換性が保たれている)。
- 期限切れ・指定 CA で検証できないサーバー証明書の場合は TURN-TLS 接続が失敗すること。
- 端末に CA をインストールして信頼設定済みの場合に、CA 証明書未指定でも通信できることを確認すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] TURN-TLS でユーザー指定の CA 証明書を検証できるようにする
    - @担当者
  ```

## 解決方法
