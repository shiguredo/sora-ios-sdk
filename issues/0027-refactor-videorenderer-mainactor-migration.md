# VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-mainactor-video-renderer
- Polished: 2026-06-06

## 目的

Swift 6 の `sending` チェックにより、`VideoRendererAdapter` で `DispatchQueue.main.async` に `renderer` / `frame` を直接キャプチャするとビルドエラーになる。現在は受け渡し専用イベント型を `@unchecked Sendable` で扱う暫定対応で回避している。公開 API の互換性を維持したまま `@MainActor` 前提の新プロトコル `MainActorVideoRenderer` を追加し、`VideoView` をその新プロトコルに移行する。暫定対応の `@unchecked Sendable` ラッパーは `VideoRenderer` から `MainActorVideoRenderer` への移行が完全に完了した後に別途削除する。

## 優先度根拠

- 現状は暫定対応により Swift 6 ビルドが通っているため機能上の不具合はない。
- 緊急性が低いため Low とする。

## 現状

公開プロトコル `VideoRenderer`（`Sora/VideoRenderer.swift:40`）には `@MainActor` が付与されていない。これに直接 `@MainActor` を付与すると既存実装者の公開 API を破壊する。

Swift 6 の `sending` エラーを回避するため、受け渡し専用イベント型を `@unchecked Sendable` として定義している（`VideoRendererSizeEvent`：行 11、`VideoRendererFrameEvent`：行 29）。いずれも `weak var renderer: VideoRenderer?` を保持するため型として Sendable にできず、同時アクセスが起きない前提に依存している。

`VideoRendererAdapter.setSize(_:)`（行 74）と `renderFrame(_:)`（行 90）は上記イベント型を生成して `DispatchQueue.main.async` で main thread へ受け渡している。

`VideoView`（`Sora/VideoView.swift:186`）は `@preconcurrency VideoRenderer` として実装されており、TODO コメント（行 183）が残っている。

行 71 にも「VideoView / VideoRenderer の MainActor 整合性は別途根本対応する」旨の TODO が残っている。

## 設計方針

**新プロトコル `MainActorVideoRenderer` の追加**:

`Sora/VideoRenderer.swift` に次の公開プロトコルを追加する。

```swift
@MainActor
public protocol MainActorVideoRenderer: AnyObject {
  func onChange(size: CGSize)
  func render(videoFrame: VideoFrame?)
  func onDisconnect(from: MediaChannel?)
  func onAdded(from: MediaStream)
  func onRemoved(from: MediaStream)
  func onSwitch(video: Bool)
  func onSwitch(audio: Bool)
}
```

既存の `VideoRenderer` プロトコルは変更せずそのまま残す。

**`VideoRendererAdapter` の変更**:

`setSize(_:)` と `renderFrame(_:)` において、`videoRenderer` が `MainActorVideoRenderer` に準拠しているかを実行時に確認し、準拠している場合は `Task { @MainActor [renderer] in ... }` で呼び出す。

```swift
func renderFrame(_ frame: RTCVideoFrame?) {
  let videoFrame = frame.map { VideoFrame.native(capturer: nil, frame: $0) }
  if let renderer = videoRenderer as? any MainActorVideoRenderer {
    Task { @MainActor [renderer] in
      renderer.render(videoFrame: videoFrame)
    }
  } else {
    // @unchecked Sendable ラッパーを経由する旧パス（VideoRenderer 互換）
    let event = VideoRendererFrameEvent(renderer: videoRenderer, videoFrame: videoFrame)
    DispatchQueue.main.async { [event] in
      event.renderer?.render(videoFrame: event.videoFrame)
    }
  }
}
```

`MainActor.assumeIsolated` は呼び出し元が main actor 上であることが保証される場合にのみ使用できる。`setSize(_:)` / `renderFrame(_:)` は WebRTC 内部スレッドから呼ばれるため `assumeIsolated` は不適切であり、`Task { @MainActor in ... }` を使用する。`videoFrame` の型（`VideoFrame?`）が `Sendable` でない場合は `@unchecked Sendable` の付与が必要になるため、コンパイル時に確認すること。

