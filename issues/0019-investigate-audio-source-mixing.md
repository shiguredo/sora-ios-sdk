# 複数音声ソースを mix して送信できるか検討する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-audio-source-mixing

## 目的

マイク以外の音声、または複数音声ソースを合成した音声を Sora に送信できるようにするかどうかを検討する。マイク入力とアプリ内の別音声 (例: ゲーム音声) を `AVAudioEngine` 等でミックスし、合成した音声データを送信できるようにすることを想定する。

## 優先度根拠

- 既存機能の不具合ではなく、新規機能の追加検討であり緊急性は低い。
- libwebrtc の音声実装がマイクに強く結合しており対応難度が高く、まずは実現方法の調査段階のため Low とする。

## 現状

任意の音声データ (マイク以外、または複数ソースを合成した音声) を送信する API が存在しない。音声トラックは `createNativeAudioSource` / `createNativeAudioTrack` で生成しており、`RTCAudioSource` はデバイスのマイク入力を前提としている。任意の音声サンプルをこの `RTCAudioSource` に流し込む API は提供していない。

```swift
// Sora/NativePeerChannelFactory.swift:134-144
func createNativeAudioSource(constraints: MediaConstraints?) -> RTCAudioSource {
  nativeFactory.audioSource(with: constraints?.nativeValue)
}

func createNativeAudioTrack(
  trackId: String,
  constraints: RTCMediaConstraints
) -> RTCAudioTrack {
  let audioSource = nativeFactory.audioSource(with: constraints)
  return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
}
```

送信用ストリームへの音声トラック追加も、ソースはマイク前提である。

```swift
// Sora/NativePeerChannelFactory.swift:168-176
if let trackId = audioTrackId {
  Logger.debug(
    type: .nativePeerChannel,
    message: "create native audio track (\(trackId))")
  let audioTrack = createNativeAudioTrack(
    trackId: trackId,
    constraints: constraints.nativeValue)
  nativeStream.addAudioTrack(audioTrack)
}
```

受信音声を取り出す `RTCAudioTrackSink` 関連 API は存在するが、これは受信側であり任意音声の送信には使えない。

```swift
// Sora/MediaStream.swift:82-88
/// RTCAudioTrackSink を RTCAudioTrack に関連付けます。
func addAudioTrackSink(_ sink: RTCAudioTrackSink)

/// RTCAudioTrackSink の関連付けを解除します。
/// 未追加の RTCAudioTrackSink を指定した場合は何もしません。
func removeAudioTrackSink(_ sink: RTCAudioTrackSink)
```

`AVAudioEngine` を用いたミキシングや、合成済み音声バッファーを送信トラックへ供給する経路は実装されていない。

## 設計方針

- libwebrtc (iOS) で、マイク入力を置き換え / 加工して送信する公式な経路 (カスタム `RTCAudioDevice` 等) が利用できるかを調査する。
- `AVAudioEngine` でマイク入力とアプリ音声 (`AVAudioPlayerNode` 等) をミキサーノードで合成し、その出力 (`AVAudioPCMBuffer`) を libwebrtc の送信音声へ渡せるかを調査する。
- SDK のレイヤー (`Sora/AudioDeviceModuleWrapper.swift` 等の音声デバイス制御層) で対応すべきか、サンプル (クイックスタートアプリ) で実現すべきかを整理する。
- 既存のマイク送信経路は変更しないことを前提とする。後方互換性を維持する。
- 調査の結果、外部依存の追加や大きな設計判断が必要と判断された場合は、本 issue を `issues/pending/` へ移動し、その理由を明記する。

## 完了条件

- 複数音声ソースをミックスした音声を Sora に送信する実現方法が調査・整理されていること。
- 仮実装により、マイク音声とアプリ音声を合成した音声が Sora へ送信できることを確認できていること。
- SDK レイヤーで対応するか、サンプルで対応するかの方針が決定していること。
- SDK 側に変更が入る場合は、`CHANGES.md` の `develop` セクションに該当エントリを追記すること。

## 解決方法
