# ステレオ音声入力に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-input
- Polished: 2026-06-05

## Pending 理由

本 issue は以下の理由により pending とする:

1. **外部依存が未確認**: WebRTC-Build 側で ADM のステレオ録音設定 (`SetStereoRecording`) および Opus エンコーダのステレオ設定が有効になっているかが未確認。有効でない場合、SDK 側の対応は WebRTC-Build 側の対応を待つ必要がある。
2. **設計判断が未決**: ステレオ入力構成を SDK の専用 API として提供するか、`configureAudioSession(block:)` を通じたアプリ側手順で済ませるかの判断がついていない。
3. **依存先 issue が未完了**: `issues/0016-add-opus-params.md` が完了しておらず、connect メッセージへの `opus_params` 伝達機構が存在しないため、ステレオパラメーターをシグナリングに含めるための土台が整っていない。

上記の前提条件が解決した時点で `issues/` に戻し、実装着手可能な状態に磨き上げる。

## 目的

ステレオ音声の送信に対応する。ステレオマイク搭載デバイスや外部オーディオインターフェースからのステレオ入力を Sora へ送信できるようにする。現状の SDK は音声入力をモノラル前提で扱っており、ステレオ入力を構成する経路が存在しない。

## 依存関係

- **`issues/0016-add-opus-params.md`**: connect メッセージへステレオ送信パラメーター (Opus の `stereo` 指定) を渡す部分は、0016 で追加する `opus_params` の connect 伝達処理に委ねる。0016 が完了していることを本 issue の着手前提条件とする。
- **WebRTC-Build**: ADM のステレオ録音設定および Opus エンコーダのステレオ設定が有効になっていること。有効でない場合、本 issue は WebRTC-Build 側の対応を待つ必要がある。

## 優先度根拠

Medium とする。ステレオ送信は利用者から求められる機能であり対応の必要性がある。一方でステレオ録音の実現には WebRTC-Build 側対応の確認、公開 API 設計の検討、0016 の完了が必要で、即時の小規模修正では収まらない。緊急のクラッシュやデータ破壊ではないため High ではない。

## 現状

### ADM のステレオ設定経路がない

音声を含む `RTCPeerConnectionFactory` は ADM を渡して生成しているが、ADM のステレオ録音設定（`SetStereoRecording` 相当）を SDK から指定する経路は存在しない。

```swift
audioDeviceModule = RTCAudioDeviceModule(bypassVoiceProcessing: bypassVoiceProcessing)
audioDeviceModuleWrapper = AudioDeviceModuleWrapper(audioDeviceModule: audioDeviceModule)
```

`Sora/NativePeerChannelFactory.swift:46`

マイク入力初期化は `PeerChannel.initializeAudioInput()` (`Sora/PeerChannel.swift:543`) で行われており、`RTCAudioSession.sharedInstance()` を操作している。ここがステレオ設定を追加する主な候補となる。

### AVAudioSession のチャンネル数設定

`AVAudioSession` の設定変更は `configureAudioSession(block:)` (`Sora/Sora.swift:284`) を通じて行え、`setPreferredInputNumberOfChannels(_:)` も対象として案内されている。`maximumInputNumberOfChannels` は現在選択されているオーディオルートのハードウェア能力を反映する `AVAudioSession` のプロパティであり、ステレオ対応デバイスが選択され有効化されていなければ 0 を返すのが仕様である。アプリ側で `configureAudioSession(block:)` 経由で `setPreferredInputNumberOfChannels(2)` を呼び出すことは既に可能だが、SDK がステレオ入力の構成手順をカプセル化した API を提供するかどうかは未決である。

### 音声関連クラスの現状

