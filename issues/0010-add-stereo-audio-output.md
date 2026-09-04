# ステレオ音声出力に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-output
- Polished: 2026-09-03
- Updated: 2026-09-04

## Pending 理由（履歴）

かつて次の理由で pending としていた（WebRTC-Build 未確認、`0038` 未完了、API 未決）。
WebRTC-Build 側のステレオ playout 対応が完了している想定のもと、SDK 側を並列に進めるため reopened した。
その後、WebRTC-Build 側の対応内容と公開 API が確定し、`m150.7871.3.2` としてリリースされた。

## reopened にした理由

WebRTC-Build 側の iOS ステレオ playout 対応を前提に、Sora iOS SDK 側の実装を進めるため pending を解除した。
現在は前提となる WebRTC-Build 側の対応が完了している。

## 目的

Sora から配信されるステレオ音声をステレオのまま再生できるようにする。
SDK が WebRTC-Build `m150.7871.3.2` の `RTCAudioDeviceModule.setStereoPlayoutEnabled(_:)` を接続単位で設定し、Answer SDP の Opus `stereo=1` を保証する。
利用者が明示的に有効化した場合のみステレオ再生へ切り替え、既定のモノラル再生を維持する。

## 依存関係

- **WebRTC-Build `m150.7871.3.2`（実装・リリース済み）**: `ios_stereo_audio_output.patch` により、iOS ADM のステレオ playout、`RemoteIOAudioUnit` の 2 ch 出力、ステレオ時の `AVAudioSessionModeDefault` 適用、`RTCAudioDeviceModule.setStereoPlayoutEnabled(_:)` / `stereoPlayoutEnabled()` が実装されている。本 issue では最初に SDK の依存をこのバージョンへ更新する。先に適用される `ios_manual_audio_input.patch` との組み合わせも SDK 側で考慮する。
- **`issues/0009-add-stereo-audio-input.md`**: 入力側。本 issue の範囲外。公開 API の命名は揃えるが、実装は独立してよい。
- **`issues/closed/0038-investigate-stereo-audio-receive.md`**: 調査済み。ADM 未実装がボトルネックであり、宣言 API だけでなくデータ経路の改修が必要という結論を本 issue に取り込み済み。
- **`issues/closed/0016-add-opus-params.md`**: 送信用の `Configuration.audioOpusParams` は実装済み。本 issue が扱う受信側の Answer SDP とは別の経路である。

## 優先度根拠

Medium とする。
WebRTC-Build 側の前提は解決済みであり、SDK 側の依存更新と機能実装を進められる状態にある。
クラッシュやデータ破壊ではないため High にはしない。

## 現状

### WebRTC-Build / libwebrtc

WebRTC-Build `m150.7871.3.2` の `ios_stereo_audio_output.patch` には次が実装されている。

- `RTCAudioDeviceModule` に Objective-C の `setStereoPlayoutEnabled:` / `stereoPlayoutEnabled` が追加され、Swift から `setStereoPlayoutEnabled(_:)` / `stereoPlayoutEnabled()` として利用できる
- `setStereoPlayoutEnabled(true)` は ADM が未初期化なら `Init()` を実行し、`AudioDeviceModuleIOS::SetStereoPlayout(true)` の結果を返す。成功時の戻り値は `0`
- 呼び出しは ADM を生成したスレッド上で、ADM を `RTCPeerConnectionFactory` へ渡す前、かつ `InitPlayout` より前に行う必要がある
- ステレオ有効時は `playout_parameters_.channels()` が 2 となり、`AudioDeviceIOS::CreateAudioUnit` が `VoiceProcessingAudioUnit` の代わりに `RemoteIOAudioUnit` を選択する
- 出力チャンネル数は `RemoteIOAudioUnit` の stream format で 2 ch にする。`RTCAudioSessionConfiguration` の preferred output channel は 1 のまま維持する
- `AudioDeviceIOS::ConfigureAudioSession` / `ConfigureAudioSessionLocked` が、ステレオ有効時だけ WebRTC セッション構成中の mode を `AVAudioSessionModeDefault` に差し替える。SDK から mode を直接変更する必要はない
- SDP の Opus `stereo=1` とアプリ側の AudioSession category / route は WebRTC-Build の範囲外であり、SDK または利用側で扱う必要がある

確定している利用上の制約は次のとおり。

