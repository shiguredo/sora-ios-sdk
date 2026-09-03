# ステレオ音声出力に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-output
- Polished: 2026-09-03

## Pending 理由（履歴）

かつて次の理由で pending としていた（WebRTC-Build 未確認、`0038` 未完了、API 未決）。WebRTC-Build 側のステレオ playout 対応が完了している想定のもと、SDK 側を並列に進めるため reopened した。以下の設計方針は、その想定と既知の制約に基づき本 issue で確定する。

## reopened にした理由

WebRTC-Build 側の iOS ステレオ playout 対応が完了している想定のもと、Sora iOS SDK 側の実装を並列に進めるため pending を解除する。

## 目的

Sora から配信されるステレオ音声をステレオのまま再生できるようにする。SDK が接続時に出力チャンネル数・AudioSession mode・必要なら SDP の Opus `stereo=1` を揃え、利用者が明示的に有効化した場合のみステレオ再生する。

## 依存関係

- **WebRTC-Build（前提・完了想定）**: iOS ADM のステレオ playout が利用可能であること。ステレオ有効時は `RemoteIO` 等へ切り替わり、`AVAudioSessionModeDefault` のとき 2ch、既定の `VoiceChat` では従来どおりモノラル、という制約を持つ想定。
- **`issues/0009-add-stereo-audio-input.md`**: 入力側。本 issue の範囲外。API 命名は揃えるが実装は独立してよい。
- **`issues/0038-investigate-stereo-audio-receive.md`**: 調査 issue。本 issue の着手ゲートにはしない。既知の結論（ADM 未実装がボトルネック、宣言 API だけでは不足、データ経路改修が必要）は下記「現状」に取り込み済み。0038 自体の closed は別作業とする。
- **`issues/0016-add-opus-params.md`**: 送信側の `opus_params` 伝達。本 issue（受信・playout）の着手前提ではない。受信の `stereo=1` は Answer SDP 側で扱う。

## 優先度根拠

Medium とする。出力を優先して進める方針であり、WebRTC-Build 完了想定のもと SDK 側を並列実装する。クラッシュやデータ破壊ではないため High にはしない。

## 現状

### WebRTC-Build / libwebrtc（完了想定）

upstream の iOS ADM では `AudioDeviceIOS::StereoPlayoutIsAvailable` が常に `false` で、`VoiceProcessingAudioUnit` も 1ch 固定だった。WebRTC-Build 側パッチによりステレオ playout が可能になっている想定で本 issue を進める。

既知の利用上の制約（WebRTC-Build 側）:

- ステレオ時は Voice Processing I/O ではなく Remote I/O 系へ切り替わる想定のため、ハードウェア AEC / AGC が使えない
- ステレオは `AVAudioSessionModeDefault` 側で有効化し、既定の `VoiceChat` ではモノラルを維持する必要がある（mode を一律 Default に変えると VoIP 挙動が壊れる）
- Bluetooth は HFP だとモノラル、A2DP ならステレオ可、などルート依存がある

### SDK 側

- `Sora/AudioMode.swift` の `AudioOutput` は `.default` / `.speaker` のみで、出力先（スピーカー等）の選択でありステレオ / モノラルの区別はない。本 issue では `AudioOutput` を拡張しない（出力先の挙動確認は `issues/0050-investigate-audiooutput-behavior.md` の範囲）。
- `Sora/Configuration.swift` に出力チャンネル数やステレオ再生を有効にするプロパティはない。近い既存フラグは `bypassVoiceProcessing`。
- アプリは `Sora.configureAudioSession(block:)` 経由で `RTCAudioSession` の `setPreferredOutputNumberOfChannels` 等を呼べる（ドキュメントにも案内がある）。ただし SDK が接続フローでステレオ再生に必要な設定（mode・チャンネル数・ADM・SDP）を揃える経路はない。
- `Sora.setAudioMode` は接続完了後の category / mode / 出力ポート変更を行い、出力チャンネル数は設定しない。
- `PeerChannel.initializeAudioInput` は入力側のセッション準備であり、ステレオ出力の主経路ではない。
- `AudioDeviceModuleWrapper` は録音のポーズ / 再開（ハードミュート）のみ。

