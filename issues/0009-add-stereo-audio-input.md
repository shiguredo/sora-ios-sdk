# ステレオ音声入力に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-input
- Polished: 2026-09-03

## Pending 理由（履歴）

かつて次の理由で pending としていた（WebRTC-Build 未確認、API 未決、`0016` 未完了）。WebRTC-Build 側のステレオ録音対応が完了している想定のもと、SDK 側を並列に進めるため reopened した。以下の設計方針は、その想定と出力側 `0010` の確定方針に揃えて本 issue で確定する。

## reopened にした理由

WebRTC-Build 側の iOS ステレオ録音対応が完了している想定のもと、Sora iOS SDK 側の実装を並列に進めるため pending を解除する。

## 目的

ステレオマイク搭載デバイスや外部オーディオインターフェースからのステレオ入力を Sora へ送信できるようにする。利用者が明示的に有効化した場合のみ、入力 2ch・ADM ステレオ録音・送信コーデックのステレオ指定を揃える。

## 依存関係

- **WebRTC-Build（前提・完了想定）**: iOS ADM のステレオ recording が利用可能であること。ステレオ有効時は `RemoteIO` 等へ切り替わり、`AVAudioSessionModeDefault` のとき 2ch、既定の `VoiceChat` では従来どおりモノラル、という制約を持つ想定（出力側 `0010` と同じ）。
- **`issues/0010-add-stereo-audio-output.md`**: 出力側。API 命名を揃える。実装は独立してよい。
- **`issues/0016-add-opus-params.md`**: connect の `audio.opus_params` 伝達機構。本 issue は `opus_params` 全体を再発明しない。`audioStereoInputEnabled == true` のときの `stereo` 指定は 0016 の機構経由で載せる。0016 が未マージなら、本 issue の作業ブランチで 0016 を先に取り込むか同一系列で先行マージする。

## 優先度根拠

Medium とする。ステレオ送信の需要はあるが、出力 `0010` を優先する方針のもと本 issue は並列整備する。クラッシュやデータ破壊ではないため High にはしない。

## 現状

### WebRTC-Build / libwebrtc（完了想定）

upstream の iOS ADM では `SetStereoRecording` が未実装相当だった。WebRTC-Build 側パッチによりステレオ録音が可能になっている想定で本 issue を進める。既知の制約（AEC/AGC 喪失、mode は Default 時のみステレオ、Bluetooth HFP はモノラル等）は `0010` と同じ前提を共有する。

### SDK 側

- `NativePeerChannelFactory` は `RTCAudioDeviceModule(bypassVoiceProcessing:)` で ADM を生成するが、ステレオ録音を指定する経路はない。
- `PeerChannel.initializeAudioInput` は `RTCAudioSession` で category 等を整える入力初期化であり、入力チャンネル数やステレオ録音の設定は行っていない。
- アプリは `Sora.configureAudioSession(block:)` 経由で `setPreferredInputNumberOfChannels` を呼べる（ドキュメント案内あり）。ただし SDK が接続フローでステレオ入力に必要な設定（mode・チャンネル数・ADM・シグナリング）を揃える経路はない。
- `AudioDeviceModuleWrapper` は録音のポーズ / 再開（ハードミュート）のみ。
- `SignalingConnect` の audio は現状 `codec_type` / `bit_rate` のみ。`opus_params` は 0016 で追加予定。
- `AudioCodec` / `AudioMode` にチャンネル数や stereo の概念はない。`AudioOutput` は出力先選択であり本 issue では触らない。
- オーディオルート変更は `SoraRTCAudioSessionDelegateAdapter` から `SoraHandlers.onChangeAudioRoute` へ通知される。高度な挿抜ハンドリングは本 issue の範囲外とする。

## 設計方針

以下を本 issue の確定方針とする。`0010` と対になる形にする。

