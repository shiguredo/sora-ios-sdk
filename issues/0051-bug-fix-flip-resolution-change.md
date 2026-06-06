# flip を 2 回した時に解像度が変わってしまう問題を修正する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-flip-resolution-change
- Polished: 2026-06-06

## 目的

`flip()` でカメラを前後に切り替えた際、バックカメラ → フロントカメラ → バックカメラという経路を経ると、最初に設定した解像度に戻らないバグを修正する。

## 優先度根拠

意図せぬ解像度の劣化は送信映像の品質に影響するため修正が必要。ただし切り替え先カメラが目標解像度をサポートしない場合にのみ発生し、フロントとバックの両方が同じ解像度に対応している場合は影響が出ない。Low とする。

## 現状

### バグの根本原因

`CameraVideoCapturer.flip()`（`CameraVideoCapturer.swift:104-158`）は切り替え先カメラのフォーマットを選択する際、`CameraSettings.resolution`（ユーザーが設定した目標解像度）ではなく「現在キャプチャしているフォーマットの実寸」を入力値として使っている（`CameraVideoCapturer.swift:120-126`）:

```swift
let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
guard
  let format = CameraVideoCapturer.format(
    width: dimension.width,
    height: dimension.height,
    for: flip.device,
    frameRate: capturer.frameRate!)
```

`CameraVideoCapturer.format(width:height:for:frameRate:)` は「指定解像度に最も近いフォーマット」を返す近似選択実装（`CameraVideoCapturer.swift:56-86`）。

### バグの再現経路

1. バックカメラで 1080p（1920x1080）に設定して起動する
2. `flip()` でフロントカメラに切り替える。フロントカメラが 1080p をサポートしない場合、近似選択アルゴリズムにより近い解像度（例: 720p = 1280x720）が選択される
3. 再度 `flip()` でバックカメラに戻す。このとき入力値は「フロントカメラが実際に使っていた 720p（1280x720）」であるため、バックカメラでも 720p が選択され元の 1080p に戻らない

`PeerChannel.initializeCameraVideoCapture()`（`PeerChannel.swift:624-625`）では `configuration.cameraSettings.resolution.width` / `.height` を使って初期フォーマットを選択しているが、`flip()` は `configuration` にアクセスする設計になっていないため、元の目標解像度が失われる。

## 設計方針

`CameraVideoCapturer` に元の目標解像度を保持するプロパティを追加し、`flip()` がそれを参照するように修正する。これにより `flip()` の public API シグネチャを変えずにバグを修正できる（シグネチャ変更は破壊的変更となるため避ける）。

`CameraVideoCapturer` に以下のプロパティを追加する（`CameraVideoCapturer.swift:184` の `format` プロパティの直後。CLAUDE.md の「コメントはしっかり入れること」の規約に従いコメントを付けること）:

```swift
/// `flip()` が解像度を維持するための目標解像度。`nil` の場合は現在フォーマットの実寸を使う
internal var targetResolution: CameraSettings.Resolution? = nil
```

`PeerChannel` は `CameraVideoCapturer` と同一モジュール内のため `internal` で十分。

`PeerChannel.initializeCameraVideoCapture()` の `capturer.start(format:frameRate:)` の completionHandler 内、`capturer.stream = stream` の直前に `capturer.targetResolution = configuration.cameraSettings.resolution` を設定する。このメソッドには `capturer.start()` を呼ぶ分岐が 2 箇所あるため、両方に追加すること:

- 第 1 分岐: `PeerChannel.swift:649` の `current.stop` のコールバック内で呼ばれる `capturer.start` の completionHandler（`PeerChannel.swift:657-668`）内の `capturer.stream = stream`（667 行目）の直前
- 第 2 分岐: `PeerChannel.swift:671` の `else` ブランチの `capturer.start` の completionHandler（671-682 行目）内の `capturer.stream = stream`（681 行目）の直前

`flip()` 内の `dimension` の算出（`CameraVideoCapturer.swift:120`）を以下のように修正する（107 行目で `capturer.format` を unwrap した変数 `format` を取得済み。122 行目以降で同名の `format` が shadow されるが、`dimension` の算出は 120 行目であり 107 行目の `format` を参照する）:

```swift
// 修正後: targetResolution があればその目標解像度を使う。なければ実寸にフォールバック
let dimension: CMVideoDimensions
if let target = capturer.targetResolution {
    dimension = CMVideoDimensions(width: target.width, height: target.height)
} else {
    dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
}
```

`flip()` 実行後、`flip.stream = capturer.stream`（`CameraVideoCapturer.swift:154`）の直後、`completionHandler(nil)`（155 行目）の前に `flip.targetResolution = capturer.targetResolution` を追加して目標解像度を引き継ぐ。

`change(format:frameRate:completionHandler:)` は `AVCaptureDevice.Format` を直接引数に取るため `targetResolution` は変化しない（呼び出し側が特定の `Format` を選んでいるため、`targetResolution` の上書きは行わない）。`change()` 後に `flip()` を呼んだ際に `targetResolution` の古い値が使われる動作の是非は別 issue で検討する。

## 完了条件

- バックカメラで 1080p に設定して接続した後、`flip()` を 2 回（バック → フロント → バック）実行すると、バックカメラが再び 1080p で動作すること
- `flip()` を 1 回（バック → フロント）実行した場合、フロントカメラが対応可能な最近似解像度が選択されること（挙動変化なし）
- 初期設定（`targetResolution == nil`）の場合は従来通り現在のフォーマットの実寸を基準に選択されること（後方互換）
- `PeerChannel.initializeCameraVideoCapture()` の `capturer.start()` を呼ぶ 2 つの分岐（`current.stop` コールバック内の分岐と `else` ブランチ）の両方で `capturer.targetResolution` を設定していること
- `change()` を呼んでも `targetResolution` は変化しないこと（`change()` は `AVCaptureDevice.Format` 直接指定のため影響しない）
- `CHANGES.md` の `## develop` セクションにある既存の `[FIX]` エントリの最後に以下を追記すること

```
- [FIX] flip を 2 回した時に元の解像度に戻らないバグを修正する
  - @voluntas
```

