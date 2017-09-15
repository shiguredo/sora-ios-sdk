# Sora iOS SDK

[![CircleCI](https://circleci.com/gh/shiguredo/sora-ios-sdk/tree/develop.svg?style=svg)](https://circleci.com/gh/shiguredo/sora-ios-sdk/tree/develop)

Sora iOS SDK は [WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリです。

使い方は [Sora iOS SDK ドキュメント](https://sora.shiguredo.jp/ios-sdk-doc/) を参照してください。

## システム条件

- iOS 10.0 以降 (シミュレーターは非対応)
- Mac OS X 10.12.5 以降
- Xcode 8.3.3 以降
- Swift 3.1
- Carthage 0.23.0 以降
- WebRTC M59
- WebRTC SFU Sora 17.06 以降

## サンプル

- [クイックスタート](https://github.com/shiguredo/sora-ios-sdk-quickstart)

## サポートについて

Sora iOS SDK に関する質問・要望・バグなどの報告は Issues の利用をお願いします。
ただし、 Sora のライセンス契約の有無に関わらず、 Issue への応答時間と問題の解決を保証しませんのでご了承ください。

Sora iOS SDK に対する有償のサポートについては現在提供しておりません。

## Issues について

質問やバグ報告の場合は、次の開発環境のバージョンを **「メジャーバージョン、マイナーバージョン、メンテナンスバージョン」** まで含めて書いてください (8.3.1 など) 。
これらの開発環境はメンテナンスバージョンの違いでも Sora iOS SDK の挙動が変わる可能性があります。

- Sora iOS SDK
- Mac OS X
- Xcode
- Swift
- iOS
- Carthage

## ロードマップ

### 2.0

- スナップショット機能に対応する
- パブリッシャーに渡す映像の編集と加工に対応する
- パブリッシャーに任意の映像を渡せるようにする

### 1.2

- IPv6 に対応する
- WebRTC.Framework を M60 にアップデートする

