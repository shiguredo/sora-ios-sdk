# Sora iOS SDK

[![CircleCI branch](https://img.shields.io/circleci/project/github/shiguredo/sora-ios-sdk/develop.svg)](https://github.com/shiguredo/sora-ios-sdk) 
[![GitHub tag](https://img.shields.io/github/tag/shiguredo/sora-ios-sdk.svg)](https://github.com/shiguredo/sora-ios-sdk)

Sora iOS SDK は [WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリです。

使い方は [Sora iOS SDK ドキュメント](https://sora.shiguredo.jp/ios-sdk-doc/) を参照してください。

## About Support

Support for Sora iOS SDK by Shiguredo Inc. are limited
**ONLY in JAPANESE** through GitHub issues and there is no guarantee such
as response time or resolution.

## サポートについて

Sora iOS SDK に関する質問・要望・バグなどの報告は Issues の利用をお願いします。
ただし、 Sora のライセンス契約の有無に関わらず、 Issue への応答時間と問題の解決を保証しませんのでご了承ください。

Sora iOS SDK に対する有償のサポートについては現在提供しておりません。

## システム条件

- iOS 10.0 以降
- アーキテクチャ arm64, x86_64 (シミュレーターの動作は未保証)
- macOS 10.14.4 以降
- Xcode 11.0
- Swift 5.1
- Carthage 0.33.0 以降、または CocoaPods 1.6.1 以降
- WebRTC SFU Sora 19.04.0 以降

Xcode と Swift のバージョンによっては、 Carthage と CocoaPods で取得できるバイナリに互換性がない可能性があります。詳しくはドキュメントを参照してください。

## サンプル

- [クイックスタート](https://github.com/shiguredo/sora-ios-sdk-quickstart)
- [サンプル集](https://github.com/shiguredo/sora-ios-sdk-samples)

## Issues について

質問やバグ報告の場合は、次の開発環境のバージョンを **「メジャーバージョン、マイナーバージョン、メンテナンスバージョン」** まで含めて書いてください (8.3.1 など) 。
これらの開発環境はメンテナンスバージョンの違いでも Sora iOS SDK の挙動が変わる可能性があります。

- Sora iOS SDK
- Mac OS X
- Xcode
- Swift
- iOS
- Carthage

## ライセンス

Apache License 2.0

```
Copyright 2017-2019, Shiguredo Inc. and Masashi Ono (akisute)

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
