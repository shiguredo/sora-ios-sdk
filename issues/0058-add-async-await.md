# async/await に対応する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-async-await
- Polished: 2026-06-06

## 目的

`Sora.connect()` に `async throws` バージョンを追加し、Swift Concurrency を使うアプリから SDK の接続処理を簡潔に記述できるようにする。

## 優先度根拠

Swift Concurrency は Swift 5.5 以降の標準的な非同期処理モデルであり、現在 SDK が `completionHandler` のみを提供していることで利用者側に余分なラッパーコードが生じている。ただし既存の completionHandler ベース API は維持する後方互換対応であるため Medium とする。

## 現状

`Sora.connect()` の現在のシグネチャ（`Sora.swift:171`）:

```swift
public func connect(
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
    handler: @escaping (_ mediaChannel: MediaChannel?, _ error: Error?) -> Void
) -> ConnectionTask
```

- handler 型が `(MediaChannel?, Error?) -> Void` であり、成功時に `MediaChannel` を返す
- 戻り値 `ConnectionTask` は接続試行中のキャンセルに使用する
- `MediaChannel.connect()` は `internal` であり、利用者向け公開 API は `Sora.connect()` のみ
- `MediaChannel.disconnect(error:)` は同期 API（`MediaChannel.swift:512`）のため async 化の対象外
- `MediaChannelHandlers.onConnect` は `MediaChannel.swift:22` に存在し、接続完了時に呼ばれる

completionHandler ベースの公開 API の全一覧（async 化の対象候補）:
- `Sora.connect()`: `Sora.swift:171`
- `MediaChannel.getStats(handler:)`: `MediaChannel.swift:581`
- `CameraVideoCapturer.start(format:frameRate:completionHandler:)`: `CameraVideoCapturer.swift:207`
- `CameraVideoCapturer.stop(completionHandler:)`: `CameraVideoCapturer.swift:247`
- `CameraVideoCapturer.restart(completionHandler:)`: `CameraVideoCapturer.swift:267`
- `CameraVideoCapturer.change(format:frameRate:completionHandler:)`: `CameraVideoCapturer.swift:315`

本 issue のスコープは `Sora.connect()` と `MediaChannel.getStats()` の async 化のみとし、`CameraVideoCapturer` の async 化は別 issue で検討する。

内部実装（`PeerChannel`・`SignalingChannel` 等）を Swift Concurrency で書き直すことは本 issue のスコープ外とする。

## 設計方針

### `Sora.connect()` の async 版

`Sora.swift` に以下の async ラッパーを追加する（既存の completionHandler 版は維持）:

```swift
public func connect(
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration()
) async throws -> MediaChannel
```

`withCheckedThrowingContinuation` で既存の completionHandler 版をラップする。`handler` で `mediaChannel != nil` なら `continuation.resume(returning:)`、`error != nil` なら `continuation.resume(throwing:)` を呼ぶ。

`SoraHandlers.onConnect`（`Sora.swift:8`、型: `((MediaChannel?, Error?) -> Void)?`）との関係: async 版では `SoraHandlers.onConnect` ハンドラは引き続き呼ばれる（内部的に同じ completionHandler 版を呼ぶため）。`SoraHandlers.onConnect` と async 版の `continuation.resume` の二重通知については、`withCheckedThrowingContinuation` の `resume` は一度しか呼べないため、handler 内でのみ resume を呼べばよい。`SoraHandlers.onConnect` は通知用途として独立して動作する。なお `MediaChannelHandlers.onConnect`（`MediaChannel.swift:22`、型: `((Error?) -> Void)?`）は接続試行完了時に呼ばれる別のハンドラであり、こちらも影響を受けない。

`ConnectionTask` のキャンセル対応: async 版で返す `ConnectionTask` をタスクキャンセル時に呼ぶ設計も検討に値するが、まず resume のみの基本実装を優先する。

### `MediaChannel.getStats()` の async 版

`MediaChannel.swift` に以下の async ラッパーを追加する（既存の completionHandler 版は維持）:

```swift
public func getStats() async throws -> Statistics
```

既存の `getStats(handler:)` の handler 型は `(Result<Statistics, Error>) -> Void` であるため、以下のパターンでラップする:

```swift
try await withCheckedThrowingContinuation { continuation in
    getStats { result in
        switch result {
        case .success(let stats):
            continuation.resume(returning: stats)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
```

### `MainActor` との整合

`0027-refactor-videorenderer-mainactor-migration.md` が完了しているかにかかわらず、本 issue の async ラッパー追加は独立して実施できる（ラッパーは既存の completionHandler 版を呼ぶだけであり、スレッドモデルは変わらない）。

## 完了条件

- `Sora.connect()` の async 版（`async throws -> MediaChannel`）が追加されていること
- `MediaChannel.getStats()` の async 版（`async throws -> Statistics`）が追加されていること
- 既存の completionHandler ベースの `Sora.connect()` の挙動が変わらないこと
- `CHANGES.md` の `## develop` セクションにある既存の `[ADD]` エントリの最後に以下を追記すること

```
- [ADD] Sora.connect() と MediaChannel.getStats() に async/await 版 API を追加する
  - @voluntas
```
