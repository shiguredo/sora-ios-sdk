# VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-videorenderer-mainactor-migration

## 目的

Swift 6 の `sending` チェックにより、`VideoRendererAdapter` で `DispatchQueue.main.async` に `renderer` / `frame` を直接キャプチャするとビルドエラーになる。現在は受け渡し専用イベント型を `@unchecked Sendable` で扱う暫定対応で回避している。公開 API の互換性を維持したまま、描画コールバックを main actor 前提で扱える設計へ移行し、暫定対応を解消する。

## 優先度根拠

- 純粋なリファクタリングであり、現状は暫定対応により Swift 6 ビルドが通っているため機能上の不具合はない。
- 緊急性が低いため Low とする。

## 現状

公開プロトコル `VideoRenderer` には `@MainActor` が付与されていない。これに直接 `@MainActor` を付与すると公開 API 互換性を壊す可能性がある。

```swift
// Sora/VideoRenderer.swift:40
public protocol VideoRenderer: AnyObject {
  /// 映像のサイズが変更されたときに呼ばれます。
  func onChange(size: CGSize)
  /// 映像フレームを描画します。
  func render(videoFrame: VideoFrame?)
  // ...
}
```

Swift 6 の `sending` エラーを回避するため、受け渡し専用イベント型を `@unchecked Sendable` として定義している。いずれも `weak var renderer: VideoRenderer?` を保持するため型として Sendable にできず、同時アクセスが起きない前提に依存している。

```swift
// Sora/VideoRenderer.swift:11
private final class VideoRendererSizeEvent: @unchecked Sendable {
  weak var renderer: VideoRenderer?
  let size: CGSize
  // ...
}
```

`VideoRendererAdapter` の `setSize(_:)`（`Sora/VideoRenderer.swift:74`）と `renderFrame(_:)`（`Sora/VideoRenderer.swift:90`）は、上記イベント型を生成して `DispatchQueue.main.async` で main thread へ受け渡している。

```swift
// Sora/VideoRenderer.swift:90
func renderFrame(_ frame: RTCVideoFrame?) {
  let videoFrame = frame.map { VideoFrame.native(capturer: nil, frame: $0) }
  let event = VideoRendererFrameEvent(renderer: videoRenderer, videoFrame: videoFrame)
  DispatchQueue.main.async { [event] in
    event.renderer?.render(videoFrame: event.videoFrame)
  }
}
```

`Sora/VideoRenderer.swift:71` に「VideoView / VideoRenderer の MainActor 整合性は別途根本対応する」旨の TODO が残っている。

## 設計方針

- 既存の `VideoRenderer` は互換性維持のため当面変更しない。
- `@MainActor` 前提の新しい描画 API を追加する（例: 新規プロトコルの追加）。`VideoRendererAdapter` は新 API 実装時に `MainActor.assumeIsolated` 等を用いて main actor 上で直接呼び出し、`sending` 回避ラッパーを経由しない経路を用意する。
- 段階移行期間を設け、旧 API は deprecate して新 API への移行を案内する。
- 移行完了後に暫定対応（`VideoRendererSizeEvent` / `VideoRendererFrameEvent` と `@unchecked Sendable`、`Sora/VideoRenderer.swift:71` の TODO）を削除する。
- 後方互換性: 既存の `VideoRenderer` 実装は破壊的変更なしでビルド可能であり続ける。新 API はオプトインで追加する。
- 参考として `Sora/VideoView.swift` の描画呼び出し経路も新 API へ追従させる。

## 完了条件

- 既存の `VideoRenderer` 実装が破壊的変更なしでビルドできること。
- 新 API 実装では `VideoRendererAdapter` の `sending` 回避ラッパーが不要になること。
- Swift 6 ビルドが通ること。
- 旧 API から新 API への移行手順がコードコメントまたは deprecation メッセージで明示されること。
- `CHANGES.md` の `## develop` セクションに `[ADD]` エントリと担当者行を追記すること。

## 解決方法
