# TURN-TLS でクライアント証明書を指定する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-turn-tls-client-certificate
- Polished:

## 概要

TURN-TLS 接続においてクライアント証明書（秘密鍵 + 証明書）を指定できるようにする。クライアント認証が必要な環境での TURN-TLS 利用を可能にする。

## 依存関係

- `0022-add-user-ca-certificate`：クライアント証明書の指定 API は 0022 の公開 API 設計に合わせること
- `0021-add-turn-tls-ca-certificate`：TURN-TLS の証明書検証処理を実装した 0021 と合わせて実装すること

## 設計方針

Unity SDK の実装（`ClientCert`・`ClientKey`）を参考にする。

`Configuration` へのクライアント証明書・秘密鍵プロパティの追加は `0063-add-websocket-client-certificate` と共通の設計にする。両 issue は同じ `Configuration` の API を共有するため、先に 0063 の設計を確定させてから 0064 を実装すること。

TURN-TLS のクライアント証明書は libwebrtc 内部の SSL ハンドシェイクで使用される。libwebrtc の `RTCConfiguration` または PeerConnection 生成時にクライアント証明書を渡す経路を確認する。

## 根拠

TURN-TLS における mTLS 認証が必要なネットワーク環境が存在する。WebSocket（0063）と TURN-TLS（本 issue）の両方でクライアント証明書を指定できることで、完全なカスタム PKI 環境での接続が実現できる。
