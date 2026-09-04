# Sora iOS SDK

[![libwebrtc](https://img.shields.io/badge/libwebrtc-150.7871-blue.svg)](https://chromium.googlesource.com/external/webrtc/+/branch-heads/7871)
[![GitHub tag](https://img.shields.io/github/tag/shiguredo/sora-ios-sdk.svg)](https://github.com/shiguredo/sora-ios-sdk)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Sora iOS SDK は [WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリです。

## About Shiguredo's open source software

We will not respond to PRs or issues that have not been discussed on Discord. Also, Discord is only available in Japanese.

Please read https://github.com/shiguredo/oss before use.

## 時雨堂のオープンソースソフトウェアについて

利用前に https://github.com/shiguredo/oss をお読みください。

## 特徴

- [libwebrtc](https://webrtc.googlesource.com/src/) を利用した iOS SDK
- [WebRTC 統計情報](https://www.w3.org/TR/webrtc-stats/) の取得に対応 (`MediaChannel.getStats`)
- 回線が不安定な際に、解像度とフレームレートの優先度を指定する `DegradationPreference` に対応
  - `.maintainFramerate` / `.maintainResolution` / `.balanced` / `.disabled` を指定可能
- 映像コーデック `VP8` / `VP9` / `AV1` / `H.264` / `H.265` に対応
  - `H.264` / `H.265` は Apple Video Toolbox によるハードウェアデコーダー/エンコーダーを利用
- 音声トラックを無効にし、デジタルサイレンスパケットを送出するミュート(ソフトミュート)を利用できる
- 映像トラックを無効にし、黒塗りの映像パケットを送出するミュート(ソフトミュート)を利用できる
- 音声・映像のプライバシーインジケーターを消灯するミュート(ハードミュート)を利用できる
  - 接続時にハードミュート状態にできる
- フロント / リアカメラ切り替えとキャプチャフォーマット変更に対応
- 各種カメラ設定を利用できる
  - 解像度・フレームレート・フロントカメラ優先
- 受信した音声データを PCM 形式で取得できる
- ステレオ音声出力に対応

## ステレオ音声出力

`Configuration.audioStereoOutputEnabled` を `true` にすると、Sora から受信した Opus 音声をステレオで再生できます。既定値は `false` であり、従来のモノラル音声出力を維持します。

```swift
var configuration = Configuration(
  urlCandidates: [url],
  channelId: channelId,
  role: .recvonly)
configuration.audioStereoOutputEnabled = true
```

ステレオ音声出力には次の制約があります。

- Voice Processing I/O の代わりに RemoteIO を利用するため、AEC と AGC は利用できない
- `MediaChannel.setAudioHardMute(_:)` は利用できない
- `Configuration.bypassVoiceProcessing` の指定は無視される
- `recvonly` でも AudioSession のカテゴリに `playAndRecord` を利用するため、マイク権限が必要
- 送信側ロールでは `initialMicrophoneEnabled` に `false` を指定できない
- `audioEnabled` に `false` を指定した場合、または音声コーデックに PCMU を指定した場合は利用できない。`.default` を指定した場合も、Answer の有効な音声メディアセクションに Opus がなければ接続に失敗する
- WebRTC-Build m150.7871.3.2 では Sora iOS SDK が管理する音声接続全体でステレオ接続を 1 つだけ利用でき、他の音声接続とは同時に利用できない
- Bluetooth HFP ではモノラルになる。アプリが `.allowBluetoothA2DP` を許可し、A2DP route が選択された場合はステレオ出力を利用できるが、SDK は route を自動で切り替えない
- 接続後に `Sora.setAudioMode(.voiceChat(...))` を呼ぶと、OS によってモノラル出力へ切り替わる可能性がある

## システム条件

- iOS 14 以降
- アーキテクチャ arm64 (シミュレーターの動作は未保証)
- Xcode 26.2
  - Swift 6 言語モードでビルドしています
- WebRTC SFU Sora 2025.2.0 以降

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
Copyright 2017 Shiguredo Inc.
Copyright 2017 SUZUKI Tetsuya (Original Author)

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
