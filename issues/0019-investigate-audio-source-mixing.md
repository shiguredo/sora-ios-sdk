# 複数音声ソースを mix して送信できるか検討する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-audio-source-mixing
- Polished: 2026-06-05

## 目的

マイク以外の音声、または複数音声ソースを合成した音声を Sora に送信できるかを調査する。マイク入力とアプリ内の別音声（例: ゲーム音声）を `AVAudioEngine` 等でミックスして送信する経路が技術的に実現可能かを切り分けることが目的である。

## 優先度根拠

- 既存機能の不具合ではなく、新規機能の追加検討であり緊急性は低い。
- libwebrtc の音声実装がマイクに強く結合しており対応難度が高く、まずは実現方法の調査段階のため Low とする。

## 依存関係

`0038-investigate-stereo-audio-receive.md` は libwebrtc の audio_device 実装（`AudioDeviceModuleIOS`）の構造を調査する。本 issue が調査する経路 1（`RTCAudioDeviceModule` の差し替え）は、同レイヤーへの介入可能性を前提とするため、 0038 で得られる audio_device の構造把握が本 issue の判断材料となる。なお 0038 は playout（受信側）にフォーカスしており、本 issue は recording（送信側）にフォーカスするため調査対象は異なる。

## 現状

任意の音声データ（マイク以外、または複数ソースを合成した音声）を送信する API が存在しない。音声トラックは `createNativeAudioTrack` で生成しており、 `RTCAudioSource` はデバイスのマイク入力を前提としている（`Sora/NativePeerChannelFactory.swift:138-144`）。

```swift
// Sora/NativePeerChannelFactory.swift:138-144
func createNativeAudioTrack(
  trackId: String,
  constraints: RTCMediaConstraints
) -> RTCAudioTrack {
  let audioSource = nativeFactory.audioSource(with: constraints)
  return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
}
```

現在の `AudioDeviceModuleWrapper`（`Sora/AudioDeviceModuleWrapper.swift`）は `RTCAudioDeviceModule` の録音の pause/resume（ハードミュート）のみをラップするクラスであり、カスタム音声ソースの供給経路は実装されていない。SDK に `AVAudioEngine` によるミキシングや合成済み音声バッファーを送信トラックへ供給する経路は存在しない。

## 設計方針

本 issue は調査までを範囲とし、以下の経路が技術的に実現可能かを切り分ける。既存のマイク送信経路は変更しないことを前提とする。SDK 側で対応するか、サンプルで対応するかの方針も調査の中で整理する。

調査すべき実現経路:

1. **`RTCAudioDeviceModule` の差し替え**: `NativePeerChannelFactory.init` では `RTCAudioDeviceModule` を `RTCPeerConnectionFactory` の `audioDeviceModule:` 引数に渡している（`Sora/NativePeerChannelFactory.swift:43-56`）。`RTCAudioDeviceModule` は ObjC クラスで libwebrtc の C++ `AudioDeviceModule` へのブリッジであるため、独自サブクラスを作成して C++ 仮想関数を経由するカスタム音声入力を供給できるかが不明である。調査の起点は WebRTC パッケージ（SPM キャッシュまたは Pods の `WebRTC.xcframework` 内）に含まれるヘッダー（`RTCAudioDeviceModule.h` 等）であり、 ObjC からのサブクラス化または委譲が可能かを確認する。
2. **`RTCAudioCustomProcessing`**: libwebrtc の iOS ヘッダーに `RTCAudioCustomProcessing` プロトコルが存在するかを、パッケージヘッダーを grep して確認する。存在する場合、マイク音声に対して前処理としてミキシングを適用できるかを調査する。
3. **カスタム `AVAudioEngine` からの PCM 注入**: libwebrtc の VoiceProcessingIO は `AVAudioEngine` とは独立した Core Audio `AudioUnit` として動作するため、 `AVAudioEngine.installTap` で直接割り込むことはできない。現実的な経路としては、 `AVAudioEngine` で合成した `AVAudioPCMBuffer` を経路 1 のカスタム `RTCAudioDeviceModule` 実装に渡すことで送信音声として供給できるかを調査する。

調査の結果、 libwebrtc のソース変更が不可避、または C++ レイヤーへの ABI 依存が生じると判断された場合は、本 issue を `issues/pending/` へ移動し、その理由を明記する。

## 完了条件

- 上記の調査すべき実現経路それぞれについて、技術的に可能か不可能かの結論が出ていること。
- SDK レイヤーで対応するか、サンプルで対応するかの方針が決定していること（または pending 移動の判断が下されていること）。
- 調査結果と対応方針を本 issue の `## 解決方法` セクションに記載すること。

## 解決方法
