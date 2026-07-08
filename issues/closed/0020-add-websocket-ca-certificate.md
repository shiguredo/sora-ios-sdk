# WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed: 2026-07-07
- Model: Opus 4.8
- Branch: feature/add-websocket-ca-certificate
- Polished: 2026-06-05

## 目的

企業内で自前のプライベート CA を利用している環境では、 Sora サーバーの証明書がシステム CA で検証できず、 WebSocket シグナリング接続が確立できない場合がある。ユーザーが指定した CA 証明書を用いて WebSocket シグナリングのサーバー証明書を検証できるようにする。

本 issue は WebSocket シグナリング経路の証明書検証実装に限定する。 ATS や OS のシステム trust 設定そのものを SDK 内で変更・無効化することは対象外とする。

## 依存関係

本 issue の検証処理は、ユーザーが CA 証明書を指定する公開 API（ `0022-add-user-ca-certificate` ）から CA 証明書を受け取って利用する。 `0022` は完了済みであり、現行コードには `Configuration.caCertificate` と `Configuration.parsedCACertificates()` が存在する。本 issue はそれらを WebSocket シグナリング経路へ配線する実装を対象とする。

## 優先度根拠

- 自前 CA を利用する企業ユーザーからの要望であり、対応しないと当該環境では接続自体が成立しない。
- システム CA を利用する通常環境では既に接続できており緊急性は限定的なため High ではなく Medium とする。

## 現状

WebSocket シグナリングは `URLSession` を用いて接続している。サーバー証明書の検証は `URLSession` のデリゲートで処理しており、 `NSURLAuthenticationMethodServerTrust` 分岐で `performDefaultHandling` を呼び、 iOS のシステム CA による既定検証に委ねている（ `Sora/URLSessionWebSocketChannel.swift:262-264` ）。

```swift
// Sora/URLSessionWebSocketChannel.swift:262-264
case NSURLAuthenticationMethodServerTrust:
  // デフォルト処理
  completionHandler(.performDefaultHandling, nil)
```

このため、システム CA で検証できないサーバー証明書（自前 CA で署名された証明書など）の場合、ユーザーが CA 証明書を指定しても WebSocket シグナリング接続は確立できない。

`URLSessionWebSocketChannel` は `SignalingChannel.swift:109` の `setUpWebSocketChannel(url:proxy:)` で生成されており、現状は `url` と `proxy` のみを受け取る。CA 証明書を渡す経路が存在しない。

## 設計方針

**変更対象ファイルとシグネチャ変更:**

- `SignalingChannel.swift:109` の `setUpWebSocketChannel(url:proxy:)` メソッドのシグネチャに CA 証明書引数を追加する。このメソッドは `connect` 時（ 215 行目）と `redirect` 時（ 242 行目）の 2 箇所から呼ばれるため、メソッドシグネチャを変更すれば両方が一度に対応できる。
- `URLSessionWebSocketChannel.init(url:proxy:)` にも CA 証明書引数を追加する。
- CA 証明書引数の型は `[SecCertificate]?` とする。 `Configuration.caCertificate` の PEM 文字列は `Configuration.parsedCACertificates()` で `SecCertificate` 配列へ変換し、その結果を渡す。中間 CA を含む構成に対応するため、単一証明書ではなく配列を前提にする。

**`parsedCACertificates()` の失敗伝播:**

- `Configuration.parsedCACertificates()` は PEM パース失敗時に `throw` するため、 `SignalingChannel.connect()` と redirect 経路の両方で明示的に `do-catch` すること。
- `SignalingChannel.connect()` は `throws` しないため、失敗は接続開始前の設定エラーとして扱い、 `onConnect?(error)` を呼んで即時に接続失敗として返す。あわせて `state` を `.disconnected` に戻し、 WebSocket 接続開始前なので `disconnect(error:reason:)` は呼ばない。 `try?` による握り潰しは禁止する。
- redirect 経路では、すでに接続シーケンス中の失敗であるため `disconnect(error: error, reason: .signalingFailure)` で切断エラーとして上位へ伝播させる。
- `setUpWebSocketChannel(...)` 自体は `throws` にせず、呼び出し前にパース済み `[SecCertificate]?` を用意してから渡す。これにより WebSocket 生成責務と設定検証責務を分離する。

**証明書検証ロジック:**

- `NSURLAuthenticationMethodServerTrust` 分岐に、ユーザー指定 CA 証明書を用いたカスタム検証処理を追加する。
- CA 証明書を指定しない場合は、現状どおり `performDefaultHandling`（システム CA 検証）にフォールバックする。後方互換性を維持する。
- CA 証明書がある場合は、`challenge.protectionSpace.serverTrust` から `SecTrust` を取得し、`SecTrustSetAnchorCertificates` で指定 CA 配列をアンカーに設定したうえで `SecTrustEvaluateWithError` で検証する。複数証明書（ルート CA と中間 CA）を配列のまま渡すことを前提とする。
- `SecTrustSetAnchorCertificatesOnly(trust, true)` を呼び、指定 CA のみをアンカーとして扱う。企業内プライベート CA 環境でユーザーが明示指定したアンカーだけを信頼する方針を採用する。 CA 未指定時のみシステム CA による既定検証を利用する。
- 検証成功時は `completionHandler(.useCredential, URLCredential(trust:))` とする。
- 検証失敗時は `completionHandler(.cancelAuthenticationChallenge, nil)` を返して認証チャレンジを中止する。 `URLSession` がその後どの delegate コールバックで失敗を通知するか（ `didCompleteWithError` で十分か、明示的な `disconnect(error:)` が必要か）は現行の `URLSessionWebSocketChannel` のエラー伝播経路と整合する形で実装時に確認すること。二重通知を避けるため、 challenge ハンドラ内で即座に `disconnect(error:)` を呼ぶ前提で固定しない。
- 接続開始前の PEM パース失敗は `configurationError`、 trust 評価失敗は `signalingChannelError` として責務を分ける。
- `URLSessionWebSocketChannel` 内の Security フレームワーク利用パターン、 `SecTrustEvaluateWithError` の戻り値解釈、失敗時のログ方針は、既存の `IOSCertificateVerifier` と整合させること。 WebSocket 側は `RTCSSLCertificateVerifier` を使えないが、証明書チェーン評価の考え方は既存コードに合わせる。
- `URLSession` 経由の WebSocket 接続は ATS（ App Transport Security）と OS のシステム trust の影響を受ける。 SDK の実装対象はあくまで `URLSessionDelegate` での trust 評価であり、 ATS 例外設定や OS 側の信頼設定を SDK が自動で変更することはできない。これらは利用アプリ側の責務として扱い、本 issue の完了条件には含めない。

