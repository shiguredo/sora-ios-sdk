# VideoRenderer の実行キューを指定できるようにする

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-videorenderer-custom-queue
- Polished:

## 概要

`VideoRenderer` プロトコルの実装メソッドを実行するキューを利用者が指定できるようにする。現在はメインキュー固定になっており、重い処理を実装するとメインキューへの負荷が増大して UI 更新に影響する可能性がある。

## 現状

`VideoRendererAdapter`（`Sora/VideoRenderer.swift`）が `VideoRenderer` のメソッドを常にメインキューで実行している。利用者が独自に別キューに移すことは `renderFrame` の中で `DispatchQueue.global().async` を呼ぶことで可能だが、API として明示的にサポートされていない。

## 設計方針

`VideoRenderer` プロトコルに実行キューを指定するプロパティを追加する。

```swift
public protocol VideoRenderer: AnyObject {
    // nil のとき VideoRendererAdapter 内部のデフォルトキューで実行する
    var queue: DispatchQueue? { get }
    func render(videoFrame: VideoFrame?)
}
```

- デフォルト実装で `queue` を `nil` とし、既存の実装者に変更不要にすることを検討する（`extension VideoRenderer { var queue: DispatchQueue? { nil } }`）
- `VideoRendererAdapter` は `queue` が指定されていればそのキューへ最終配送し、指定がなければ main queue へ配送する (順序は `0105` の owner queue が決める)
- `VideoView` にも専用の内部キューを持たせることを検討する

## `0105` との関係

`0105` で 7 種類の renderer callback の最終配送が main queue に統一された。`0060` はその最終配送先を利用者 queue に置き換える issue である。

- 順序の決定は `0105` の `StreamFrameOwner` の owner queue が担い、利用者 queue は最終配送先としてだけ使う (順序と drop の判断を利用者 queue へ委ねない)。
- 本 issue の対象は最終配送先の置き換えであり、callback の種類と登録経路は変更しない。

## `0027` との関係

`0027`（VideoRenderer MainActor 移行）と方向性の確認が必要。MainActor 前提の API 設計との整合性を取ること。

## 根拠

映像処理など重い `renderFrame` 実装をメインキューで実行することは UI のフレームドロップに直結する。利用者が安全に実行キューを制御できる手段を SDK として提供することで、パフォーマンス上の問題を根本的に解決できる。
