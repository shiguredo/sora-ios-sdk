# iOS でステレオ音声を受信できない事象を調査する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-stereo-audio-receive

## 目的

Sora iOS SDK で受信音声をステレオで再生できない事象の原因を調査し、ステレオ受信を実現するために必要な対応を明確にする。libwebrtc の iOS 向け audio_device 実装ではステレオが未実装で強制的にモノラルとなっているため、何を変更すればステレオ受信が可能になるかを切り分け、対応方針を確立する。

## 依存関係

本調査の結果は `0010-add-stereo-audio-output` (ステレオ音声出力の実装) の前提となる。本 issue でステレオ playout の可否と必要な対応を明らかにした上で `0010-add-stereo-audio-output` に着手すること。

## 優先度根拠

- ステレオ受信は利用者から求められる機能であり、対応の必要性がある。
- 原因が libwebrtc の audio_device・SDP 生成・再生経路のいずれにあるかが未確定の調査段階であり、緊急性は中程度のため Medium とする。

## 現状

ステレオ受信を妨げている要因が複数想定されるが、定量的な切り分けは行われていない。

- iOS の audio_device 実装ではステレオが未実装で、`AudioDeviceIOS::StereoPlayoutIsAvailable()` が false を返す（libwebrtc `sdk/objc/native/src/audio/audio_device_ios.mm` 付近）。`audio_device_module_ios.mm` の `StereoPlayoutIsAvailable` も同実装を経由する。
- macOS には `AudioDeviceMac::StereoPlayoutIsAvailable()` の実装が存在するが、iOS には `_mixerManager` 相当の仕組みがなく、macOS の実装をそのまま流用することはできない。
- Sora iOS SDK 側にはステレオ受信を制御するフラグや設定が存在しない。`Sora/Configuration.swift` 等にステレオ関連の設定は無い。
- 現在の Sora iOS SDK の libwebrtc は `Sora/PackageInfo.swift` の `WebRTCInfo.version`（M148 系）である。

```swift
public static let version = "M148"
```

`Sora/PackageInfo.swift` の `WebRTCInfo.version` が M148 系であり、本調査は M148 系を前提とする。

## 設計方針

本 issue は調査までを範囲とし、ステレオ受信を実現するために必要な対応を切り分ける。

- libwebrtc の audio_device
  - `AudioDeviceModuleIOS::SetStereoPlayout(true)` でチャンネル数を 2（`nChannels = 2`）に設定できるよう改修できるかを確認する。
  - macOS の `_mixerManager` 方式は iOS とは仕組みが異なるため流用せず、iOS のスピーカー出力対応を拡張する形で実現可能かを調べる。
  - まずは受信（playout）にフォーカスし、必要に応じて送信（recording）も対象に含める。
- SDP / コーデック
  - 音声コーデックは Opus を前提とし、ステレオ受信のための SDP / fmtp 設定（`stereo=1` 等）の扱いを RFC 7587 に沿って確認する。
- Sora iOS SDK 側のフラグ
  - ステレオ受信を有効化する `forceStereo` 相当のフラグを `Sora/Configuration.swift` に追加し、`Sora/PeerChannel.swift` の音声トラック / SDP 構築へ反映する方式を検討する。
  - 既定はモノラルとし、フラグを有効にしたときのみステレオ受信を行うことで後方互換性を保つ。

## 完了条件

- iOS でステレオ受信ができない原因（libwebrtc の audio_device 実装か、SDP か、再生経路か）が特定されていること。
- ステレオ受信を実現するために必要な対応（libwebrtc 側の改修内容と Sora iOS SDK 側のフラグ追加方針）が結論づけられていること。
- 既定はモノラルで後方互換性を保つ方針が確認されていること。
- 調査結果と対応方針を本 issue にまとめること。

## 解決方法