## テスト方針

モック・スタブは使用しない。

`urlSession(_:task:didReceive:completionHandler:)` 全体の E2E をユニットテストで再現する必要はないが、 `SecTrust` 評価ロジック自体はヘルパー関数へ分離すればテストできる。 `0021` の `IOSCertificateVerifier` と同様に、テスト用の自己署名 CA 証明書とその CA で署名したサーバー証明書チェーンを用意し、以下をユニットテストで確認すること。

- 指定 CA 配列をアンカーにした評価で、対応する証明書チェーンが成功すること
- 異なる CA を指定した場合は失敗すること
- CA 未指定時は、システム CA では信頼されないテスト用チェーンが失敗すること

加えて、完了条件に記載した動作確認（後方互換確認、失敗ケースの確認、 trust 評価経路の確認）を結合テストとして実機で行い、結果を `## 解決方法` に記載すること。 ATS / OS trust の要件確認は参考情報として `## 解決方法` に記載してよいが、 SDK 実装の合否条件には含めない。

## 完了条件

- ユーザー指定の CA 証明書が `URLSessionDelegate` の server trust challenge まで到達し、指定アンカーでの `SecTrustEvaluateWithError` が成功した場合に `completionHandler(.useCredential, ...)` を返せること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で接続できること（後方互換性が保たれている）。
- 不正・期限切れ・指定 CA で検証できないサーバー証明書の場合は接続が失敗すること。
- `Configuration.caCertificate` の PEM 解析失敗時に、 connect 開始前に `SoraError.configurationError` として失敗すること。
- 証明書 trust 評価失敗時に、 WebSocket 接続失敗として上位へエラーが伝播すること。
- ATS / OS のシステム trust 要件が接続成立に影響しうることを `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする
    - @voluntas
  ```

## 解決方法

- `SignalingChannel` で `Configuration.parsedCACertificates()` を `connect()` と `redirect()` の両方で評価し、結果の `[SecCertificate]?` を `URLSessionWebSocketChannel` へ渡すようにした。
- `Configuration.parsedCACertificates()` の PEM パース失敗は、 `connect()` では接続開始前の `configurationError` として `onConnect` へ返し、 redirect 経路では `disconnect(error:reason:)` で上位へ伝播するようにした。
- `URLSessionWebSocketChannel` の `NSURLAuthenticationMethodServerTrust` 分岐で、 CA 証明書指定時は `performDefaultHandling` ではなく専用の server trust challenge ハンドラへ入るようにした。
- server trust challenge ハンドラでは `challenge.protectionSpace.serverTrust` を取り出し、 `SecTrustSetAnchorCertificates` と `SecTrustSetAnchorCertificatesOnly(trust, true)` を使ってユーザー指定アンカーで `SecTrustEvaluateWithError` を行う。
- `SecTrustSetAnchorCertificates` に渡すアンカーは、 PEM からパースした全証明書ではなく、 subject と issuer が一致する自己署名証明書のみを抽出した root CA に限定するようにした。中間 CA はアンカーにはせず、サーバー送出チェーンまたは trust オブジェクト側で解決される前提とする。
- trust 評価成功時は `completionHandler(.useCredential, URLCredential(trust: serverTrust))` を返し、失敗時は `completionHandler(.cancelAuthenticationChallenge, nil)` と `signalingChannelError` で接続失敗として扱うようにした。
- 実機確認では、 `Configuration.caCertificate` が設定され、 `parsedCACertificates()` が 2 件（ `Test Intermediate CA` と `Test Root CA` ）へ分解されることを確認した。
- 実機確認では、 `URLSessionDelegate` の server trust challenge に到達し、 `SecTrustEvaluateWithError` が成功して `completionHandler(.useCredential, ...)` が呼ばれることを確認した。これは SDK 側の独自 CA 検証経路が動作していることを示す。
- 一方で、上記が成功した後でも `ATS failed system trust` / `NSURLErrorDomain Code=-1200` により接続全体が失敗するケースを確認した。したがって、本実装は `URLSessionDelegate` 内での trust 評価を追加するものであり、 ATS や OS のシステム trust 要件そのものを無効化するものではない。
- そのため、 ATS 例外設定、実機への root CA インストール、 OS 側 trust 設定、配布環境ごとの TLS 制約確認は利用アプリ側の責務とする。 SDK 単体で「自前 CA なら必ず wss 接続が成立する」ことまでは保証しない。
- サーバーの TLS チェーン送出は `openssl s_client -showcerts` で確認し、葉証明書 `sora.tmiya83.com` と `Test Intermediate CA` が送出され、 root CA はサーバーからは送出されていないことを確認した。これは一般的な TLS 構成として妥当である。