- `RemoteIO` へ切り替わるため、Voice Processing I/O が提供する AEC / AGC / マイクミュートは利用できない
- `RemoteIOAudioUnit::SetMicrophoneMute` は no-op で成功を返す。`pauseRecording` / `resumeRecording` によって WebRTC の録音データ経路は停止 / 再開するが、RemoteIO の入力バスは無効化されず、マイクインジケーターを消すハードミュートにはならない
- `bypassVoiceProcessing` は `RemoteIO` 経路では意味を持たず、指定しても無視される
- SDK はステレオ出力時に `PlayAndRecord` を設定する方針とするため、受信専用の場合もマイク権限が必要となる
- Bluetooth HFP はモノラルであり、A2DP ではステレオ出力が可能。patch は category や route の自動最適化を行わない
- 接続後に `Sora.setAudioMode(.voiceChat(...))` を呼ぶと、OS 側で出力が 1ch に制限される可能性がある

### SDK 側

- `Package.swift` の `libwebrtcVersion` は `m150.7871.3.0` であり、stereo playout API を含む `m150.7871.3.2` への更新が必要
- `Sora/PackageInfo.swift` の `WebRTCInfo.maintenanceVersion` は `"0"` である。`m150.7871.3.2` は同じ WebRTC revision を利用するため、maintenance version だけを `"2"` に更新すればよい
- `Sora/Configuration.swift` にステレオ再生を有効にするプロパティはない。近い既存フラグは `bypassVoiceProcessing`
- `Sora/NativePeerChannelFactory.swift` の `NativePeerChannelFactory.init` は `RTCAudioDeviceModule` を生成した直後に `RTCPeerConnectionFactory` へ渡している。この 2 処理の間が `setStereoPlayoutEnabled(true)` の呼び出し位置となる
- `Sora/MediaChannel.swift` の `MediaChannel.init` は `configuration.bypassVoiceProcessing` と `configuration.audioDevice` を `NativePeerChannelFactory.init` へ渡しているが、ステレオ出力設定は渡していない
- `Sora/PeerChannel.swift` の `createAnswer` は生成した Answer を変更せず `setLocalDescription` へ渡しており、Opus の `stereo=1` を保証していない
- `Sora/AudioDeviceModuleWrapper.swift` の `setAudioHardMute(_:)` は `pauseRecording` / `resumeRecording` の戻り値が `0` なら成功扱いにする。ステレオ時は録音データ経路が停止しても RemoteIO の入力バスとマイクインジケーターは止まらないため、SDK が公開 API で約束するハードミュートを満たさないまま成功と判断する
- `Sora/AudioMode.swift` の `AudioOutput` は `.default` / `.speaker` のみで、出力先の選択を表す。ステレオ / モノラルの設定とは分離されている
- `Sora.configureAudioSession(block:)` から preferred output channel を変更できるが、本 patch によるステレオ出力の成立条件ではない
- `Sora.setAudioMode` は category / mode / 出力ポートを変更する API であり、本 issue ではステレオ切替の責務を追加しない
- WebRTC-Build の `ios_manual_audio_input.patch` は、`RTCAudioSession.initializeInput` の完了を `VoiceProcessingAudioUnit::Initialize` から呼ばれる `startVoiceProcessingAudioUnit` に依存させている。`RemoteIOAudioUnit` はこの通知を行わないため、ステレオ時に現在の `PeerChannel.initializeAudioInput` を呼ぶと完了ハンドラーが呼ばれない
- 同 patch は `RTCAudioSessionConfiguration.webRTC().category` の既定値を `Ambient` に変更している。ステレオ時は VPIO 専用の `initializeInput` を経由せず、別の経路で `PlayAndRecord` を設定する必要がある

## 設計方針

以下を本 issue の確定方針とする。

1. **WebRTC SDK の更新を最初に実施する**
   - `Package.swift` の `libwebrtcVersion` を `m150.7871.3.2` に更新し、`WebRTC.xcframework.zip` に対応する checksum へ更新する
   - `Sora/PackageInfo.swift` の `WebRTCInfo.maintenanceVersion` を `"2"` に更新する。`version`、`branch`、`commitPosition`、`revision` は変更しない
   - 更新後の WebRTC.xcframework で `RTCAudioDeviceModule.setStereoPlayoutEnabled(_:)` / `stereoPlayoutEnabled()` を Swift から利用できることを確認してから SDK 側の実装へ進む

2. **公開 API を追加する**
   - `Configuration` に `audioStereoOutputEnabled: Bool = false` を追加する
   - 既定の `false` では従来どおりモノラルとなり、`true` のときだけステレオ出力経路を有効化する
   - `audioStereoOutputEnabled == true` と `audioEnabled == false`、または `audioCodec == .pcmu` の同時指定は、ステレオ化する音声経路や Opus payload が存在しないため `SoraError.configurationError` とする
   - `AudioOutput` は出力先を表す既存の責務に留め、変更しない

