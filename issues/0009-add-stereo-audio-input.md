# ステレオ音声入力に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-input

## 目的

ステレオ音声の送信に対応する。ステレオマイク搭載デバイスや外部オーディオインターフェースからのステレオ入力を Sora へ送信できるようにする。現状の SDK は音声入力をモノラル前提で扱っており、ステレオ入力を構成する経路が存在しない。

## 依存関係

connect メッセージへステレオ送信パラメーター (Opus の stereo 指定) を渡す部分は、`0016-add-opus-params` で追加する `opus_params` の connect 伝達処理と実装を共通化する。

## 優先度根拠

Medium とする。ステレオ送信は利用者から求められる機能であり対応の必要性がある。一方でステレオ録音の実現には WebRTC-Build 側（ADM のステレオ録音設定・Opus エンコード設定）の対応やデバイス変更への追従、公開 API 設計の検討が必要で、即時の小規模修正では収まらない。緊急のクラッシュやデータ破壊ではないため High ではない。

## 現状

音声を含む `RTCPeerConnectionFactory` は ADM を渡して生成しているが、ADM のステレオ録音設定（`SetStereoRecording` 相当）を SDK から指定する経路は存在しない。

```swift
audioDeviceModule = RTCAudioDeviceModule(bypassVoiceProcessing: bypassVoiceProcessing)
audioDeviceModuleWrapper = AudioDeviceModuleWrapper(audioDeviceModule: audioDeviceModule)
```

`Sora/NativePeerChannelFactory.swift:46`

`AVAudioSession` の設定変更は `configureAudioSession(block:)` を通じて行え、`setPreferredInputNumberOfChannels(_:)` も対象として案内されている（`Sora/Sora.swift:284` 付近）。しかし `maximumInputNumberOfChannels` が既定で 0 を返すため、現状ではチャンネル数を 2 に設定できない。組み込みマイクからのステレオ録音には `AVAudioSession.setPreferredInput` で組み込みマイクを選択し、入力データソースの極性（`AVAudioSession.PolarPattern.stereo` 相当）と入力の向き（`setPreferredInputOrientation`）を構成する必要がある。

iOS SDK の音声関連は `Sora/AudioCodec.swift` / `Sora/AudioMode.swift` / `Sora/AudioDeviceModuleWrapper.swift` にあるが、いずれもチャンネル数（モノラル / ステレオ）を選択・指定する API を持たない。`Sora/AudioCodec.swift` は Opus のみを定義しており、ステレオ送信に必要な Opus の `stereo` / チャンネル数指定を connect メッセージへ渡す仕組みも存在しない。

## 設計方針

1. WebRTC-Build 側でステレオ入力（ADM のステレオ録音設定、Opus エンコーダのステレオ設定）が有効になっていることを前提条件として確認する。未整備なら本対応は WebRTC-Build 側対応待ちとなる。
2. ステレオ録音を有効化する入力構成（組み込みマイク選択、入力データソースのステレオ極性設定、入力の向き設定、`setPreferredInputNumberOfChannels(2)`）を SDK としてどう提供するかを設計する。`configureAudioSession(block:)` を利用するアプリ側手順で足りるか、SDK に専用 API を追加するかを判断する。
3. デバイス変更（ルート変更）への追従が必要になる。ルート変更通知を受けて入力構成を再適用するハンドリングを設計する。
4. connect メッセージで音声のステレオ送信を要求する必要がある場合は、`SignalingConnect` の音声パラメーターへ該当キーを追加し、Sora 仕様に合わせる。connect メッセージへの伝達は「## 依存関係」のとおり `opus_params` の実装と共通化する。
5. ADM 側のステレオ録音設定（`SetStereoRecording`）が必要な場合、libwebrtc の Objective-C レイヤーに該当 API がないため、SDK から呼び出すための橋渡し実装の要否を確認する。
6. 後方互換性: 既定はモノラルとし、明示的にステレオを指定した場合のみ挙動が変わるようにする。既存の `configureAudioSession` や音声 API の挙動は変更しない。

## 完了条件

- ステレオ音声入力を有効にする設定または手順が `Configuration` ないし SDK API として提供されること。
- 指定時に入力チャンネル数が 2 に設定され、ステレオマイク搭載デバイスで L/R 両チャンネルの音声が Sora へ送信されること。
- 入力デバイスのルート変更が発生してもステレオ構成が維持されること。
- 既定（未指定）およびステレオ未対応デバイスではモノラルのまま従来挙動を維持すること。
- 実機でステレオ入力が Sora 側で受信できることを確認すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声入力に対応する
    - @担当者
  ```

## 解決方法
