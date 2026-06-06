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
    func renderFrame(_ frame: RTCVideoFrame?)
}
```

- デフォルト実装で `queue` を `nil` とし、既存の実装者に変更不要にすることを検討する（`extension VideoRenderer { var queue: DispatchQueue? { nil } }`）
- `VideoRendererAdapter` は `queue` が指定されていればそのキューで、指定がなければ内部キューで実行する
- `VideoView` にも専用の内部キューを持たせることを検討する

## `0027` との関係

`0027`（VideoRenderer MainActor 移行）と方向性の確認が必要。MainActor 前提の API 設計との整合性を取ること。

## 根拠

映像処理など重い `renderFrame` 実装をメインキューで実行することは UI のフレームドロップに直結する。利用者が安全に実行キューを制御できる手段を SDK として提供することで、パフォーマンス上の問題を根本的に解決できる。