## 設計方針

以下を本 issue の確定方針とする。

1. **公開 API**
   - `Configuration` に `audioStereoOutputEnabled: Bool = false` を追加する。
   - 既定 `false` で従来どおりモノラル。`true` のときのみステレオ出力経路を有効化する。
   - `AudioOutput` 列挙型は変更しない。

2. **設定の反映**
   - 接続処理のなかで、`audioStereoOutputEnabled == true` のときに次を行う。
     - WebRTC 向け `RTCAudioSessionConfiguration` の `outputNumberOfChannels` を 2 にする（およびステレオ有効に必要な mode を `AVAudioSessionModeDefault` 側へ合わせる）。既定（`false`）では現行どおり `VoiceChat` 前提を崩さない。
     - WebRTC-Build が公開しているステレオ playout 有効化手段（ADM の `SetStereoPlayout` 相当、またはパッチが要求する同等の設定）を、ファクトリ / ADM 初期化経路から呼び出す。具体的な ObjC API 名は、利用する WebRTC.xcframework のヘッダーに合わせる。
   - `configureAudioSession(block:)` のみに任せて SDK に設定を持たない案は採用しない（完了条件と一致させるため）。
   - `setAudioMode` にステレオ切替を混ぜない。`setAudioMode` は出力先・category / mode の既存責務に留め、ステレオ有効時に利用者が `voiceChat` へ戻してモノラル化する衝突が起きないよう、ドキュメントで「ステレオ出力有効時は mode を VoiceChat に戻さない」旨を示す。

3. **SDP / Opus**
   - ステレオ出力有効時、Answer 生成経路（`PeerChannel.createAnswer` 周辺）で Opus の fmtp に `stereo=1` が含まれることを保証する。含まれない場合は Answer SDP を書き換えて挿入する（受信デコードを 2ch にするため）。
   - 送信用 `opus_params`（0016）とは切り離す。

4. **後方互換性**
   - 既定はモノラル。既存の `configureAudioSession` / `setAudioMode` / 未設定時の接続挙動は変えない。

5. **範囲外（本 issue でやらない）**
   - ステレオ入力（0009）
   - デバイス挿抜や内蔵マイク L/R の高度なハンドリング（必要なら別 issue）
   - Bluetooth ルートの自動最適化の実装（制約はドキュメントに書く）
   - `AudioOutput` のスピーカー挙動調査（0050）

## 変更対象

- `Sora/Configuration.swift`: `audioStereoOutputEnabled` 追加
- 接続・ファクトリ経路（`NativePeerChannelFactory` / `MediaChannel` / ADM 初期化）: ステレオ有効時の ADM / `RTCAudioSessionConfiguration` 反映
- `Sora/PeerChannel.swift`: Answer SDP の Opus `stereo=1` 保証（ステレオ有効時のみ）
- ドキュメント（README または該当ガイド）: 有効化方法、VoiceChat との関係、AEC/AGC・Bluetooth の制約
- `CHANGES.md` の `develop` セクション

## 完了条件

- `Configuration.audioStereoOutputEnabled` が追加され、既定が `false` であること
- `true` のとき、接続フローで出力 2ch とステレオ playout 有効化（WebRTC-Build が要求する設定）が行われること
- `true` のとき、Answer SDP の Opus に `stereo=1` が含まれること
- `false`（既定）では従来どおりモノラル（VoiceChat 前提の既存挙動）を維持すること
- 実機でステレオ再生が確認できること（WebRTC-Build 成果物を用いた検証）
- 利用上の制約（AEC/AGC、Bluetooth HFP/A2DP、`setAudioMode` との関係）がドキュメントに書かれていること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声出力に対応する
    - @担当者
  ```

## 解決方法