**呼び出し順序に関する注意**:

`DispatchQueue.main.async` は直列キューであり `setSize` → `renderFrame` の enqueue 順を保証する。一方 `Task { @MainActor in ... }` は Swift concurrency のスケジューラに委ねられ、他の `@MainActor` タスクが割り込む可能性があるため `setSize` と `renderFrame` の相対的な実行順序が入れ替わり得る。現状の `VideoView` 実装がサイズ変更とフレーム描画の順序依存を持つかを確認し、問題がある場合はシリアルな `AsyncStream` 等で順序を保証する追加設計を検討すること。

**`VideoView` の移行**:

`VideoView` は `MainActorVideoRenderer` と `VideoRenderer` の両方に準拠させる。`extension VideoView: @preconcurrency VideoRenderer` を `extension VideoView: MainActorVideoRenderer, VideoRenderer` に変更する。これにより `MediaStream.videoRenderer: VideoRenderer?` への代入など既存コードへの影響なく `MainActorVideoRenderer` 準拠が追加される。`VideoView.swift:183` の TODO コメントを削除する。

なお `VideoView` は UIView サブクラスであり `@MainActor` 隔離されている。`VideoRenderer`（`@MainActor` なし）への準拠には引き続き `@preconcurrency` が必要になる可能性があるため、コンパイル結果を確認して対応すること。

**旧 `VideoRenderer` の deprecation**:

`VideoRenderer` プロトコルに `@available(*, deprecated, renamed: "MainActorVideoRenderer")` を付与して新 API への移行を案内する。Swift でプロトコル自体への `@available(*, deprecated)` 付与がコンパイルエラーになる場合は、プロトコルに Swift Doc コメントで `- Important: deprecated. Use MainActorVideoRenderer instead.` を追記し、`/// - Deprecated` タグで移行先を示す。

**暫定対応削除のスコープ**:

`VideoRendererSizeEvent`・`VideoRendererFrameEvent` と `@unchecked Sendable`、`VideoRenderer.swift:71` の TODO 削除は本 issue のスコープ外とする。`VideoRenderer` プロトコルを使用している全実装が `MainActorVideoRenderer` に移行完了した後に別途 issue を立てて行う。

## テスト方針

モック・スタブは使用しない。

- Swift 6 ビルドが通ること（`xcodebuild` または Xcode でビルドを実行しエラーがないことを確認）。
- `VideoView` を使った映像描画が引き続き main thread で呼ばれることを Xcode の Main Thread Checker を有効にして手動テストで確認すること。
- 既存の `VideoRenderer` 準拠実装（`VideoView` 以外の実装者が存在する場合）が破壊的変更なしでビルドできることを確認すること。

## 完了条件

- `Sora/VideoRenderer.swift` に `@MainActor public protocol MainActorVideoRenderer` が追加されていること。
- `VideoRendererAdapter` が `MainActorVideoRenderer` 準拠の renderer を `Task { @MainActor in ... }` で呼び出す経路を持ち、旧 `VideoRenderer` 向けの `@unchecked Sendable` ラッパー経路も維持されていること。
- `VideoView` が `VideoRenderer` 準拠を維持したまま `MainActorVideoRenderer` にも準拠し、`@preconcurrency` を除去していること（`VideoRenderer` 準拠の削除は本 issue のスコープ外）。
- `VideoView.swift:183` の TODO コメントが削除されていること。
- `VideoView` の `setSize` / `renderFrame` 呼び出し順序依存の有無を調査し、問題がある場合は対処方針を `## 解決方法` に記載するか別 issue に起票すること。
- `VideoRenderer` に `@available(*, deprecated, renamed: "MainActorVideoRenderer")` または同等の deprecation 案内が付与されていること。
- 既存の `VideoRenderer` 実装が破壊的変更なしでビルドできること。
- Swift 6 ビルドが通ること。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [ADD] MainActor 前提の映像描画プロトコル MainActorVideoRenderer を追加する
    - @voluntas
  ```

## 解決方法
