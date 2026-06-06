# WebSocket シグナリングでクライアント証明書を指定できるようにする

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-websocket-client-certificate
- Polished:

## 概要

WebSocket シグナリング接続においてクライアント証明書（秘密鍵 + 証明書）を指定できるようにする。クライアント認証が必要な環境（企業内 mTLS 環境など）での接続を可能にする。

## 依存関係

- `0022-add-user-ca-certificate`：クライアント証明書の指定 API は CA 証明書の公開 API と同じ `Configuration` に追加するため、0022 の設計に合わせること
- `0020-add-websocket-ca-certificate`：WebSocket の証明書検証処理を実装した 0020 と合わせて実装すること

## 設計方針

Unity SDK の実装（`ClientCert`・`ClientKey`）を参考にする。

`Configuration` にクライアント証明書と秘密鍵を指定するプロパティを追加する。

```swift
// Configuration への追加案
var clientCertificate: SecCertificate?
var clientPrivateKey: SecKey?
```

または PEM 文字列で受け取って内部で変換する設計とする。0022 の型設計と統一すること。

`URLSessionWebSocketChannel` の `URLSessionDelegate` にて `NSURLAuthenticationMethodClientCertificate` チャレンジを処理し、指定されたクライアント証明書を `URLCredential` として返す。

## 根拠

クライアント証明書による相互 TLS（mTLS）認証は企業内システムとの連携で求められるケースがある。CA 証明書指定機能（0022）と組み合わせることで、完全なカスタム PKI 環境での接続が可能になる。
