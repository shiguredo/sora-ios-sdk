# SDK 側の TLS 証明書チェックを無効にするオプションを追加する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-insecure-tls-option
- Polished:

## 概要

開発・検証環境での自己署名証明書の利用など、TLS 証明書の検証をスキップしたいケースのために、SDK 側で証明書チェックを無効にするオプションを追加する。

## 対象経路

### WebSocket シグナリング（wss）

- `URLSession` の `URLSessionDelegate` で `NSURLAuthenticationMethodServerTrust` チャレンジを受け取った際に、証明書チェックをスキップして接続を許可する
- 現状は `performDefaultHandling` を呼んでおり、自己署名証明書の場合に接続エラーとなる（`URLSessionWebSocketChannel.swift`）

### libwebrtc（TURN-TLS）

- libwebrtc 内部の SSL 検証をスキップするには `sdk/objc` へのパッチが必要
- `RTCSSLAdapter` 等の経路を調査し、検証スキップを可能にする方法を確認する

## 設計方針

`Configuration` に `insecure: Bool` オプションを追加する。

```swift
// Configuration への追加案
var insecure: Bool = false
```

- デフォルトは `false`（証明書チェックあり）
- `true` にした場合は wss・TURN-TLS 双方の証明書チェックをスキップする
- 本番環境での利用を防ぐためログに警告を出力する

## 注意

本オプションはセキュリティリスクを伴うため、開発・テスト目的のみで使用すること。CA 証明書を指定した検証（`0022` 参照）が可能な場合はそちらを優先する。

## 根拠

開発・検証環境では自己署名証明書を使うケースが多く、証明書チェックを無効にする手段がないと接続確認すらできない。Momo など時雨堂の他製品でも `insecure` オプションとして提供されており、SDK でも同様の機能が求められている。
