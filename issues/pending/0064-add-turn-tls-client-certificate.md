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

- `webrtc-build` の `issues/0023-add-ios-turn-tls-client-certificate.md`：iOS の ObjC ブリッジ (`RTCIceServer`) にクライアント証明書を渡す API を追加するパッチ。本 issue はこのパッチが取り込まれるまで着手できない
- `0022-add-user-ca-certificate`：クライアント証明書の指定 API は 0022 の公開 API 設計に合わせること
- `0021-add-turn-tls-ca-certificate`：TURN-TLS の証明書検証処理を実装した 0021 と合わせて実装すること

## 設計方針

Unity SDK の実装（`ClientCert`・`ClientKey`）を参考にする。

`Configuration` へのクライアント証明書・秘密鍵プロパティの追加は `0063-add-websocket-client-certificate` と共通の設計にする。両 issue は同じ `Configuration` の API を共有するため、先に 0063 の設計を確定させてから 0064 を実装すること。

TURN-TLS のクライアント証明書は libwebrtc 内部の SSL ハンドシェイクで使用される。現行の ObjC API では `ICEServerInfo.nativeValue` が生成する `RTCIceServer` の `nativeServer` が native の `PeerConnectionInterface::IceServer` を組み立てる。webrtc-build の `ios_turn_tls_client_certificate.patch`（0023）で `RTCIceServer` にクライアント証明書 (PEM) を渡す経路が追加されるため、SDK 側はここへ証明書と秘密鍵を渡す設計にする。

## 根拠

TURN-TLS における mTLS 認証が必要なネットワーク環境が存在する。WebSocket（0063）と TURN-TLS（本 issue）の両方でクライアント証明書を指定できることで、完全なカスタム PKI 環境での接続が実現できる。

## Pending 理由

libwebrtc (C++) 側の実装は完了している。`turn_tls_client_certificate.patch` (https://github.com/shiguredo-webrtc-build/webrtc-build/pull/146) で `PeerConnectionInterface::IceServer::tls_client_identity` が追加され、`RelayServerConfig` / `TurnPort` / `SSLAdapter::SetIdentity()` まで伝搬する。

一方、現行の `WebRTC.xcframework` が公開する Objective-C API には TURN-TLS のクライアント証明書を渡す経路がなく、この状態では実装できない。具体的に確認した API:

- `RTCIceServer`: `tlsCertPolicy` / `hostname` / `tlsAlpnProtocols` / `tlsEllipticCurves` のみで、クライアント証明書を受け取るプロパティ・初期化子がない
- `RTCConfiguration.certificate`: DTLS（メディア暗号化）用の自己署名証明書であり、TURN-TLS クライアント証明書とは別物
- `RTCSSLCertificateVerifier`: サーバー証明書検証コールバックであり、クライアント証明書送出の仕組みではない
- `RTCPeerConnectionFactory` の `peerConnectionWithConfiguration:` オーバーロード: `certificateVerifier:` のみを受け付け、クライアント証明書パラメーターなし

不足しているのは ObjC ブリッジ (`RTCIceServer` → `nativeServer` → `IceServer::tls_client_identity`) のみで、webrtc-build に `issues/0023-add-ios-turn-tls-client-certificate.md` として起票済み。このパッチが取り込まれた時点で本 issue を再評価する。

iOS SDK が `libwebrtc_c.xcframework` (webrtc_c) へ移行すれば C++ API に直接アクセスできるため ObjC ブリッジは不要になるが、移行は当面先のため、現行 `WebRTC.xcframework` 向けの ObjC パッチで対応する。
