# SDK 側の TLS 証明書チェックを無効にするオプションを追加する

- Priority: Medium
- Created: 2026-06-06
- Completed: 2026-07-31
- Model: Sonnet 4.6
- Branch: feature/add-insecure-tls-option
- Polished:

## 概要

開発・検証環境での自己署名証明書の利用など、TLS 証明書の検証をスキップしたいケースのために、SDK 側で証明書チェックを無効にするオプションを追加する。

## 評価結果

実装価値はあるため issue は維持してよい。ただし、現状の issue 本文には実装前提の誤りがあるため、そのまま着手すると設計を誤る。

- WebSocket シグナリング（wss）の `insecure` は未実装であり、本 issue の主対象として妥当
- TURN-TLS 側は未実装ではなく、すでに `TLSSecurityPolicy.insecure` と `RTCIceServer.tlsCertPolicy = .insecureNoCheck` の経路が存在する
- しかし `TLSSecurityPolicy` と `ICEServerInfo.tlsSecurityPolicy` は public API であり、`Configuration.insecure` と二重管理になる
- そのため `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` を deprecated とし、`Configuration.insecure` に一本化する
- Android SDK と同様の公開 API 設計 (`insecure: Boolean`) に統一する

## 対象経路

### WebSocket シグナリング（wss）

- `URLSession` の `URLSessionDelegate` で `NSURLAuthenticationMethodServerTrust` チャレンジを受け取った際に、証明書チェックをスキップして接続を許可する
- 現状は `performDefaultHandling` を呼んでおり、自己署名証明書の場合に接続エラーとなる（`URLSessionWebSocketChannel.swift`）

### libwebrtc（TURN-TLS）

- `TLSSecurityPolicy` を介さず、`Configuration.insecure` から直接 `RTCTlsCertPolicy.insecureNoCheck` を設定する
- `ICEServerInfo.usesVerifiedTURNTLS` は `insecure == true` の場合 `false` を返すため、`IOSCertificateVerifier` を使った追加検証も無効化される
- `ICEServerInfo.tlsSecurityPolicy` は deprecated とし、`Configuration.insecure` に集約する

## 依存関係

- `0022-add-user-ca-certificate`：CA 証明書指定 API と優先順位を揃えること。`TLSSecurityPolicy` 非推奨化の影響を確認すること
- `0063-add-websocket-client-certificate`：WebSocket の `URLSessionDelegate` に TLS 分岐を追加するため、同一箇所の競合に注意すること
- `0049-add-disable-builtin-ssl-certificates`：本 issue 自体の実装必須条件ではないが、TURN-TLS の検証経路を整理する文脈で参照が必要。`TLSSecurityPolicy` 非推奨化に伴う影響を確認すること

## 設計方針

`Configuration` に `insecure: Bool` オプションを追加する。

```swift
// Configuration への追加案
var insecure: Bool = false
```

- デフォルトは `false`（証明書チェックあり）
- `true` にした場合は wss・TURN-TLS 双方の証明書チェックをスキップする
- 本番環境での利用を防ぐためログに警告を出力する

### 非推奨化と移行方針

- `TLSSecurityPolicy` は deprecated とし、新規コードでは使用しない
- `ICEServerInfo.tlsSecurityPolicy` は deprecated とし、新規コードでは設定しない
- 既存利用者には `Configuration.insecure` への移行を案内する
- `TLSSecurityPolicy.insecure` を使っていたコードは `Configuration.insecure = true` へ置き換える
- `TLSSecurityPolicy.secure` を明示していたコードは削除し、`Configuration.insecure` のデフォルト値 `false` に委ねる
- 互換性維持のため、deprecated API は当面残すが、内部実装の正本は `Configuration.insecure` のみにする
- deprecated API と `Configuration.insecure` が同時に使われた場合は、`Configuration.insecure` を常に優先する

### 優先順位

Android SDK と同じく、`insecure` を最優先にする。

- `insecure == true` の場合は、`caCertificate` が指定されていてもサーバー証明書検証をスキップする
- `insecure == false` かつ `caCertificate != nil` の場合は、システム CA を使わず指定 CA のみで検証する
- `insecure == false` かつ `caCertificate == nil` の場合は、システム既定の検証を行う

### iOS 側の具体方針

