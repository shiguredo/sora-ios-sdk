# TURN-TLS でユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-turn-tls-ca-certificate
- Polished: 2026-07-08

## 目的

企業内で自前のプライベート CA を利用している環境では、 TURN-TLS （ `turns:` ）サーバーの証明書がシステム CA で検証できず、 TURN-TLS 経由のメディア通信が確立できない。ユーザーが指定した CA 証明書を用いて TURN-TLS サーバー証明書を検証できるようにする。

本 issue は TURN-TLS 経路の証明書検証実装に限定する。

## 依存関係

- 0022: `Configuration.caCertificate` と `Configuration.parsedCACertificates()` を提供。完了済み。
- 0020: WebSocket シグナリングの CA 検証実装。完了済み。本 issue は 0020 で確立したパターン（ `rootAnchorCertificates(from:)` 、`SecTrustSetAnchorCertificates` + `Only(true)` 、OSStatus チェック、 `SecTrustEvaluateWithError` エラーログ）に従う。

## 優先度根拠

- 対応しないとプライベート CA 環境では TURN-TLS 経由の通信が成立しない。
- システム CA を利用する通常環境では既に通信できており緊急性は限定的なため High ではなく Medium とする。

## 現状

TURN-TLS の証明書検証は、 `IOSCertificateVerifier` が `RTCSSLCertificateVerifier` プロトコルを実装して行っている（ `Sora/IOSCertificateVerifier.swift` ）。 `verifyChain(_:)` で libwebrtc から DER 証明書チェーンを受け取り、 `evaluate(_:)` で `SecTrust` を構築し `SecTrustEvaluateWithError` で検証する。 `init(evaluator:)` でカスタム evaluator を差し込める設計になっている。

現状はシステム CA による検証のみであり、ユーザー指定 CA をアンカーとして設定する処理は無い。

**配線経路の現状と課題**:

`PeerChannel` は `configuration: Configuration` と `webRTCConfiguration: WebRTCConfiguration` の両方を保持している。 `createNativePeerChannel` は `PeerChannel.swift:838` の `createAndSendAnswer` 内で呼ばれる。現状の `createCertificateVerifier(configuration: WebRTCConfiguration)` は `WebRTCConfiguration` しか受け取れず、 `Configuration.caCertificate` を `IOSCertificateVerifier` に渡す経路が存在しない。

## 設計方針

### CA 証明書の型とフィルタリング

- `IOSCertificateVerifier` が受け取る CA 証明書の型は `[SecCertificate]?` とする。 PEM 文字列から `SecCertificate` への変換は 0022 側で行う。
- `Configuration.caCertificate` の PEM にはルート CA と中間 CA の両方が含まれる可能性がある。中間 CA を `SecTrustSetAnchorCertificates` に渡すと、本来ルート CA の署名で検証すべき中間 CA が無条件に信頼済みアンカーと見なされ、チェーン検証の強度が落ちる。
- そのため、 0020 で実装した `rootAnchorCertificates(from:)` と同様に、発行者と主体が同一の自己署名証明書（ルート CA）のみをアンカーとして抽出する。 `URLSessionWebSocketChannel.rootAnchorCertificates(from:)` と同一のロジックを `IOSCertificateVerifier` にも実装する。 `static` メソッドなので共通化せず各クラスに個別実装する。

### TURN-TLS の証明書チェーンと中間 CA

libwebrtc から `verifyChain(_:)` で渡される DER チェーンは、TURN サーバーが TLS ハンドシェイクで送出した証明書チェーンである。 `caCertificate` の責務は信頼アンカーの指定に限定し、チェーンの補完は行わない。この方針は 0020 (WebSocket) と同一である。

サーバーが葉証明書と中間証明書を含む完全なチェーンを送出する構成が前提となる。TURN サーバーが葉証明書のみを送出する構成では中間 CA 不在により検証が失敗するが、これはサーバー側の設定の問題であり、SDK で補完すべきではない。

### `SecTrustSetAnchorCertificatesOnly` の方針

- CA 証明書を指定した場合は `SecTrustSetAnchorCertificatesOnly(trust, true)` を呼び、指定 CA のみをアンカーとする。
- CA 証明書を指定しない場合は現状どおりシステム CA による評価を行う（後方互換性維持）。

### `IOSCertificateVerifier` の変更方針

- 既存の `init(evaluator: @escaping Evaluator)` は削除せずに残す。
- 新たに `convenience init(caCertificates: [SecCertificate]?)` を追加する。
  - CA 証明書あり（非 nil かつ非空）の場合: キャプチャした `caCertificates` で `{ chain in evaluate(chain, caCertificates: caCertificates) }` クロージャーを生成し `init(evaluator:)` に渡す。
  - CA 証明書なしの場合: `IOSCertificateVerifier.evaluate` をそのまま渡す。
