# H.265 向け映像コーデックパラメーターに対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-video-h265-params
- Polished: 2026-06-05

## 備考

`origin/feature/video-h265-params` (commit `e0a434e`) に本 issue と同一内容の実装が既に存在する。実装着手時はこのブランチの内容を確認し、流用可能であれば PR を作成する。

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

`Sora/Configuration.swift:228-234`

`SignalingConnect` にも `vp9Params` / `av1Params` / `h264Params` はあるが `h265Params` が無い（`Sora/Signaling.swift:364-370`）。JSON エンコード用の `VideoCodingKeys` にも `h265_params` が無い。

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

エンコード条件分岐は `h264Params != nil` まで判定し、`h264_params` を出力しているが `h265_params` は無い。

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

`Sora/PeerChannel.swift:413-415`

なお `VideoCodec` には `.h265` が既に定義されている（`Sora/VideoCodec.swift:33`）。

## 設計方針

`videoH264Params` の実装にならい、以下の箇所に H.265 向けの対応を追加する。

1. `Sora/Configuration.swift`: `videoH264Params`（`Sora/Configuration.swift:234`）の直後に以下を追加する:
   ```swift
   /// H265 向け映像コーデックパラメーター
   public var videoH265Params: Encodable?
   ```
2. `Sora/Signaling.swift`:
   - `SignalingConnect` に `h265Params` を追加する。`h264Params`（`Sora/Signaling.swift:370`）の直後に以下を追加する:
     ```swift
     /// H265 向け映像コーデックパラメーター
     public var h265Params: Encodable?
     ```
     `SignalingConnect` は `public struct` でありカスタムイニシャライザを持たない。メンバーワイズイニシャライザに `h265Params` が自動追加されるため、参照元（`PeerChannel.swift:413-415`）への引数追加が必要になる。SDK 外部で `SignalingConnect(...)` を直接構築しているコードが存在した場合は追加対応が必要だが、通常はそのような利用は行われない。
   - `VideoCodingKeys`（`Sora/Signaling.swift:895`）に `case h265_params` を追加する（`case h264_params` の直後）。
   - エンコード条件分岐（`Sora/Signaling.swift:949`）に `|| h265Params != nil` を追加する。
   - if ブロック内で `h264Params` と同様に `try videoContainer.encodeIfPresent(h265Params, forKey: .h265_params)` を追加する。
3. `Sora/PeerChannel.swift`: connect 生成の `h264Params`（`Sora/PeerChannel.swift:415`）の直後に以下を追加する:
   ```swift
   h265Params: configuration.videoH265Params,
   ```

### エッジケースの設計判断

- **`videoCodec != .h265` 時の `h265Params` 指定**: 既存の他コーデック（VP9 / AV1 / H.264）と同様に、`videoCodec` とパラメーターの整合性チェックは行わない。`h265Params` は `videoCodec` の値にかかわらず指定可能とし、実利用側の責任で整合性を保つ。この挙動は既存の `vp9Params` / `av1Params` / `h264Params` と一貫している。
- **デコードパス（受信側）**: `SignalingConnect` は `Decodable` に準拠しており、`VideoCodingKeys` に `h265_params` を追加することでサーバーからの受信時も自動デコードされる。既存の他 params と同様、受信時の特別な処理は不要。

## 後方互換

`videoH265Params` のデフォルト値は `nil` であり、指定されない限りエンコード判定に影響せず connect メッセージに `h265_params` を含めない。追加フィールドであり既存動作を一切変更しないため、後方互換性は保たれる。

## テスト方針

1. `videoH265Params` に任意の `Encodable` 値を設定した `Configuration` で生成した connect メッセージの JSON に `video.h265_params` が含まれることを検証する。
2. `videoH265Params` が `nil`（デフォルト）の場合、connect メッセージの JSON に `h265_params` が含まれないことを検証する。
3. `videoH264Params` と `videoH265Params` の両方を設定した場合、双方が正しくエンコードされることを検証する。

## 完了条件

- `Configuration.videoH265Params` を指定すると、connect メッセージの `video.h265_params` として送信されること。
- 未指定時は connect メッセージに `h265_params` が含まれないこと。
- VP9 / AV1 / H.264 と同じ条件分岐で正しくエンコードされること。
- エンコード結果を検証するテストが追加されていること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] Configuration に H.265 向け映像コーデックパラメーター videoH265Params を追加する
    - @担当者
  ```

## 解決方法
