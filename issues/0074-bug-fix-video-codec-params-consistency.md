# 映像コーデック種別とコーデックパラメーターの整合性を保証する

- Priority: High
- Created: 2026-07-06
- Completed:
- Model: GPT-5
- Branch: feature/fix-video-codec-params-consistency
- Polished: 2026-07-10

## 目的

`Configuration.videoCodec` と `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` の不整合な組み合わせを SDK 側で防ぐ。H.265 は 0011 で修正済みだが、VP9 / AV1 / H.264 は未対応であり、同一の設計上の問題を抱えている。

## 優先度根拠

High。`videoCodec` と `videoH265Params` の不整合で Sora サーバーが `invalid_video_format` を返して接続に失敗することを確認済み。VP9 / AV1 / H.264 も同じ問題を持ち、一括是正が必要。

## 現状

`PeerChannel` で `Configuration` の各 params を `SignalingConnect` へ引き渡しているが、H.265 のみ `videoCodec == .h265` のガードが入っており、VP9 / AV1 / H.264 は無条件で渡している。

```swift
// Sora/PeerChannel.swift:431-434
vp9Params: configuration.videoVp9Params,          // 無条件
av1Params: configuration.videoAv1Params,          // 無条件
h264Params: configuration.videoH264Params,        // 無条件
h265Params: configuration.videoCodec == .h265 ? configuration.videoH265Params : nil  // ガード済み
```

`Signaling.swift` のエンコードでも、VP9 / AV1 / H.264 の params は `videoCodec` にかかわらずエンコードされる。

## 設計方針

H.265 と同様に、VP9 / AV1 / H.264 も `videoCodec` と一致する場合のみ params を送信する。`PeerChannel` での絞り込みを基本とし、`Signaling` 側のエンコードでもガードを付ける（二重防御、0011 と同じパターン）。

### PeerChannel.swift

`sendConnectMessage` 内の `SignalingConnect` 生成箇所（`:431-433`）で、各 params を `videoCodec` に応じて絞る:

```swift
vp9Params: configuration.videoCodec == .vp9 ? configuration.videoVp9Params : nil,
av1Params: configuration.videoCodec == .av1 ? configuration.videoAv1Params : nil,
h264Params: configuration.videoCodec == .h264 ? configuration.videoH264Params : nil,
```

### Signaling.swift

エンコード時に `videoCodec` チェックを追加する（0011 の H.265 と同じパターン）:

```swift
if let vp9Params, videoCodec == .vp9 {
if let av1Params, videoCodec == .av1 {
if let h264Params, videoCodec == .h264 {
```

### videoCodec == .default の扱い

`.default` はサーバー選択に委ねる値であり、どのコーデック params とも整合しないため、すべての codec 固有 params を送らない。上記の `videoCodec == .vp9` 等のガードが偽になるため、自然にフィルタされる。

### ログ

不一致を検出した場合、何も出力しない。利用者が `videoH265Params` を設定して `videoCodec = .vp9` を指定した場合、params は単に送信されず、エラーにもならない。積極的に通知したい場合は別 issue で Configuration のバリデーションを検討する。

## テスト方針

モック・スタブは使用しない。既存の `SignalingConnectEncodingTests` に以下のケースを追加する。

- `videoCodec == .vp9` + `videoVp9Params` 設定 → `vp9_params` が含まれる
- `videoCodec == .h264` + `videoVp9Params` 設定 → `vp9_params` が含まれない
- `videoCodec == .default` + `videoVp9Params` 設定 → `vp9_params` が含まれない
- 同様のテストを AV1 / H.264 についても追加
- H.265 のコード不一致テストは 0011 で実装済みのため不要

## 完了条件

- VP9 / AV1 / H.264 / H.265 すべてで `videoCodec` と一致する場合のみ params が送信されること
- `videoCodec == .default` では codec 固有 params が一切送信されないこと
- テストがすべて通ること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [FIX] videoCodec と不一致の codec 固有パラメーターが送信される問題を修正する
    - @t-miya
  ```

## 解決方法