1. **公開 API**
   - `Configuration` に `audioStereoInputEnabled: Bool = false` を追加する（出力の `audioStereoOutputEnabled` と対）。
   - 既定 `false` で従来どおりモノラル。`true` のときのみステレオ入力経路を有効化する。
   - `configureAudioSession` のみに任せて SDK に設定を持たない案は採用しない。
   - `audioInputChannels: Int` 案は採用しない（0010 と同様に Bool で揃える）。

2. **設定の反映**
   - 接続処理のなかで、`audioStereoInputEnabled == true` のときに次を行う。
     - WebRTC 向け `RTCAudioSessionConfiguration` の `inputNumberOfChannels` を 2 にする（およびステレオ有効に必要な mode を `AVAudioSessionModeDefault` 側へ合わせる）。既定（`false`）では現行どおり `VoiceChat` 前提を崩さない。
     - WebRTC-Build が公開しているステレオ録音有効化手段（ADM の `SetStereoRecording` 相当）を、ファクトリ / ADM 初期化経路から呼び出す。具体的な ObjC API 名は利用する WebRTC.xcframework のヘッダーに合わせる。
   - `setAudioMode` にステレオ切替を混ぜない（`0010` と同じ）。ステレオ入力有効時に利用者が `voiceChat` へ戻してモノラル化する衝突が起きないよう、ドキュメントで注意する。

3. **シグナリング / Opus**
   - `audioStereoInputEnabled == true` のとき、connect の `audio.opus_params` にステレオ送信が分かるよう `stereo`（必要なら `sprop_stereo`）を載せる。伝達は 0016 の `audioOpusParams` 機構を使う。
   - 利用者が `audioOpusParams` で明示指定している場合は、明示指定を優先する（衝突時の詳細は実装時にドキュメント化）。
   - 送信 SDP 側で Opus の `stereo=1` が必要な場合は、オファー / 送信コーデック設定経路で保証する（受信 Answer の書き換えは `0010` の範囲）。

4. **後方互換性**
   - 既定はモノラル。既存の `configureAudioSession` / `setAudioMode` / 未設定時の接続挙動は変えない。

5. **範囲外**
   - ステレオ出力（0010）
   - デバイス挿抜や内蔵マイク L/R の高度なハンドリング（必要なら別 issue）
   - Bluetooth ルートの自動最適化の実装（制約はドキュメントに書く）
   - ルート変更時の完全な自動再構成（通知は既存 `onChangeAudioRoute` を利用。SDK が接続時に設定した内容の再適用を入れる場合は最小限にとどめる）

## 変更対象

- `Sora/Configuration.swift`: `audioStereoInputEnabled` 追加
- 接続・ファクトリ経路（`NativePeerChannelFactory` / `MediaChannel` / ADM 初期化、必要なら `PeerChannel.initializeAudioInput`）: ステレオ有効時の ADM / `RTCAudioSessionConfiguration` 反映
- シグナリング経路（0016 の `audioOpusParams` 連携）: ステレオ有効時の `stereo` 載荷
- 送信 SDP / コーデック設定経路（必要な場合）: Opus `stereo=1` 保証
- ドキュメント: 有効化方法、`0010` / `0016` との関係、VoiceChat・AEC/AGC・Bluetooth の制約
- `CHANGES.md` の `develop` セクション

## 完了条件

- `Configuration.audioStereoInputEnabled` が追加され、既定が `false` であること
- `true` のとき、接続フローで入力 2ch とステレオ録音有効化（WebRTC-Build が要求する設定）が行われること
- `true` のとき、connect 経由で Opus ステレオ送信が指定され（0016 機構）、実機から Sora へステレオ音声が送れること
- `false`（既定）では従来どおりモノラルを維持すること
- 利用上の制約（AEC/AGC、Bluetooth、`setAudioMode`、`audioOpusParams` との関係）がドキュメントに書かれていること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声入力に対応する
    - @担当者
  ```

## 解決方法
