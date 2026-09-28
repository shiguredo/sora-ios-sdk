# VideoRenderer の実行キューを指定できるようにする

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-videorenderer-custom-queue
- Polished: 2026-09-24

## 概要

`VideoRenderer` プロトコルの実装メソッドを実行するキューを利用者が指定できるようにする。現在はメインキュー固定になっており、重い処理を実装するとメインキューへの負荷が増大して UI 更新に影響する可能性がある。

## 現状

`StreamFrameOwner`（`Sora/StreamFrameOwner.swift`）が `VideoRenderer` の 7 種類の callback（`onChange(size:)` / `render(videoFrame:)` / `onDisconnect(from:)` / `onAdded(from:)` / `onRemoved(from:)` / `onSwitch(video:)` / `onSwitch(audio:)`）をすべて main queue へ最終配送する。利用者が独自に別のキューへ移すことは `render(videoFrame:)` の実装内で `DispatchQueue.global().async` を呼ぶことで可能だが、callback ごとに手動で移す必要があり、API として明示的にサポートされていない。

## 設計方針

`VideoRenderer` プロトコルに実行キューを指定するプロパティを追加する。

```swift
public protocol VideoRenderer: AnyObject {
    // nil のときは main queue へ最終配送する
    var queue: DispatchQueue? { get }
    func render(videoFrame: VideoFrame?)
}
```

- `queue` は 7 種類すべての callback の最終配送先に適用する (callback の種類と登録経路は変更しない)
- デフォルト実装で `queue` を `nil` とし、既存の実装者に変更不要にする (`extension VideoRenderer { var queue: DispatchQueue? { nil } }`)
- `StreamFrameOwner` は `queue` が指定されていればそのキューへ、指定がなければ main queue へ最終配送する (順序は `0105` の owner queue が決める)
- 順序を保証するため、利用者 queue は直列 queue を前提とする。並行 queue では最終配送の呼び出し順が保証されないためである
- `VideoView` を含む UI 描画は本 issue の対象外とし、UI 専用の MainActor 契約は `0027` に委ねる

## `0105` との関係

`0105` で 7 種類の renderer callback の最終配送が main queue に統一され、最終配送の実行箇所は `StreamFrameOwner` の `appendDeliveryLocked` / `deliverNextOnMainQueue` になった。`0060` はその最終配送先を利用者 queue に置き換える issue である。

- 順序の決定は `0105` の `StreamFrameOwner` の owner queue が担い、利用者 queue は最終配送先としてだけ使う (順序と drop の判断を利用者 queue へ委ねない)。
- 本 issue の対象は最終配送先の置き換えであり、callback の種類と登録経路は変更しない。

## `0027` との関係

`0027`（VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する）は UI 描画用の `@MainActor` renderer protocol を追加し、`VideoView` を新経路へ移行する。legacy の `VideoRenderer` と `MediaStream.videoRenderer` の型は `0027` では変更しない。

- 本 issue は legacy `VideoRenderer` に custom executor 契約 (`queue`) を追加し、non-UI renderer（映像処理、機械学習などの用途）を対象とする。
- UI 描画は `0027` の MainActor 契約に委ねる。本 issue は UI 用 protocol へ `queue` を追加しない (MainActor 配送を型で保証する契約と矛盾しないようにするため)。
- `0027` は legacy protocol 全体の deprecation を本 issue の custom executor 契約と移行先が確定した後に判断するとしている。本 issue が定める `queue` 契約と直列 queue 前提がその移行判断の前提になる。

## 完了条件

- `VideoRenderer` プロトコルに `var queue: DispatchQueue? { get }` が追加され、デフォルト実装で `nil` が返ること (既存の実装者に変更不要であること)。
- `StreamFrameOwner` の renderer callback の最終配送先が、`queue` 指定時はそのキュー、`nil` のときは main queue になること。
- 7 種類すべての callback が同じ配送先を使い、順序付けと drop の判断を利用者 queue へ委ねず、owner の配送ロジックが担っていること。
- `queue` 未設定の既存実装者と `VideoView` の挙動が変わらないこと。
- renderer callback の executor 契約が `Sora/VideoRenderer.swift` の doc と `skills/sora-ios-sdk/SKILL.md` に記載され、`CHANGES.md` の `## develop` に追記されていること。

## 根拠

映像処理などの重い処理を含む `render(videoFrame:)` 実装をメインキューで実行することは UI のフレームドロップに直結する。利用者が安全に実行キューを制御できる手段を SDK として提供することで、パフォーマンス上の問題を根本的に解決できる。
