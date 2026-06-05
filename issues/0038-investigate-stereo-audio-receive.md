# iOS でステレオ音声を受信できない事象を調査する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-stereo-audio-receive
- Polished: 2026-06-06

## 目的

Sora iOS SDK で受信音声をステレオで再生できない事象の原因を調査し、ステレオ再生を実現するために必要な対応を明確にする。libwebrtc の iOS 向け audio_device 実装ではステレオが未実装で強制的にモノラルとなっているため、何を変更すればステレオ playout（ AVAudioSession 経由のスピーカー出力でのステレオ再生）が可能になるかを切り分け、対応方針の検討材料を整理する。本 issue では「ステレオ受信」は RTP ・デコードレイヤーでの 2 チャンネル受信、「ステレオ playout」は再生デバイスへの 2 チャンネル出力を指す。

## 依存関係

本調査の結果は `0010-add-stereo-audio-output` (ステレオ音声出力の実装) の前提となる。本 issue でステレオ playout の可否と必要な対応を明らかにした上で `0010-add-stereo-audio-output` に着手すること。

## 優先度根拠

- `0010-add-stereo-audio-output`（ステレオ音声出力）と `0009-add-stereo-audio-input`（ステレオ音声入力）がいずれも pending 状態であり、本調査の完了が両 issue の実装開始の前提となっている。
- 原因が libwebrtc の audio_device ・ SDP 生成 ・ 再生経路のいずれにあるかが未確定の調査段階であり、即時のコード変更は生じないため High ではなく Medium とする。

## 現状

ステレオ受信を妨げている要因が複数想定されるが、定量的な切り分けは行われていない。

- iOS の audio_device 実装ではステレオが未実装で、`AudioDeviceIOS::StereoPlayoutIsAvailable()` が false を返す（libwebrtc `sdk/objc/native/src/audio/audio_device_ios.mm` 付近）。`audio_device_module_ios.mm` の `StereoPlayoutIsAvailable` も同実装を経由する。
- macOS には `AudioDeviceMac::StereoPlayoutIsAvailable()` の実装が存在するが、iOS には `_mixerManager` 相当の仕組みがなく、macOS の実装をそのまま流用することはできない。
- Sora iOS SDK 側にはステレオ受信を制御するフラグや設定が存在しない。`Sora/Configuration.swift` にステレオ関連の設定は無い。ただし `bypassVoiceProcessing: Bool = false`（`Sora/Configuration.swift:155`）が存在し、これが `Sora/NativePeerChannelFactory.swift` の `RTCAudioDeviceModule(bypassVoiceProcessing:)` の初期化引数に渡されている。ステレオ設定を追加する場合も同様の経路が参考になる。
- `Sora/Signaling.swift` の `AudioCodingKeys` には現状 `codec_type` と `bit_rate` のみが実装されており、シグナリングレベルでのステレオ指定（`opus_params.stereo` 等）を Sora サーバーへ送る手段が SDK に存在しない。
- 現在の libwebrtc バージョンは `Sora/PackageInfo.swift` の `WebRTCInfo.version` で確認でき、本調査は M148 を前提とする。

## 設計方針

本 issue は調査までを範囲とし、ステレオ受信を実現するために必要な対応を切り分ける。

- libwebrtc の audio_device
  - `AudioDeviceModuleIOS::SetStereoPlayout(true)` でチャンネル数を 2 （`nChannels = 2`）に設定できるよう改修できるかを確認する。`RTCAudioDeviceModule` の Objective-C ラッパーに `SetStereoPlayout` に相当する API が公開されているかを `WebRTC.xcframework` のヘッダーで先に確認すること。公開されていない場合は libwebrtc 本体を直接改修する方針となる。
  - macOS の `_mixerManager` 方式は iOS とは仕組みが異なるため流用せず、iOS のスピーカー出力対応を拡張する形で実現可能かを調べる。
  - 本 issue の調査対象は受信（playout）に限定する。送信（recording）は `0009-add-stereo-audio-input` で別途扱う。
- SDP / コーデック（ Opus ）
  - 音声コーデックは Opus を前提とし、ステレオ受信のための SDP / fmtp 設定（`stereo=1` 等）の扱いを RFC 7587 に沿って確認する。具体的には `PeerChannel.swift` の `createAnswer` / `setLocalDescription` 周辺で SDP に `a=fmtp:111 stereo=1` が含まれているかをログで確認し、含まれていない場合は SDK での挿入方法を調査する。
  - Sora サーバー側の accept-stereo 対応状況を確認する（サーバーが `stereo=1` を拒否している場合は SDK 側の対応だけでは解決しない）。
- Sora iOS SDK 側のシグナリングとフラグ
  - `Sora/Signaling.swift` の `AudioCodingKeys` に `stereo` 相当のパラメータを追加してシグナリングで Sora サーバーへステレオ指定を送る方式を調査する。`0016-add-opus-params`（open）の進捗を確認し、着手中または完了済みであれば事前に内容を確認すること。
  - ステレオ受信を有効化するフラグを `Sora/Configuration.swift` に追加できるかを調査する。既存の `bypassVoiceProcessing` の経路（`NativePeerChannelFactory.swift` 経由）を参考に、ADM へのステレオ設定の伝達方法を確認する。既定はモノラルとし後方互換性を保つ方針とする。

## 完了条件

- `RTCAudioDeviceModule` の ObjC ヘッダーで `SetStereoPlayout` 相当の API 公開有無を確認し、結果（公開されている / されていない）が `## 解決方法` に記載されていること。
- `PeerChannel.swift` の `createAnswer` または `setLocalDescription` 前後の SDP ログで `a=fmtp:111 stereo=1` の有無が確認されており、ステレオ指定が SDP に含まれているかどうかが明記されていること。
- 実機でのスピーカー出力時に `AVAudioSession.sharedInstance().outputNumberOfChannels` の実測値が記録されており、現状でモノラル出力（1 チャンネル）になっていることが数値で示されていること。
- ステレオ playout を実現するために必要な対応レイヤー（libwebrtc 改修 / SDP 操作 / シグナリング追加 / SDK フラグの組み合わせ）が「何をどの順序で対応すべきか」として `## 解決方法` に記載されていること。
- 既定はモノラルで後方互換性を保つ方針が明示されていること。

## 解決方法