3. **ADM を Factory 作成前に設定する**
   - `MediaChannel.init` から `configuration.audioStereoOutputEnabled` と、送信ロールまたはステレオ出力が必要とする `PlayAndRecord` 要求を `NativePeerChannelFactory.init` へ渡す
   - ADM や AudioSession に触る前に、手順 2、送信ロールでの `initialMicrophoneEnabled == false`、internal な `Configuration.audioDevice` との同時指定を検証する
   - `NativePeerChannelFactory.init` を throwing initializer に変更する。通常の ADM 経路では、`RTCAudioDeviceModule(bypassVoiceProcessing:)` の生成直後に、同じスレッド上で `setStereoPlayoutEnabled(true)` を呼ぶ
   - 戻り値が `0` であることを確認してから `RTCPeerConnectionFactory(..., audioDeviceModule: adm)` を生成する
   - 戻り値が `0` 以外の場合は `SoraError.mediaChannelError` を throw し、利用者の指定に反してモノラルへ暗黙にフォールバックしない
   - stereo API が成功した後、手順 4 の AudioSession category 要求を登録してから ADM を Factory へ渡す。stereo API の失敗時には共有 AudioSession 設定を変更しない
   - `MediaChannel.init` も throwing initializer に変更し、`Sora.connect` で初期化エラーを捕捉する。失敗した `MediaChannel` は管理対象へ追加せず、完了済みの `ConnectionTask` を返し、引数の接続ハンドラーと `Sora.handlers.onConnect` の双方へ同じエラーを 1 回ずつ通知する
   - `audioStereoOutputEnabled == false` の場合は stereo API を呼ばず、既存の初期化経路を維持する
   - internal な `Configuration.audioDevice` が指定された経路には `RTCAudioDeviceModule` が存在しないため、`audioStereoOutputEnabled == true` との同時指定は `SoraError.configurationError` として扱う

4. **共有 AudioSession の category を接続間で管理する**
   - `RTCAudioSessionConfiguration.webRTC()` はプロセス内の共有設定であるため、接続ごとに直接上書きして放置しない。AudioSession category の要求を直列化する internal な coordinator を追加する
   - coordinator は最初の要求登録時に元の category を保存し、送信を行う接続または `audioStereoOutputEnabled == true` の接続が 1 つでも存在する間は `AVAudioSession.Category.playAndRecord.rawValue` を維持する
   - coordinator はプロセス全体で共有し、ロックで保護する。要求登録時に一意な lease を返し、同じ lease の解除を複数回行っても状態が変わらないようにする
   - `audioStereoOutputEnabled == true` の場合は送受信ロールにかかわらず要求を登録する。既存のモノラル送信接続も同じ coordinator に登録し、`PeerChannel.initializeAudioInput` からの category 直接代入を除去する
   - `NativePeerChannelFactory` が lease を保持し、`MediaChannel` の切断時に明示的に解除する。接続初期化が途中で失敗した場合も解除し、deinit は解除漏れに対する最後の安全策とする。最後の要求がなくなった時点で保存した category を復元する
   - 複数接続中に 1 接続が切断されても、残る送信接続またはステレオ接続が必要とする `PlayAndRecord` を維持する
   - SDK は `RTCAudioSessionConfiguration` の preferred output channel を 2 に変更しない
   - SDK はステレオ有効化のために `AVAudioSession` の mode を直接変更しない
   - 2 ch の stream format、`RemoteIOAudioUnit` の選択、WebRTC セッション構成時の `AVAudioSessionModeDefault` 適用は WebRTC-Build 側に任せる
   - `configureAudioSession(block:)` のみに任せて SDK にステレオ設定を持たない案は採用しない
   - `setAudioMode` にステレオ切替を混ぜない。接続後に `.voiceChat` へ変更するとステレオ出力を維持できない可能性をドキュメントに記載する

