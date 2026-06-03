# libwebrtc の Swift Package 更新を自動化できるか調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-libwebrtc-package-update-automation

## 目的

libwebrtc のバージョン更新時に `Package.swift` のバージョン文字列と checksum を手作業で書き換えており、手順が煩雑でミスが起きやすい。Swift Package 側の更新をどこまで自動化できるかを調査し、自動化の対象範囲と方式を決定する。

## 優先度根拠

- バージョン更新のたびに発生する作業だが頻度は限られ、ユーザー影響のある不具合ではない。
- 自動化方式の選択に設計判断を要する調査段階であるため Low とする。

## 現状

Swift Package の libwebrtc 参照は `Package.swift` にハードコードされている。

```swift
let libwebrtcVersion = "m148.7778.7.0"
```

`Package.swift:6` でバージョン文字列を定義している。`binaryTarget` では webrtc-build のリリース URL と checksum を直接参照している。

```swift
.binaryTarget(
    name: "WebRTC",
    url: "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/\(libwebrtcVersion)/WebRTC.xcframework.zip",
    checksum: "df0f99daa66231adce88b4ae0e8b4672ab053842cc43ebe8120968e1337084f6"
),
```

`Package.swift:20`-`25` でリリースの `WebRTC.xcframework.zip` を `libwebrtcVersion` で組み立て、`checksum` に SHA-256 を直書きしている。バージョン更新時は `libwebrtcVersion` の書き換えと checksum の再計算・差し替えを手動で行う必要がある。

## 設計方針

Swift Package 側のバージョン・checksum 更新を自動化できるかを調査し、方式を決定する。

- 自動化の候補となる処理を整理する。
  - `Package.swift:6` の `libwebrtcVersion` を指定バージョンへ更新する。
  - 該当する webrtc-build リリースの `WebRTC.xcframework.zip` をダウンロードし、`swift package compute-checksum` もしくは `shasum -a 256` で SHA-256 を計算して `checksum` を更新する。
- 自動化の実現形態を比較する。
  - 案 A: `bin/` 配下のスクリプト（シェルまたは Swift）として用意し、引数でバージョンを受け取る。
  - 案 B: GitHub Actions ワークフロー（`workflow_dispatch` でバージョン入力）として用意し、更新内容を PR として提出する。
- 自動化後に Swift Package でビルドが通るかを確認する。

## 完了条件

- Swift Package のバージョン・checksum 更新を自動化する方式（案 A / 案 B）が決定し、本 issue にまとめられていること。
- checksum がダウンロードした `WebRTC.xcframework.zip` から実際に計算した値で更新されることが確認されていること。
- 自動化後に Swift Package でのビルドが通ることが確認されていること。
- 調査結果と決定した方式を本 issue の解決方法に記載すること。

## 解決方法
