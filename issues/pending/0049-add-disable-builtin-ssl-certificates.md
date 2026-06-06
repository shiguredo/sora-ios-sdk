# iOS SDK 向け libwebrtc ビルドで組み込み証明書を無効化する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-disable-builtin-ssl-certificates
- Polished:

## 概要

GN オプション `rtc_builtin_ssl_root_certificates = false` を iOS SDK 向け libwebrtc ビルドに適用し、libwebrtc の組み込み SSL ルート証明書を無効化する。

## 背景

WebRTC-Build では iOS / Android SDK 向けビルドの分岐内でのみこの GN オプションを設定できる。これにより C++ SDK 向けビルドには影響を与えずに iOS / Android SDK でのみ組み込み証明書を無効化できる。

`0020`（WebSocket CA 証明書）・`0021`（TURN-TLS CA 証明書）の実装において、SDK 側でユーザー指定の CA 証明書を使って検証する際に libwebrtc の組み込み証明書が干渉しないようにするために必要。

参考: https://github.com/shiguredo-webrtc-build/webrtc-build/pull/106

## 実装状況

### iOS SDK 側（完了済み）

`IOSCertificateVerifier` が実装済み。ICE サーバーに `turns:` URL があり `tlsSecurityPolicy` が `.secure` の場合、libwebrtc の組み込み検証を使わず iOS システム CA で TURN-TLS 証明書チェーンを検証する（`Sora/IOSCertificateVerifier.swift`）。

`ios_ssl_certificate_verifier_chain.patch`（`verifyChain` メソッドの追加）も WebRTC-Build の `ios_sdk` ビルドに適用済み。

### WebRTC-Build 側（未着手）

`run.py` の `IOS_COMMON_GN_ARGS` および `build_webrtc_ios_sdk` 関数には `rtc_builtin_ssl_root_certificates = false` がまだ追加されていない。現在の libwebrtc バイナリには組み込み証明書がコンパイルされたまま。

## 残作業

- WebRTC-Build の `run.py` にて `build_webrtc_ios_sdk` 向けの GN オプションに `rtc_builtin_ssl_root_certificates = false` を追加し PR を提出する
- 無効化後に `0020`・`0021`・`0022` と組み合わせた動作を確認する

本 issue は iOS SDK に関わる変更のみを対象とする。Android SDK 対応は別途行う。

## 根拠

組み込み証明書が有効なままでは、ユーザー指定の CA 証明書による検証とのコンフリクトが生じる恐れがある。`0020`/`0021`/`0022` の実装と合わせて、カスタム CA 検証が正しく機能する環境を整えるために必要。