5. **Answer SDP の Opus `stereo=1` を保証する**
   - [RFC 7587 Section 7 / 7.1](https://www.rfc-editor.org/rfc/rfc7587.html#section-7.1) に従い、Answer 側の `stereo=1` を SDK が受信する Opus 音声のステレオ優先指定として扱う。Offer と Answer の Opus パラメーターは独立しているため、Offer に `stereo=1` があることを追加条件にはしない
   - `PeerChannel.createAnswer` で native Answer を生成した後、`setLocalDescription` より前に SDP を変換する
   - `m=audio` セクション内の `a=rtpmap:<payload type> opus/48000/2` から Opus の payload type を取得し、`111` などの値を固定しない
   - 対応する `a=fmtp:<payload type>` に `stereo=1` がなければ追加し、`stereo=0` があれば `stereo=1` に置換する。fmtp 行がなければ同じ audio セクションへ追加する
   - 出力側の受信設定であるため、送信側のチャンネル数を通知する `sprop-stereo` は追加しない
   - SDP の改行形式と Opus 以外の media section / fmtp parameter を維持する
   - 変換後の `RTCSessionDescription` を `setLocalDescription` と Sora への Answer 送信の両方に使用する
   - `audioCodec == .default` または `.opus` でも生成された Answer の audio セクションに Opus payload が存在しない場合は `SoraError.peerChannelError` とし、ステレオ出力が成立していない Answer を送信しない
   - `audioStereoOutputEnabled == false` の場合は SDP を変更しない

6. **ハードミュートとの非互換を成功扱いにしない**
   - `audioStereoOutputEnabled == true` の場合、`MediaChannel.setAudioHardMute(_:)` は `pauseRecording` / `resumeRecording` を呼ばず、未対応であることを示す `SoraError.mediaChannelError` を返す
   - 送信ロールで `initialMicrophoneEnabled == false` とステレオ出力を同時指定した場合は、初期ハードミュートを保証できないため接続を設定エラーとして失敗させる
   - ステレオ出力と送信を併用し、`initialMicrophoneEnabled == true` の場合は、VPIO 専用の `setInitialMicrophoneMute` / `initializeInput` を呼ばない。AudioSession category は手順 4 で設定済みとし、RemoteIO が構成する入力バスを使用する
   - `pauseRecording` / `resumeRecording` による録音データ経路の停止 / 再開と、入力バスを無効化するハードミュートを区別する。既存 API の「マイクインジケーターを消す」という契約を満たせない処理を成功扱いにしない
   - `bypassVoiceProcessing == true` との同時指定はエラーにしないが、ステレオ時には指定が無視されることをドキュメントに記載する

7. **後方互換性を維持する**
   - `audioStereoOutputEnabled` の既定値は `false` とする
   - 未指定時は既存の `VoiceProcessingIO` / `AVAudioSessionModeVoiceChat` / モノラル出力 / ハードミュートの挙動を変更しない

8. **範囲外とする**
   - ステレオ入力（0009）
   - デバイス挿抜や内蔵マイク L/R の高度なハンドリング
   - Bluetooth route の自動最適化
   - `AudioOutput` のスピーカー挙動調査（0050）

## テスト方針

モックやスタブは使用しない。

- `ConfigurationTests` で `audioStereoOutputEnabled` の既定値が `false` であることを確認する
- 実際の `RTCAudioDeviceModule` を使い、Factory へ渡す前に `setStereoPlayoutEnabled(true)` が成功し、`stereoPlayoutEnabled()` が `true` を返すことを確認する
- stereo API の戻り値を接続エラーへ変換する実装コードの純粋な判定処理を分離し、非 `0` を渡した場合にモノラルへフォールバックせず `SoraError.mediaChannelError` になることを確認する
- 設定の組み合わせが不正な場合と stereo API が失敗した場合に、AudioSession category が変更されないことを確認する
- `audioStereoOutputEnabled == false` では既存経路を維持することを確認する
- SDP 変換について、fmtp 行なし、`stereo` なし、`stereo=0`、既に `stereo=1`、複数の audio payload type、Opus payload なし、video fmtp 併存、CRLF / LF の各ケースを実データから構築した SDP で確認する
- ステレオ時の `setAudioHardMute(_:)` が成功を返さないことと、モノラル時の既存ハードミュートを壊さないことを確認する
- iOS 実機で L/R が分離した音源を再生し、左右が混合されずステレオ出力されることを確認する
- iOS 実機でステレオの recvonly / sendonly / sendrecv が接続でき、sendonly / sendrecv では `RTCAudioSession.initializeInput` の完了待ちが残らず音声を送信できることを確認する
- iOS 実機でステレオ接続を切断して再接続できることを確認し、VPIO 用の入力初期化状態が残留しないことを確認する
- 実際の `RTCAudioSessionConfiguration.webRTC()` を使い、複数の送信 / ステレオ接続に相当する category 要求を登録・解除しても、最後の要求を解除するまで `PlayAndRecord` が維持され、最後に元の category へ復元されることを確認する
- `sendonly + audioStereoOutputEnabled == true + initialMicrophoneEnabled == false` の決定的な設定エラーを使い、戻る `ConnectionTask` が完了済みであること、引数の接続ハンドラーと `Sora.handlers.onConnect` が各 1 回だけエラーを通知すること、`mediaChannels` と `onAddMediaChannel` に失敗した channel が現れないことを確認する
- iOS 実機でモノラル時、マイク権限拒否時、`initialMicrophoneEnabled` 指定時、Bluetooth HFP / A2DP、接続後の `setAudioMode` 変更時の挙動を確認する

## 変更対象

- `Package.swift`: WebRTC-Build を `m150.7871.3.2` へ更新し、checksum を更新
- `Sora/PackageInfo.swift`: `WebRTCInfo.maintenanceVersion` を `"2"` へ更新
- `Sora/Configuration.swift`: `audioStereoOutputEnabled` を追加
- `Sora/Sora.swift`: throwing initializer のエラーを接続ハンドラーへ返し、失敗時の `ConnectionTask` を完了
- `Sora/MediaChannel.swift`: Factory 初期化への設定伝達、throwing initializer 化、ハードミュート非対応の明示、組み合わせ制約の検証
- `Sora/NativePeerChannelFactory.swift`: Factory 作成前の `setStereoPlayoutEnabled(true)` 呼び出しと失敗の伝播
- `Sora/PeerChannel.swift`: category の直接代入を coordinator 利用へ変更、ステレオ時の VPIO 専用入力初期化のスキップ、および変換済み Answer の使用
- AudioSession category coordinator 用の新規ファイル: 複数接続からの `PlayAndRecord` 要求と元の category の復元を管理
- SDP 変換用の新規ファイル: Answer SDP の Opus `stereo=1` 保証
- `SoraTests/ConfigurationTests.swift`: 既定値のテスト
- `SoraTests/` 配下の音声 Factory / SDP テスト: ADM 設定順序、失敗経路、SDP 変換、ハードミュート制約のテスト
- ドキュメント: 有効化方法、VoiceChat、AEC / AGC、ハードミュート、`bypassVoiceProcessing`、マイク権限、Bluetooth の制約
- `CHANGES.md`: WebRTC-Build 更新とステレオ音声出力対応

## 完了条件

- `Package.swift` が WebRTC-Build `m150.7871.3.2` と対応 checksum を参照していること
- `Sora/PackageInfo.swift` の `WebRTCInfo.maintenanceVersion` が `"2"` であり、WebRTC revision の情報が成果物と一致していること
- 更新後の WebRTC.xcframework から `RTCAudioDeviceModule.setStereoPlayoutEnabled(_:)` / `stereoPlayoutEnabled()` を利用できること
- `Configuration.audioStereoOutputEnabled` が追加され、既定値が `false` であること
- `audioEnabled == false` または `audioCodec == .pcmu` との同時指定が設定エラーとなり、Answer に Opus payload がない場合も接続を成功扱いにしないこと
- `true` の場合は ADM の生成直後かつ Factory 作成前に `setStereoPlayoutEnabled(true)` を呼び、失敗時はモノラルへフォールバックせず接続を失敗させること
- SDK がステレオ時の AudioSession category を `PlayAndRecord` に設定し、複数接続で要求を共有し、最後の要求を解除したときに元の category へ復元すること
- SDK が preferred output channel や AudioSession mode を重複して設定せず、WebRTC-Build 側の 2 ch / RemoteIO / mode 切替を利用すること
- `true` の場合は Answer SDP の Opus payload に `stereo=1` が含まれ、変換後の SDP が local description と Sora への Answer の両方に使われること
- `false` の場合は従来どおりモノラルの `VoiceProcessingIO` / `VoiceChat` 経路と既存ハードミュートを維持すること
- stereo 時の `setAudioHardMute(_:)` が、録音データ経路だけを停止して SDK のハードミュート契約を満たさない処理を成功扱いにしないこと
- 送信ロールで `initialMicrophoneEnabled == false` と stereo を同時指定した場合に、初期ハードミュートを保証できないまま接続しないこと
- stereo の sendonly / sendrecv では VPIO 専用の `setInitialMicrophoneMute` / `initializeInput` を呼ばず、RemoteIO の入力経路で送信できること
- 実機でステレオ再生を確認し、recvonly、sendonly、sendrecv、切断後の再接続、モノラル、マイク権限拒否、Bluetooth HFP / A2DP、`setAudioMode` 変更時の挙動も確認すること
- 利用上の制約（AEC / AGC、ハードミュート、`bypassVoiceProcessing`、マイク権限、Bluetooth HFP / A2DP、`setAudioMode`）がドキュメントに書かれていること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声出力に対応する
    - @担当者
  - [UPDATE] libwebrtc m150.7871.3.2 に上げる
    - @担当者
  ```

## 解決方法
