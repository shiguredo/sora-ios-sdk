# Sora iOS SDK

[![libwebrtc](https://img.shields.io/badge/libwebrtc-138.7204-blue.svg)](https://chromium.googlesource.com/external/webrtc/+/branch-heads/7204)
[![GitHub tag](https://img.shields.io/github/tag/shiguredo/sora-ios-sdk.svg)](https://github.com/shiguredo/sora-ios-sdk)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Sora iOS SDK は [WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリです。

## About Shiguredo's open source software

We will not respond to PRs or issues that have not been discussed on Discord. Also, Discord is only available in Japanese.

Please read https://github.com/shiguredo/oss before use.

## 時雨堂のオープンソースソフトウェアについて

利用前に https://github.com/shiguredo/oss をお読みください。

## システム条件

- iOS 14 以降
- アーキテクチャ arm64 (シミュレーターの動作は未保証)
- Xcode 16.2
- Swift 5.10
- WebRTC SFU Sora 2025.1.0 以降

Xcode と Swift のバージョンによっては、 取得できるバイナリに互換性がない可能性があります。詳しくはドキュメントを参照してください。

## サンプル

- [クイックスタート](https://github.com/shiguredo/sora-ios-sdk-quickstart)
- [サンプル集](https://github.com/shiguredo/sora-ios-sdk-samples)

## ドキュメント

[Sora iOS SDK ドキュメント — Sora iOS SDK](https://sora-ios-sdk.shiguredo.jp/)

## 有償での優先実装

- 帯域幅制限時に解像度またはフレームレートのどちらを維持するか指定できるようにする機能
  - 企業名非公開

## 有償での優先実装が可能な機能一覧

**詳細は Discord またはメールにてお問い合わせください**

- オープンソースでの公開が前提
- 可能であれば企業名の公開
  - 公開が難しい場合は `企業名非公開` と書かせていただきます

### 機能

- 音声出力先変更機能

## ライセンス

Apache License 2.0

```
Copyright 2017-2024, Shiguredo Inc.
Copyright 2017-2023, SUZUKI Tetsuya (Original Author)

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
