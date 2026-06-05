# type: connect の audio.opus_params に対応する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-opus-params

## 目的

`Configuration` に Opus 固有のパラメーター `opus_params` を指定できるようにし、`type: connect` シグナリングメッセージの `audio.opus_params` として送信できるようにする。`opus_params` には `channels` / `clock_rate` / `maxplaybackrate` / `minptime` / `ptime` / `stereo` / `sprop_stereo` / `useinbandfec` / `usedtx` といった Opus 固有のパラメーターが含まれ、ステレオ送信や FEC / DTX などの細かい音声設定をユーザーが制御できるようになる。

## 優先度根拠

- 既存機能の不具合ではなく利便性向上を目的とした機能追加であり、緊急性は低い。
- Opus の細かい音声設定を制御できるようにする補助的な機能のため Low とする。

## 現状

`Configuration` から送信できる音声設定は `audioCodec` と `audioBitRate` に限られており、`opus_params` を送信する経路が存在しない。

`Configuration` には `audioCodec` と `audioBitRate` のみが定義されている。

```swift
// Sora/Configuration.swift:124-128
/// 音声コーデック。デフォルトは `.default` です。
public var audioCodec: AudioCodec = .default

/// 音声ビットレート。デフォルトは無指定です。
public var audioBitRate: Int?
```

`SignalingConnect` も音声については `audioCodec` / `audioBitRate` のみを保持する。

```swift
// Sora/Signaling.swift:307-311
/// 音声コーデック
public var audioCodec: AudioCodec

/// 音声ビットレート
public var audioBitRate: Int?
```

`encode(to:)` では `audio` コンテナに `codec_type` と `bit_rate` のみをエンコードしており、`opus_params` をエンコードしていない。`audio` コンテナを生成する条件にも `opus_params` が含まれていない。

```swift
// Sora/Signaling.swift:980-993
if audioEnabled {
  if audioCodec != .default || audioBitRate != nil {
    var audioContainer =
      container
      .nestedContainer(
        keyedBy: AudioCodingKeys.self,
        forKey: .audio)
    if audioCodec != .default {
      try audioContainer.encode(audioCodec, forKey: .codec_type)
    }
    try audioContainer.encodeIfPresent(
      audioBitRate,
      forKey: .bit_rate)
  }
} else {
  try container.encode(false, forKey: .audio)
}
```

`AudioCodingKeys` には `opus_params` のキーが無い。

```swift
// Sora/Signaling.swift:903-906
enum AudioCodingKeys: String, CodingKey {
  case codec_type
  case bit_rate
}
```

一方、映像コーデックパラメーターは `Encodable?` 型で `Configuration` から `SignalingConnect` まで透過的に渡され、ネストしたコンテナにエンコードされている。

```swift
// Sora/Signaling.swift:963-974
if let vp9Params {
  let vp9ParamsEnc = videoContainer.superEncoder(forKey: .vp9_params)
  try vp9Params.encode(to: vp9ParamsEnc)
}
if let av1Params {
  let av1ParamsEnc = videoContainer.superEncoder(forKey: .av1_params)
  try av1Params.encode(to: av1ParamsEnc)
}
if let h264Params {
  let h264ParamsEnc = videoContainer.superEncoder(forKey: .h264_params)
  try h264Params.encode(to: h264ParamsEnc)
}
```

## 設計方針

- 映像コーデックパラメーター (`vp9Params` / `av1Params` / `h264Params`) と同じ設計に揃え、`opus_params` を `Encodable?` として `Configuration` から `SignalingConnect` まで透過的に渡す。SDK 側で個別パラメーターの型を厳密に持たないため、サーバーの仕様変更にも追従しやすい。
- 新規プロパティのデフォルトは `nil` とし、`nil` の場合は `opus_params` をエンコードしない。後方互換性を維持する。
- 現状の `audio` コンテナ生成条件 `audioCodec != .default || audioBitRate != nil` では `opus_params` のみ指定したケースで `audio` コンテナが生成されないため、`opus_params` が存在する場合も `audio` コンテナを生成するよう条件を拡張する。

## 完了条件

- `Configuration` に `opus_params` を指定するプロパティ (`Encodable?`) が追加されている。
- `Configuration.audioOpusParams` を指定すると、シグナリング connect メッセージの `audio.opus_params` として送信されること。
- `nil` の場合は `opus_params` がエンコードされず、既存の挙動が変更されていないこと (後方互換性が保たれている)。
- `opus_params` が正しく JSON にエンコードされること、および `nil` 時にエンコードされないことを検証するテストが `SoraTests/` に追加されている。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] Configuration に audio.opus_params を指定する audioOpusParams を追加する
    - @担当者
  ```

## 解決方法