- `Configuration` に `public var insecure: Bool = false` を追加する
- `SignalingChannel` で `configuration.insecure` を `URLSessionWebSocketChannel` に渡す
- `URLSessionWebSocketChannel` に `insecure: Bool` プロパティを追加し、`NSURLAuthenticationMethodServerTrust` 受信時に `insecure == true` なら `URLCredential(trust:)` を返して接続を許可する
- `TURN-TLS` については、`WebRTCConfiguration` に internal な `isInsecure: Bool` を追加し、`nativeValue` 算出時に直接 `RTCTlsCertPolicy.insecureNoCheck` を設定する。`TLSSecurityPolicy` を経由しない
- **`TLSSecurityPolicy` と `ICEServerInfo.tlsSecurityPolicy` を deprecated にする**
  - `@available(*, deprecated, message: "Configuration.insecure を使用してください")` を付与
  - `TLSSecurityPolicy` の enum case 自体は残すが、新規利用は案内しない
  - `ICEServerInfo.tlsSecurityPolicy` は互換性のため保持するが、内部では使用しない
  - `WebRTCConfiguration.isInsecure` を正本とし、`nativeValue` で直接 `RTCTlsCertPolicy` を決定する
- Android SDK と同様に、公開 API は `Bool` 一つのみで制御する設計に統一する

### ログ方針

- `insecure == true` で接続を開始する際は、WebSocket と TURN-TLS の両方で警告ログを出す
- ログメッセージは英語にする

## 現状（実装後）

- `Configuration.insecure` が実装され、WebSocket / TURN-TLS 両経路に反映済み
- `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` は deprecated（2027 年中に廃止予定）
- `URLSessionWebSocketChannel.resolveServerTrustDisposition()` により認証チャレンジの判定がテスト可能
- `WebRTCConfigurationTests` が新設され、優先順位・エッジケースをカバー
- `redirect()` にも insecure 警告ログを追加済み

## テスト方針

モック・スタブは使用しない。

- `ConfigurationTests` に `insecure` のデフォルト値が `false` であることを追加する
- `TLSSecurityPolicy` と `ICEServerInfo.tlsSecurityPolicy` に deprecated 属性が付与され、移行メッセージが正しいことをコンパイルで確認する
- `SignalingE2ETests` または実機検証で、自己署名証明書の `wss://` に対して `insecure = true` で接続できることを確認する
- 同条件で `insecure = false` の場合は接続に失敗することを確認する
- `caCertificate` を指定していても `insecure = true` が優先されることを確認する
- `turns:` を返す環境で `insecure = true` のとき TURN-TLS 接続が成立することを確認する
- 既存の `caCertificate` 利用パスが回帰していないことを確認する
- deprecated API と `Configuration.insecure` を同時指定した場合に、`Configuration.insecure` が優先されることを確認する

## 完了条件

- `Configuration` に `public var insecure: Bool = false` が追加されていること
- `URLSessionWebSocketChannel` が `insecure` を受け取り、`NSURLAuthenticationMethodServerTrust` で検証スキップできること
- `Configuration.insecure` が TURN-TLS 側で直接 `RTCTlsCertPolicy.insecureNoCheck` に反映されること
- `TLSSecurityPolicy` が deprecated になっていること
- `ICEServerInfo.tlsSecurityPolicy` が deprecated になっていること
- deprecated メッセージで `Configuration.insecure` への移行先が案内されていること
- deprecated API と `Configuration.insecure` が同時指定された場合でも `Configuration.insecure` が優先されること
- `insecure` と `caCertificate` の優先順位が issue 記載どおりに統一されていること
- `insecure` 有効時に警告ログが出ること
- テスト方針に記載した確認が完了していること
- `CHANGES.md` の `## develop` セクションに以下を追記すること

```md
- [ADD] WebSocket シグナリングと TURN-TLS で insecure モードを利用できるようにする
  - `insecure = true` の場合はサーバー証明書の検証をスキップする
  - `TLSSecurityPolicy` と `ICEServerInfo.tlsSecurityPolicy` を非推奨化し、`Configuration.insecure` に一本化する
  - @voluntas
```

## 注意

本オプションはセキュリティリスクを伴うため、開発・テスト目的のみで使用すること。CA 証明書を指定した検証（`0022` 参照）が可能な場合はそちらを優先する。

## 根拠

開発・検証環境では自己署名証明書を使うケースが多く、証明書チェックを無効にする手段がないと接続確認すらできない。Momo など時雨堂の他製品でも `insecure` オプションとして提供されており、SDK でも同様の機能が求められている。

