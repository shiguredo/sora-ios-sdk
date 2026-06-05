# WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-websocket-ca-certificate

## 目的

企業内で自前のプライベート CA を利用している環境では、Sora サーバーの証明書がシステム CA で検証できず、WebSocket シグナリング接続が確立できない。ユーザーが指定した CA 証明書を用いて WebSocket シグナリングのサーバー証明書を検証できるようにし、こうした環境でも接続できるようにする。

本 issue は WebSocket シグナリング経路の証明書検証実装に限定する。

## 依存関係

本 issue の検証処理は、ユーザーが CA 証明書を指定する公開 API (`0022-add-user-ca-certificate`) から CA 証明書を受け取って利用する。`0022-add-user-ca-certificate` の公開 API 追加を前提とする。

## 優先度根拠

- 自前 CA を利用する企業ユーザーからの要望であり、対応しないと当該環境では接続自体が成立しない。
- システム CA を利用する通常環境では既に接続できており緊急性は限定的なため High ではなく Medium とする。

## 現状

WebSocket シグナリングは `URLSession` を用いて接続している。サーバー証明書の検証は `URLSession` のデリゲートで処理しており、`NSURLAuthenticationMethodServerTrust` 分岐で `performDefaultHandling` を呼び、iOS のシステム CA による既定検証に委ねている。

```swift
// Sora/URLSessionWebSocketChannel.swift:261-264
switch authMethod {
case NSURLAuthenticationMethodServerTrust:
  // デフォルト処理
  completionHandler(.performDefaultHandling, nil)
```

このため、システム CA で検証できないサーバー証明書 (自前 CA で署名された証明書など) の場合、ユーザーが CA 証明書を指定しても WebSocket シグナリング接続は確立できない。

## 設計方針

- `NSURLAuthenticationMethodServerTrust` 分岐に、ユーザー指定 CA 証明書を用いたカスタム検証処理を追加する。
- ユーザー指定の CA 証明書が無い場合は、現状どおり `performDefaultHandling` (システム CA 検証) にフォールバックする。後方互換性を維持する。
- ユーザー指定の CA 証明書がある場合は、`challenge.protectionSpace.serverTrust` から `SecTrust` を取得し、`SecTrustSetAnchorCertificates` で指定 CA をアンカーに設定したうえで `SecTrustEvaluateWithError` で検証する。検証成功時は `completionHandler(.useCredential, URLCredential(trust:))`、失敗時は `cancelAuthenticationChallenge` で接続を中止する。
- `URLSession` 経由の WebSocket 接続は ATS (App Transport Security) の影響を受ける。検証ロジックが通っても ATS でブロックされる場合があるため、ATS 回避が必要かどうかを動作確認で確認する。
- ユーザー指定 CA 証明書を受け取る公開 API の追加は本 issue の範囲外とし、本 issue では検証処理の実装を行う。

## 完了条件

- ユーザー指定の CA 証明書で署名されたサーバー証明書を持つ Sora サーバーに、WebSocket シグナリングで接続できること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で接続できること (後方互換性が保たれている)。
- 不正・期限切れ・指定 CA で検証できないサーバー証明書の場合は接続が失敗すること。
- ATS の影響有無を確認し、必要であれば回避方法 (対象ドメインの ATS 例外設定) を整理すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] WebSocket シグナリングでユーザー指定の CA 証明書を検証できるようにする
    - @担当者
  ```

## 解決方法
