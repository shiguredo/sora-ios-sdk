# H.265 向け映像コーデックパラメーターに対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-video-h265-params

## 目的

`Configuration` に H.265 向けの映像コーデックパラメーター `videoH265Params` を追加し、connect メッセージへ送信できるようにする。VP9 / AV1 / H.264 には既存だが H.265 だけが欠けており、コーデック間で API の一貫性を保つために追加する。

## 優先度根拠

Medium とする。既存の他コーデック（VP9 / AV1 / H.264）と機能を揃えるための追加であり、H.265 利用時にパラメーター指定ができない欠落を埋めるものである。既存機能の不具合ではないため High ではない。

## 現状

`videoH264Params` 等は以下の箇所で扱われているが、H.265 向けは存在しない。

`Configuration` には他コーデックのパラメーターが定義済みで、`videoH265Params` だけが無い。

```swift
/// VP9 向け映像コーデックパラメーター
public var videoVp9Params: Encodable?

/// AV1 向け映像コーデックパラメーター
public var videoAv1Params: Encodable?

/// H264 向け映像コーデックパラメーター
public var videoH264Params: Encodable?
```

`Sora/Configuration.swift:228`

`SignalingConnect` にも `vp9Params` / `av1Params` / `h264Params` はあるが `h265Params` が無い（`Sora/Signaling.swift:364`）。JSON エンコード用の `VideoCodingKeys` にも `h265_params` が無い。

```swift
enum VideoCodingKeys: String, CodingKey {
  case codec_type
  case bit_rate
  case vp9_params
  case av1_params
  case h264_params
}
```

`Sora/Signaling.swift:895`

エンコード処理は `h264Params != nil` まで判定し、`h264_params` を出力しているが `h265_params` は無い。

```swift
if videoCodec != .default || videoBitRate != nil || vp9Params != nil || av1Params != nil
  || h264Params != nil
{
```

`Sora/Signaling.swift:949`

`PeerChannel` の connect 生成では `vp9Params` / `av1Params` / `h264Params` を渡しているが H.265 は渡していない。

```swift
vp9Params: configuration.videoVp9Params,
av1Params: configuration.videoAv1Params,
h264Params: configuration.videoH264Params
```

`Sora/PeerChannel.swift:413`

なお `VideoCodec` には `.h265` が既に定義されている（`Sora/VideoCodec.swift:33`）。

## 設計方針

`videoH264Params` の実装にならい、以下の箇所に H.265 向けの対応を追加する。

1. `Sora/Configuration.swift`: `videoH264Params`（`Sora/Configuration.swift:234`）の直後に `videoH265Params: Encodable?` を定義する。
2. `Sora/Signaling.swift`:
   - `SignalingConnect` に `h265Params: Encodable?` を追加する（`Sora/Signaling.swift:370` 付近）。
   - `VideoCodingKeys`（`Sora/Signaling.swift:895`）に `h265_params` を追加する。
   - エンコード判定（`Sora/Signaling.swift:949`）に `h265Params != nil` を加え、`h264Params` と同様に `videoContainer.superEncoder(forKey: .h265_params)` で出力する。
3. `Sora/PeerChannel.swift`: connect 生成（`Sora/PeerChannel.swift:415` 付近）に `h265Params: configuration.videoH265Params` を追加する。

## 後方互換

`videoH265Params` のデフォルト値は `nil` であり、指定されない限りエンコード判定に影響せず connect メッセージに `h265_params` を含めない。追加フィールドであり既存動作を一切変更しないため、後方互換性は保たれる。

## 完了条件

- `Configuration.videoH265Params` を指定すると、connect メッセージの `video.h265_params` として送信されること。
- 未指定時は connect メッセージに `h265_params` が含まれないこと。
- VP9 / AV1 / H.264 と同じ条件分岐で正しくエンコードされること。
- エンコード結果を検証するテストを追加すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] Configuration に H.265 向け映像コーデックパラメーター videoH265Params を追加する
    - @担当者
  ```

## 解決方法