- 新たに `private static func evaluate(_ certificateChain: [SecCertificate], caCertificates: [SecCertificate]) -> Bool` を追加する。以下の手順で評価する:
  1. `rootAnchorCertificates(from: caCertificates)` でルート CA のみを抽出。空なら `false`
  2. `SecPolicyCreateSSL(true, nil)` で SSL ポリシーを生成
  3. `SecTrustCreateWithCertificates` で `SecTrust` を構築。 `errSecSuccess` 以外または trust が nil なら `false`
  4. `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(trust, true)` を呼び、各 OSStatus をチェック
  5. `SecTrustEvaluateWithError` で評価し、 `CFError` をログ出力
  6. いずれかのステップで失敗した場合は `false` を返す
- クラス Doc コメント（ `IOSCertificateVerifier.swift:5` ）を「システム CA のみ」から「システム CA またはユーザー指定 CA」に更新する。

### 配線経路の変更

`WebRTCConfiguration` には CA 証明書を追加しない（ WebRTC プロトコル設定とは別概念）。代わりに以下のシグネチャ変更を行う:

1. `NativePeerChannelFactory.createNativePeerChannel(configuration:constraints:proxy:delegate:)` （ `Sora/NativePeerChannelFactory.swift:70-75` ）に `caCertificates: [SecCertificate]? = nil` 引数を追加する。デフォルト `nil` で `createClientOfferSDP` 内部呼び出しは変更不要。
2. `NativePeerChannelFactory.createCertificateVerifier(configuration:caCertificates:)` （ `Sora/NativePeerChannelFactory.swift:109` ）に `caCertificates: [SecCertificate]?` 引数を追加し、 `IOSCertificateVerifier(caCertificates: caCertificates)` を呼ぶ。
3. `PeerChannel.swift:838` の `createNativePeerChannel` 呼び出し前に `configuration.parsedCACertificates()` を `try` で呼び出し、結果を `caCertificates:` 引数として渡す。 PEM が不正な場合、既に `SignalingChannel.connect()` でパースに失敗して接続が成立しないため、この throw パスは実運用では到達しない防御的コードである。それでも、型を得て引き渡すため `try` で呼び、 throw した場合は既存の失敗パス（ `PeerChannel.swift:843-851` ）と同様に `lock.unlock()` → `disconnect(error: SoraError.configurationError(...), reason: .signalingFailure)` で伝播させる。

### ホスト名検証

引き続き行わない。 `RTCSSLCertificateVerifier` のコールバック引数にホスト名が含まれず技術的に不可能であるため。 libwebrtc の TURN-TLS 向け OpenSSLAdapter 経路でも SAN / CN 照合が行われていない既存挙動と一致する。

## テスト方針

モック・スタブは使用しない。

テスト用証明書は 0020 の `URLSessionWebSocketChannelTests.swift` で使用した Base64 DER 埋め込みと同じものを再利用する（テスト用ルート CA + サーバー証明書 + 別 CA）。このセットはルート CA がサーバー証明書に直接署名する構成であり、中間 CA を含まない。以下のテストケースで中間 CA 用 fixture が必要な場合は別途追加する。

- `IOSCertificateVerifier(caCertificates: [caCert])` で生成した verifier に、指定 CA で署名したサーバー証明書チェーンを渡すと `true` を返すこと。
- 指定 CA とは異なる CA で署名したチェーンを渡すと `false` を返すこと。
- `IOSCertificateVerifier(caCertificates: nil)` で生成した verifier に、テスト用自己署名 CA で署名したチェーンを渡すと `false` を返すこと（システム CA では信頼されないため）。
- 中間 CA 証明書（自己署名でない CA 証明書）のみを `caCertificates` に指定した場合、ルート CA 不在でアンカー抽出が空になり `false` を返すこと。

後方互換性の確認（ CA 未指定時にシステム CA 評価パスに入ること）は実機での手動テストで行う。

## 完了条件

- 上記 4 つのテストケースがすべて通ること。
- 実機での手動テスト（指定 CA で署名した `turns:` サーバーへの接続、後方互換確認、失敗ケース確認）を実施し、結果を `## 解決方法` に記載すること。 libwebrtc 側または iOS 側の制約により実通信が成立しない場合は、制約内容と回避策を `## 解決方法` に明記すること。
- 以下の制約を `Configuration.caCertificate` の Swift Doc コメントに記載すること:
  - ホスト名検証が行われないこと
  - TURN サーバーが中間証明書を含む完全なチェーンを送出する必要があること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] TURN-TLS でユーザー指定の CA 証明書を検証できるようにする
    - @t-miya
  ```

## 解決方法