- `Sora/AudioCodec.swift`: Opus と PCMU のみ。チャンネル数や stereo 指定の概念がない。
- `Sora/AudioMode.swift`: AVAudioSession のカテゴリとモード設定のみ。チャンネル数設定は含まれない。
- `Sora/AudioDeviceModuleWrapper.swift`: `RTCAudioDeviceModule` の録音ポーズ/再開をラップしている。ステレオ録音制御 (`SetStereoRecording` 相当) の追加先として自然だが、現在はハードミュート制御のみ。
- `Sora/Signaling.swift`: `SignalingConnect` の audio エンコードは `AudioCodingKeys` として `codec_type` と `bit_rate` のみを持つ (`Signaling.swift:903-906`)。`opus_params` キーは 0016 で追加予定。

### 既存のオーディオルート変更機構

SDK は既に `SoraRTCAudioSessionDelegateAdapter` (`Sora/Sora.swift:459-490`) でオーディオルート変更を捕捉し、`SoraHandlers.onChangeAudioRoute` (`Sora/Sora.swift:24-29`) を介してユーザーに通知している。ステレオ入力のルート変更追従はこの既存機構を拡張する形で実装できる。

## 設計方針（調査・判断が必要な項目）

以下は実装着手前に結論を出すべき調査・設計判断項目である。これらが未決であることが本 issue の pending 理由の一部となっている。

1. **WebRTC-Build 側の対応状況確認**: ADM のステレオ録音設定、Opus エンコーダのステレオ設定が有効になっているか。未整備なら WebRTC-Build 側対応を待つ。
2. **API 設計の決定**: 以下のいずれかの方針を選択する:
   - `Configuration` に `audioInputChannels: Int = 1` を追加し、2 以上でステレオとする
   - `Configuration` に `audioStereoEnabled: Bool = false` を追加する
   - `configureAudioSession(block:)` 経由のアプリ側手順に任せ、SDK 側では何も追加しない
   - 選択した場合、SDK 内で `setPreferredInputNumberOfChannels(2)` を呼び出す責務をどこに持たせるか（`AudioDeviceModuleWrapper` に追加するか、`PeerChannel.initializeAudioInput()` 内で直接行うか）
3. **ルート変更への追従**: 既存の `onChangeAudioRoute` ハンドラ (`Sora/Sora.swift:24-29`) を活用し、ルート変更時にチャンネル数設定を再適用する。再適用の責務を SDK が持つか、アプリ側に委ねるかを決定する。
4. **connect メッセージへの伝達**: 0016 で追加される `opus_params` の `stereo` フィールドに委ねる。本 issue の API で設定したチャンネル数と `opus_params.stereo` の値を連動させるか独立に管理するかを決定する。
5. **ADM 側の StereoRecording 設定**: libwebrtc の Objective-C レイヤーに `SetStereoRecording` 相当の API が存在するか確認する。存在しない場合、`AudioDeviceModuleWrapper` に C++ レイヤー呼び出しのためのブリッジを追加する必要があるか判断する。
6. **後方互換性**: 既定はモノラル (1ch) とし、明示的にステレオを指定した場合のみ挙動が変わるようにする。既存の `configureAudioSession` や音声 API の挙動は変更しない。

## 完了条件

実装着手前の前提条件:
- WebRTC-Build 側で ADM のステレオ録音設定および Opus エンコーダのステレオ設定が有効であることが確認されていること
- `issues/0016-add-opus-params.md` が完了し、`opus_params` 伝達機構が利用可能になっていること
- API 設計（上記「設計方針 2」）の方針が決定され、具体的なプロパティ名・型・デフォルト値が決定していること

実装後の完了条件:
- ステレオ音声入力を有効にする設定が `Configuration` に追加されていること
- 指定時に入力チャンネル数が 2 に設定され、ステレオマイク搭載デバイスで L/R 両チャンネルの音声が Sora へ送信されること
- 入力デバイスのルート変更が発生してもステレオ構成が維持されること
- 既定（未指定）およびステレオ未対応デバイスではモノラルのまま従来挙動を維持すること
- 実機でステレオ入力が Sora 側で受信できることを確認すること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声入力に対応する
    - @担当者
  ```

## 解決方法
