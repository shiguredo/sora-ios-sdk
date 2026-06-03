# ユーザーが CA 証明書を指定するための公開 API を追加する

- Priority: High
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-user-ca-certificate

## 目的

企業内で自前のプライベート CA を利用している環境向けに、サーバー証明書検証用の CA 証明書をユーザーが指定できる公開 API を `Configuration` に追加する。指定された CA 証明書は WebSocket シグナリング経路と TURN-TLS 経路の両方の証明書検証で共通利用する。

本 issue は CA 証明書を受け取る公開 API の設計・追加に限定し、実際の検証処理は各経路の実装で行う。

## 依存関係

本 issue で追加する公開 API は、`0020-add-websocket-ca-certificate` (WebSocket シグナリングの証明書検証) と `0021-add-turn-tls-ca-certificate` (TURN-TLS の証明書検証) の前提となる。本 issue が無いと両者の検証処理をユーザーが利用できないため、先行して着手すること。

## 優先度根拠

- この「ユーザーが CA 証明書を指定する公開 API」は、WebSocket シグナリング経路と TURN-TLS 経路の証明書検証実装が利用する唯一の入口である。
- この公開 API が無いと、ユーザーは WebSocket シグナリングと TURN-TLS の証明書検証機能を一切利用できない。検証機能全体の唯一のブロッカーであるため最優先 (High) とする。

## 現状

`Configuration` には接続に必要な各種設定が公開プロパティとして定義されているが、CA 証明書を指定するプロパティは存在しない。

```swift
// Sora/Configuration.swift:216-225
/// プロキシに関する設定
public var proxy: Proxy?

/// 転送フィルターの設定
///
/// この項目は 2025 年 12 月リリース予定の Sora にて廃止されます
public var forwardingFilter: ForwardingFilter?

/// リスト形式の転送フィルターの設定
public var forwardingFilters: [ForwardingFilter]?
```

証明書検証は経路ごとに独立しており、いずれもシステム CA による検証のみで、ユーザー指定 CA を受け取る入口が無い。

WebSocket シグナリングは `NSURLAuthenticationMethodServerTrust` 分岐で `performDefaultHandling` (システム CA 検証) を行っている。

```swift
// Sora/URLSessionWebSocketChannel.swift:262-264
case NSURLAuthenticationMethodServerTrust:
  // デフォルト処理
  completionHandler(.performDefaultHandling, nil)
```

TURN-TLS は `IOSCertificateVerifier` がシステム CA で証明書チェーンを検証している。

```swift
// Sora/IOSCertificateVerifier.swift:58-59
var error: CFError?
return SecTrustEvaluateWithError(trust, &error)
```

iOS の Security フレームワークが扱う証明書は `SecCertificate` (DER) であり、PEM 文字列で受け取る場合は `SecCertificate` への変換を考慮する必要がある。

## 設計方針

- `Configuration` に CA 証明書を指定する公開プロパティ (例: `caCertificate`) を追加する。
- 指定形式は PEM 文字列を基本とし、PEM から `SecCertificate` (DER) への変換処理を SDK 内で行う。
- 追加するプロパティはオプショナルとし、未指定 (nil) の場合は従来どおりシステム CA による検証を行う。後方互換性を維持する。
- 指定された CA 証明書を、WebSocket シグナリング経路と TURN-TLS 経路の両検証経路に渡す配線を行う。両経路で同一の CA を共通利用する。
- X.509 形式ではない、もしくは壊れた CA 証明書が指定された場合の挙動を定義する (パース失敗時にエラーとするか、検証失敗として扱うか)。

## 完了条件

- `Configuration` に CA 証明書を指定する公開プロパティが追加されていること。
- 指定した CA 証明書が WebSocket シグナリングと TURN-TLS の両検証経路に渡ること。
- CA 証明書を指定しない場合は、従来どおりシステム CA による検証で接続できること (後方互換性が保たれている)。
- 不正な形式 (X.509 でない / 壊れている) の CA 証明書が指定された場合の挙動が定義され、明確なエラーになること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] Configuration にサーバー証明書検証用の CA 証明書を指定する公開プロパティを追加する
    - @担当者
  ```

## 解決方法
