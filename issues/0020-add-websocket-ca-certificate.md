# WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-websocket-ca-certificate
- Polished: 2026-06-05

## 目的

企業内で自前のプライベート CA を利用している環境では、 Sora サーバーの証明書がシステム CA で検証できず、 WebSocket シグナリング接続が確立できない。ユーザーが指定した CA 証明書を用いて WebSocket シグナリングのサーバー証明書を検証できるようにし、こうした環境でも接続できるようにする。

本 issue は WebSocket シグナリング経路の証明書検証実装に限定する。

## 依存関係

本 issue の検証処理は、ユーザーが CA 証明書を指定する公開 API（ `0022-add-user-ca-certificate` ）から CA 証明書を受け取って利用する。`0022-add-user-ca-certificate` の公開 API 追加を前提とするため、先に `0022` を完了させること。

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
- CA 証明書引数の型は 0022 の設計（ `Configuration.caCertificate` ）に合わせること。0022 が PEM 文字列で受け取る場合は `SecCertificate` への変換後に渡すか変換前に渡すかを 0022 と調整すること。中間 CA が複数段ある環境では配列が必要になる可能性があるため、型を 0022 と統一すること（本 issue の実装は 0022 の型確定後に着手すること）。

**証明書検証ロジック:**

- `NSURLAuthenticationMethodServerTrust` 分岐に、ユーザー指定 CA 証明書を用いたカスタム検証処理を追加する。
- CA 証明書を指定しない場合は、現状どおり `performDefaultHandling`（システム CA 検証）にフォールバックする。後方互換性を維持する。
- CA 証明書がある場合は、`challenge.protectionSpace.serverTrust` から `SecTrust` を取得し、`SecTrustSetAnchorCertificates` で指定 CA をアンカーに設定したうえで `SecTrustEvaluateWithError` で検証する。`SecTrustSetAnchorCertificatesOnly` の扱い（システム CA も併用するか、指定 CA のみとするか）は 0021 と方針を統一して決定すること。検証成功時は `completionHandler(.useCredential, URLCredential(trust:))`、失敗時は `cancelAuthenticationChallenge` で接続を中止する。
- `URLSession` 経由の WebSocket 接続は ATS（ App Transport Security）の影響を受ける。ATS 回避が必要かどうかを動作確認で確認すること。

## テスト方針

モック・スタブは使用しない。`urlSession(_:task:didReceive:completionHandler:)` デリゲートメソッドのコードパスは実際のネットワーク接続なしにはテストできないため、ユニットテストは追加しない。完了条件に記載した動作確認（自前 CA サーバーへの接続、後方互換確認、失敗ケースの確認）を結合テストとして実機で行い、結果を `## 解決方法` に記載すること。

## 完了条件

- ユーザー指定の CA 証明書で署名されたサーバー証明書を持つ Sora サーバーに、 WebSocket シグナリングで接続できること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で接続できること（後方互換性が保たれている）。
- 不正・期限切れ・指定 CA で検証できないサーバー証明書の場合は接続が失敗すること。
- ATS の影響有無を確認し、必要であれば回避方法（対象ドメインの ATS 例外設定）を `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする
    - @voluntas
  ```

## 解決方法
