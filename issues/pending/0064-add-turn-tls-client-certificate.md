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

## Pending 理由

バンドルしている libwebrtc（WebRTC.xcframework）の Objective-C API に TURN-TLS のクライアント証明書（mTLS）を渡す経路が存在しないため、現時点では実装不可能。

具体的に確認した API:

- `RTCPeerConnectionFactory` の `peerConnectionWithConfiguration:` オーバーロード: `certificateVerifier:` のみを受け付け、クライアント証明書パラメーターなし
- `RTCConfiguration.certificate`: DTLS（メディア暗号化）用の自己署名証明書であり、TURN-TLS クライアント証明書とは別物
- `RTCIceServer`: `tlsCertPolicy` / `hostname` のみで、クライアント証明書フィールドなし
- `RTCSSLCertificateVerifier`: サーバー証明書検証コールバックであり、クライアント証明書送出の仕組みではない

実現するには libwebrtc の C++ 内部（`cricket::TurnPort` または `rtc::OpenSSLAdapter`）への追加実装と Objective-C ブリッジの公開が必要。shiguredo-webrtc-build（m148.7778.7.0）が当該 API を公開するようになった時点で本 issue を再評価すること。
