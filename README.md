# Sora iOS SDK

[![libwebrtc](https://img.shields.io/badge/libwebrtc-m97.4692-blue.svg)](https://chromium.googlesource.com/external/webrtc/+/branch-heads/4692
[![GitHub tag](https://img.shields.io/github/tag/shiguredo/sora-ios-sdk.svg)](https://github.com/shiguredo/sora-ios-sdk)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Sora iOS SDK は [WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリです。

## About Shiguredo's open source software

We will not respond to PRs or issues that have not been discussed on Discord. Also, Discord is only available in Japanese.

Please read https://github.com/shiguredo/oss before use.

## 時雨堂のオープンソースソフトウェアについて

利用前に https://github.com/shiguredo/oss をお読みください。

## システム条件

- iOS 13 以降
- アーキテクチャ arm64, x86_64 (シミュレーターの動作は未保証)
- macOS 12.2 以降
- Xcode 13.2
- Swift 5.5.2
- CocoaPods 1.11.2 以降
- WebRTC SFU Sora 2021.2 以降

Xcode と Swift のバージョンによっては、 CocoaPods で取得できるバイナリに互換性がない可能性があります。詳しくはドキュメントを参照してください。

## バージョン 2022.2.1 は暫定対処版です

バージョン 2022.2.1 は CocoaPods を利用して Sora iOS SDK を利用している場合、App Store Connect に bitcode を有効にしてアップロードができない不具合に対処するために、依存ライブラリ (WebRTC) のバージョンを下げて提供した暫定対処版となります。
以下の条件に当てはまらない方についてはバージョン 2022.2.0 の利用を推奨します。

- Cocoa Pods を利用して Sora iOS SDK を利用しており、bitcode を有効にして App Store Connect にアップロードを行う必要がある

詳細はドキュメントをご確認ください。
- [Sora iOS SDK が CocoaPods を利用した時、 bitcode を有効にしてビルドしたバイナリが App Store Connect にアップロードできない](https://sora-ios-sdk.shiguredo.jp/notes#038191)


## サンプル

- [クイックスタート](https://github.com/shiguredo/sora-ios-sdk-quickstart)
- [サンプル集](https://github.com/shiguredo/sora-ios-sdk-samples)

## ドキュメント

[Sora iOS SDK ドキュメント — Sora iOS SDK](https://sora-ios-sdk.shiguredo.jp/)

## ライセンス

Apache License 2.0

```
Copyright 2017-2022, SUZUKI Tetsuya (Original Author)
Copyright 2017-2022, Shiguredo Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
