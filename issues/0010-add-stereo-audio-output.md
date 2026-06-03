# ステレオ音声出力に対応する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-output

## 目的

Sora から配信されるステレオ音声をステレオのまま再生できるようにする。現状の SDK は音声出力をモノラル前提で扱っており、出力チャンネル数を選択・反映する経路が存在しない。

## 依存関係

本対応は、受信音声をステレオで再生できるか (iOS の libwebrtc でステレオ playout が利用可能か) の調査に依存する。`0038-investigate-stereo-audio-receive` の調査結果を前提とし、その完了後に着手すること。

## 優先度根拠

Low とする。WebRTC-Build 側（ネイティブのオーディオデバイス層・Opus デコード設定）の対応が前提となり、iOS SDK 単独では完結しない。具体的なユーザー要望や緊急性を示す情報は無く、調査・設計の比重が大きいため Low とする。

## 現状

音声出力経路はネイティブの WebRTC オーディオデバイス層に依存している。WebRTC 側には出力チャンネル数を扱う API が存在する。

- `RTCAudioDevice`（`sdk/objc/components/audio/RTCAudioDevice.h`）にステレオ再生に関する記述（`outputNumberOfChannels` 等）がある。
- `RTCAudioSession`（同 `RTCAudioSession.h`）に `setPreferredOutputNumberOfChannels:` がある。
- `RTCAudioSessionConfiguration`（同 `RTCAudioSessionConfiguration.h`）に `outputNumberOfChannels` がある。

一方 iOS SDK の音声関連は `Sora/AudioMode.swift` / `Sora/AudioDeviceModuleWrapper.swift` にあるが、出力チャンネル数（モノラル / ステレオ）を選択・指定する API を持たない。`AudioOutput` は `default` / `speaker` のみで、ステレオ / モノラルの区別を持たない。

```swift
public enum AudioOutput {
  /// デフォルト
  case `default`

  /// スピーカー
  case speaker
}
```

`Sora/AudioMode.swift:45`

出力チャンネル数を設定・反映するコードが SDK に存在しないため、ステレオ出力は実現できない。

## 設計方針

1. WebRTC-Build 側でステレオ出力（ADM のチャンネル数、Opus デコーダのステレオ再生）が有効になっていることを前提条件として確認する。未整備なら本対応は WebRTC-Build 側対応待ちとなる。
2. iOS SDK 側では、出力チャンネル数（モノラル / ステレオ）を選択できる設定を `Configuration` に追加し、`RTCAudioSession.setPreferredOutputNumberOfChannels:` ないし `RTCAudioSessionConfiguration.outputNumberOfChannels` へ反映する。
3. 後方互換性: 既定はモノラルとし、明示的にステレオを指定した場合のみ挙動が変わるようにする。

## 完了条件

- ステレオ音声出力を有効にする設定が `Configuration` から指定できること。
- 指定時に出力チャンネル数が 2 に設定され、Sora からのステレオ音声がステレオで再生されること。
- 既定（未指定）ではモノラルのまま従来挙動を維持すること。
- 実機でステレオ再生が確認できること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声出力に対応する
    - @担当者
  ```

## 解決方法
