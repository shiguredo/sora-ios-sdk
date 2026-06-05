# TURN-TLS でユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-turn-tls-ca-certificate
- Polished: 2026-06-05

## 目的

企業内で自前のプライベート CA を利用している環境では、 TURN-TLS （ `turns:` ）サーバーの証明書がシステム CA で検証できず、 TURN-TLS 経由のメディア通信が確立できない。ユーザーが指定した CA 証明書を用いて TURN-TLS サーバー証明書を検証できるようにし、こうした環境でも TURN-TLS で通信できるようにする。

本 issue は TURN-TLS 経路の証明書検証実装に限定する。

## 依存関係

本 issue の検証処理は、ユーザーが CA 証明書を指定する公開 API（ `0022-add-user-ca-certificate` ）から CA 証明書を受け取り、検証アンカーとして利用する。 `0022-add-user-ca-certificate` の公開 API 追加を前提とするため、先に `0022` を完了させること。本 issue が受け取る `[SecCertificate]?` の型は 0022 の `Configuration.caCertificate` の型設計（ PEM → `SecCertificate` 変換を 0022 側で行う）が確定した後に整合性を確認すること。型が確定するまで本 issue の実装に着手しないこと。

## 優先度根拠

- 自前 CA を利用する企業ユーザーからの要望であり、対応しないと当該環境では TURN-TLS 経由の通信が成立しない。
- システム CA を利用する通常環境では既に TURN-TLS 通信ができており緊急性は限定的なため High ではなく Medium とする。

## 現状

TURN-TLS の証明書検証は、 `IOSCertificateVerifier` が `RTCSSLCertificateVerifier` プロトコルを実装して行っている。 `verifyChain(_:)` で libwebrtc から DER 証明書チェーンを受け取り、 `evaluate(_:)` で `SecPolicyCreateSSL` と `SecTrustCreateWithCertificates` から `SecTrust` を構築し、 `SecTrustEvaluateWithError` で検証する。

```swift
// Sora/IOSCertificateVerifier.swift:39-60
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
```

`IOSCertificateVerifier` は `init(evaluator: @escaping Evaluator = IOSCertificateVerifier.evaluate)` でカスタム `evaluator` クロージャーを差し込める設計になっており、現在はデフォルト evaluator としてシステム CA 検証のみを行う `evaluate(_:)` （行 39 ）が、行 11 の `init` のデフォルト引数として指定されている。

この verifier は `usesVerifiedTURNTLS` が真の場合（ `turns:` を含み `tlsSecurityPolicy` が `.secure` の場合）に、 `createCertificateVerifier` から `RTCPeerConnection` 生成時に渡される。

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

現状はシステム CA による検証のみであり、 `SecTrustCreateWithCertificates` で構築した `SecTrust` にユーザー指定の CA をアンカーとして設定する処理は無い。

**配線経路の現状と課題**:

`PeerChannel` は `configuration: Configuration` （行 154 ）と `webRTCConfiguration: WebRTCConfiguration` （行 191 ）の両方を保持している。 `createNativePeerChannel` 呼び出しは `PeerChannel.swift` では行 822 の 1 箇所のみであり、 `webRTCConfiguration` を渡す。なお `NativePeerChannelFactory.swift:182` の `createClientOfferSDP` は内部で `createNativePeerChannel` を呼ぶが、 SDP 生成目的であり TURN-TLS 実通信は発生しない。現状の `createCertificateVerifier(configuration: WebRTCConfiguration)` は `WebRTCConfiguration` しか受け取れず、 `Configuration.caCertificate` （ 0022 で追加予定）を `IOSCertificateVerifier` に渡す経路が存在しない。

## 設計方針

**CA 証明書の型**:

- `IOSCertificateVerifier` が受け取る CA 証明書の型は `[SecCertificate]?` とする。 PEM 文字列から `SecCertificate` への変換は 0022 側で行う。複数の CA （中間 CA を含む構成）を渡せるよう配列とする。

**`SecTrustSetAnchorCertificatesOnly` の方針**:

- CA 証明書を指定した場合は `SecTrustSetAnchorCertificatesOnly(trust, true)` を呼び、指定 CA のみをアンカーとする。企業内プライベート CA 環境では指定 CA のみを信頼することが正しい動作であるため。
- CA 証明書を指定しない場合は `SecTrustSetAnchorCertificatesOnly` を呼ばず、現状どおりシステム CA による評価を行う（後方互換性維持）。
- 0020 の `SecTrustSetAnchorCertificatesOnly` の方針もこの決定に従う。 0020 の実装時に整合させること。

**中間 CA チェーン構成の扱い**:

- TURN サーバーが葉証明書と中間証明書を含むチェーンを送出する場合は、ユーザーはルート CA のみを指定すれば検証できる。
- TURN サーバーが葉証明書のみ送出する構成では、 `SecTrustSetAnchorCertificatesOnly(trust, true)` 指定時に中間 CA が見つからず検証が失敗する。この場合はユーザーがルート CA と中間 CA を両方 `caCertificate` に含める必要がある。この制約を利用者向け API ドキュメント（ `Configuration.caCertificate` の Swift Doc コメント）に記載すること。