## 解決

### 設計の最終形

- **公開 API**: `Configuration.insecure: Bool = false` のみ。Android SDK と統一
- **WebSocket 側**: `SignalingChannel` → `URLSessionWebSocketChannel.insecure` で伝搬。`NSURLAuthenticationMethodServerTrust` 受信時に `resolveServerTrustDisposition()` で判定（skipVerification / customCAVerification / defaultHandling）
- **TURN-TLS 側**: `PeerChannel` → `WebRTCConfiguration.isInsecure` (internal) → `ICEServerInfo.nativeValue(insecure:)` → `RTCTlsCertPolicy.insecureNoCheck`
- **`usesVerifiedTURNTLS`**: `WebRTCConfiguration.usesVerifiedTURNTLS` が `isInsecure` を最優先でチェック。`ICEServerInfo.usesVerifiedTURNTLS` は `tlsSecurityPolicy == .insecure` の後方互換チェックも保持

### 非推奨化

- `TLSSecurityPolicy` enum 全体と各 case に `@available(*, deprecated)` を付与（2027 年中に廃止予定）
- `ICEServerInfo.tlsSecurityPolicy` プロパティに `@available(*, deprecated)` を付与（2027 年中に廃止予定）
- `ICEServerInfo.init(urls:userName:credential:tlsSecurityPolicy:)` に `@available(*, deprecated)` を付与
- 非推奨でない `ICEServerInfo.init(urls:userName:credential:)` を新設（デフォルト `.secure`）
- `Codable.init(from:)` は新 init を使用

### 初期設計からの差分

| 項目 | 初期設計 | 最終形 |
|---|---|---|
| `TLSSecurityPolicy` の扱い | 内部モデルとして残す | 完全に deprecated、内部でも正本は `WebRTCConfiguration.isInsecure` |
| TURN-TLS 配線 | `TLSSecurityPolicy` 経由 | `WebRTCConfiguration.isInsecure` (internal) 経由で直接 `RTCTlsCertPolicy` に変換 |
| `ICEServerInfo.nativeValue` (引数なし) | 残す | 削除（デッドコード） |
| `ICEServerInfo` init | deprecated のみ | 非推奨でない init を新設 |
| 認証チャレンジ判定 | インラインの if-else | `resolveServerTrustDisposition()` に抽出（テスト可能） |
| `redirect()` の警告ログ | なし | `connect()` と同様に追加 |
| テストファイル | `ConfigurationTests` に混在 | `WebRTCConfigurationTests` に分離 |
| 非推奨メッセージ | 廃止時期なし | "2027 年中に廃止予定" を明記 |
| CHANGES.md | 単一 `[ADD]` エントリ | `[ADD]` + `[UPDATE]` に分離 |

### 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `Sora/Configuration.swift` | `public var insecure: Bool = false` を追加 |
| `Sora/TLSSecurityPolicy.swift` | enum と全 case に `@available(*, deprecated)` を付与 |
| `Sora/ICEServerInfo.swift` | `tlsSecurityPolicy` deprecated 化、`nativeValue(insecure:)` 追加、`nativeValue` (引数なし) 削除、非推奨でない init 新設、`usesVerifiedTURNTLS` に後方互換チェック保持 |
| `Sora/WebRTCConfiguration.swift` | `isInsecure: Bool` (internal) 追加、`nativeValue` / `usesVerifiedTURNTLS` を修正 |
| `Sora/URLSessionWebSocketChannel.swift` | `insecure: Bool` 追加、`resolveServerTrustDisposition()` 抽出、認証チャレンジ分岐変更 |
| `Sora/SignalingChannel.swift` | `setUpWebSocketChannel` に insecure 伝搬、`connect()` / `redirect()` に警告ログ追加 |
| `Sora/PeerChannel.swift` | `webRTCConfiguration.isInsecure` 設定 + 警告ログ追加 |
| `SoraTests/ConfigurationTests.swift` | `testInsecureDefaultValue` 追加 |
| `SoraTests/WebRTCConfigurationTests.swift` | insecure 優先順位 + usesVerifiedTURNTLS + エッジケースのテスト (新設) |
| `SoraTests/URLSessionWebSocketChannelTests.swift` | `resolveServerTrustDisposition` のテスト追加 |
| `CHANGES.md` | `[ADD]` + `[UPDATE]` に分離して追記 |