**`IOSCertificateVerifier` の変更方針**:

- 既存の `init(evaluator: @escaping Evaluator)` は削除せずに残す。
- 新たに `convenience init(caCertificates: [SecCertificate]?)` を追加する。既存の `init(evaluator:)` に委譲する `convenience init` として宣言する。 CA 証明書ありの場合は `{ chain in IOSCertificateVerifier.evaluate(chain, anchorCertificates: caCertificates) }` クロージャーを `caCertificates` をキャプチャして `init(evaluator:)` に渡す。 CA 証明書なし（ `nil` または空配列）の場合は `IOSCertificateVerifier.evaluate` をそのまま渡す。
- CA 証明書ありの評価パスを担う `private static func evaluate(_ certificateChain: [SecCertificate], anchorCertificates: [SecCertificate]) -> Bool` を追加する。 `SecTrustSetAnchorCertificates` を先に呼び、続いて `SecTrustSetAnchorCertificatesOnly(trust, true)` を呼んでから `SecTrustEvaluateWithError` で検証する。いずれかが `errSecSuccess` 以外を返した場合は `false` を返す。

**配線経路の変更**:

`WebRTCConfiguration` には CA 証明書を追加しない（ WebRTC プロトコル設定とは別概念）。代わりに以下のシグネチャ変更を行う:

1. `NativePeerChannelFactory.createNativePeerChannel(configuration:constraints:proxy:delegate:)` に `caCertificates: [SecCertificate]? = nil` 引数を追加する（ `Sora/NativePeerChannelFactory.swift:70-75` のシグネチャ）。デフォルト `nil` にすることで `createClientOfferSDP` （ `Sora/NativePeerChannelFactory.swift:182` ）内部の呼び出しはシグネチャ変更不要となる。
2. `NativePeerChannelFactory.createCertificateVerifier(configuration:)` に `caCertificates: [SecCertificate]?` 引数を追加し、 `IOSCertificateVerifier(caCertificates: caCertificates)` を呼ぶ（ `Sora/NativePeerChannelFactory.swift:109` ）。
3. `PeerChannel.swift` 行 822 の `createNativePeerChannel` 呼び出し前に `configuration.parsedCACertificates()` を `try` で呼び出し、結果の `[SecCertificate]?` を `caCertificates:` 引数として渡す。 `parsedCACertificates()` が throw した場合は connect コールバックにエラーを伝播させること。

**ホスト名検証**:

引き続き行わない。 `RTCSSLCertificateVerifier` のコールバック引数にホスト名が含まれず技術的に不可能であるため（主因）。 libwebrtc の TURN-TLS 向け OpenSSLAdapter 経路でも SAN / CN 照合が行われていないという既存挙動もこれに一致する（副次的根拠）。この制約を利用者向け API ドキュメント（ `Configuration.caCertificate` の Swift Doc コメント）に記載すること。

## テスト方針

モック・スタブは使用しない。

`IOSCertificateVerifier.verifyChain(_:)` は `SecCertificateCreateWithData` でパースできる DER バイト列があれば、実際の TLS 接続なしでユニットテストを書ける。テスト用の自己署名 CA 証明書とその CA で署名したサーバー証明書の DER データをテストリソースとして用意し（ `openssl` で事前生成し `SoraTests/Fixtures/` 等に配置する）、以下をテストすること:

- `IOSCertificateVerifier(caCertificates: [caCert])` で生成した verifier に、指定 CA で署名したサーバー証明書チェーンを渡すと `true` を返すこと。
- 指定 CA とは異なる CA で署名したチェーンを渡すと `false` を返すこと。
- `IOSCertificateVerifier(caCertificates: nil)` で生成した verifier に、テスト用自己署名 CA で署名したチェーン（システム CA では信頼されない）を渡すと `false` を返すこと（カスタムアンカーが設定されていないことを間接的に確認する）。後方互換性（ CA 未指定時にシステム CA 評価パスに入ること）は実機での手動テストで確認する。

TURN-TLS 実通信テスト（指定 CA で署名した `turns:` サーバーへの接続）は実機での手動テストで行い、手動テストの結果（通信可否・失敗ケース確認）を `## 解決方法` に記載すること。

## 完了条件

- ユーザー指定の CA 証明書（中間 CA チェーン構成を含む）で署名された TURN-TLS サーバー証明書に対し、 TURN-TLS 通信ができること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で TURN-TLS 通信ができること（後方互換性が保たれている）。
- 期限切れ・指定 CA で検証できないサーバー証明書の場合は TURN-TLS 接続が失敗すること。
- 端末に CA をインストールして信頼設定済みの場合に、 CA 証明書未指定でも通信できることを確認すること。
- ホスト名検証ができないというセキュリティ上の制約と、サーバーが中間証明書を送出しない場合に中間 CA も `caCertificate` に含める必要があるという制約を、 `Configuration.caCertificate` の Swift Doc コメントに記載すること。
- テスト方針に記載したユニットテストがすべて通ること。
- 手動テストの結果を `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] TURN-TLS でユーザー指定の CA 証明書を検証できるようにする
    - @voluntas
  ```

## 解決方法
