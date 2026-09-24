# async/await に対応する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-async-await
- Polished: 2026-09-24

## 目的

`Sora.connect()` に `async throws` バージョンを追加し、Swift Concurrency を使うアプリから SDK の接続処理を簡潔に記述できるようにする。

## 優先度根拠

Swift Concurrency は Swift 5.5 以降の標準的な非同期処理モデルであり、現在 SDK が `completionHandler` のみを提供していることで利用者側に余分なラッパーコードが生じている。ただし既存の completionHandler ベース API は維持する後方互換対応であるため Medium とする。

## 現状

`Sora.connect()` の現在のシグネチャ（`Sora.swift` の `Sora.connect(configuration:webRTCConfiguration:handler:)`）:

```swift
public func connect(
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
    handler: @escaping (_ mediaChannel: MediaChannel?, _ error: Error?) -> Void
) -> ConnectionTask
```

- handler 型が `(MediaChannel?, Error?) -> Void` であり、成功時に `MediaChannel` を返す。実装では error があれば `handler(nil, error)`、なければ `handler(mediaChannel, nil)` のどちらか一方だけが呼ばれる
- 戻り値 `ConnectionTask`（`Sora.swift` の `ConnectionTask.cancel()`）は、接続試行中のキャンセルに使用する
- `MediaChannel.connect(webRTCConfiguration:onPrepared:handler:)`（`Sora/MediaChannel.swift`）は `internal` であり、利用者向け公開 API は `Sora.connect()` のみ
- `MediaChannel.disconnect(error:)`（`Sora/MediaChannel.swift`）は同期 API のため async 化の対象外
- `MediaChannelHandlers.onConnect`（`Sora/MediaChannel.swift` の `MediaChannelHandlers`）は接続試行完了時に呼ばれるハンドラであり、型は `((Error?) -> Void)?` である

completionHandler ベースの公開 API のうち、async 化が残っているものは次のとおり。

- `Sora.connect()`: `Sora.swift` の `Sora.connect(configuration:webRTCConfiguration:handler:)`（本 issue の対象）
- `MediaChannel.getStats(handler:)`: `Sora/MediaChannel.swift` の `getStats(handler:)`（async 化は `0120` が担当するため本 issue の対象外）
- `CameraVideoCapturer` の `start(format:frameRate:completionHandler:)` / `stop(completionHandler:)` / `restart(completionHandler:)` / `change(format:frameRate:completionHandler:)`: `Sora/CameraVideoCapturer.swift`（本 issue の対象外）

内部実装（`PeerChannel`・`SignalingChannel` 等）を Swift Concurrency で書き直すことは本 issue のスコープ外とする。

## 設計方針

### `Sora.connect()` の async 版

`Sora.swift` に以下の async ラッパーを追加する（既存の completionHandler 版は維持）:

```swift
public func connect(
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration? = nil
) async throws -> MediaChannel
```

- async 版は `handler` 引数を持たず、パラメータリストが既存版と異なるため、通常の overload 規則で共存できる（`handler:` を渡す既存の呼び出しは completionHandler 版のみに解決される）。なお `async` の有無だけが異なる overload も、SE-0296 の合意済み修正により同期・非同期コンテキストのどちらかが選択されて許容される
- `webRTCConfiguration` 引数は `0153` の完了後にその引数整理（optional・`nil` 既定値・正本は `Configuration.webRTCConfiguration`・指定時は引数を優先）へ揃える。`0153` のスコープ外に「async 版 `Sora.connect`。実装時は本 issue と同じ引数の扱い（optional・`nil` 既定値・正本の上書き）に揃える」と記載されているため、本 issue の実装は `0153` の完了後に着手する
- `withCheckedThrowingContinuation` で既存の completionHandler 版をラップする。`handler` で `mediaChannel != nil` なら `continuation.resume(returning:)`、`error != nil` なら `continuation.resume(throwing:)` を呼ぶ。handler は接続試行の終端で 1 回だけ呼ばれることを前提とできる（`0092` がキャンセル終端を一意化済み）

`SoraHandlers.onConnect`（`Sora.swift`、型: `((MediaChannel?, Error?) -> Void)?`）との関係: async 版は内部的に同じ completionHandler 版を呼ぶため、`SoraHandlers.onConnect` ハンドラは引き続き呼ばれる。async 版の `continuation.resume` は handler 内でのみ呼び、`SoraHandlers.onConnect` は通知用途として独立して動作する（`withCheckedThrowingContinuation` の `resume` は一度しか呼べないため二重通知にはならない）。`MediaChannelHandlers.onConnect`（`Sora/MediaChannel.swift`、型: `((Error?) -> Void)?`）は接続試行完了時に呼ばれる別のハンドラであり、こちらも影響を受けない。

### 接続試行のキャンセルと終端

async 版は戻り値が `MediaChannel` のみであり、既存の `ConnectionTask` を利用者へ返さない。接続試行をキャンセルできるのは `ConnectionTask.cancel()` だけのため、`MediaChannel.rpc(method:params:...)`（`Sora/MediaChannel.swift`）が行うのと同じく `withTaskCancellationHandler` を使い、呼び出し元の Task がキャンセルされたら内部で生成した `ConnectionTask.cancel()` を 1 回だけ呼ぶ。

- `onCancel` は別スレッドから呼ばれ得るため、`ConnectionTask` の参照はロックで保護したボックス（`MediaChannel.rpc` の `CancelledRPCIDStore` と同じ考え方）で共有する
- キャンセル成立時は `continuation.resume(throwing:)` で終端し、接続成功の callback は発火させない（`0092` の「キャンセル後は接続成功 callback を発火させない」に従う）

### `MainActor` との整合

`0027`（VideoRenderer の MainActor 移行）が完了しているかにかかわらず、本 issue の async ラッパー追加は独立して実施できる。ラッパーは既存の completionHandler 版を呼ぶだけであり、スレッドモデルは変わらない。

一方、async 版の引数（`Configuration`・`WebRTCConfiguration`）と戻り値（`MediaChannel`）は `Sendable` ではない（`Sora/Configuration.swift` の `Configuration`、`Sora/WebRTCConfiguration.swift` の `WebRTCConfiguration`、`Sora/MediaChannel.swift` の `MediaChannel`）。`0107` の Swift 6 consumer fixture（strict concurrency と warnings-as-errors）に `try await` の compile scenario を追加し、actor / Task 境界からの呼び出しで診断が出る場合は、`0152` が追加する公開 Sendable 設定型を受け取る overload へ揃える。

## 前提となる issue

- `0092`（完了）: `ConnectionTask` のキャンセル終端の一意化。本 issue のキャンセル設計が依拠する。async 接続 API の追加は本 issue のスコープであると明記されている
- `0102`（完了 2026-09-16）: 接続設定の snapshot 化。async 版は既存 overload と同じ snapshot 生成経路を使う
- `0107`（open）: Swift 6 consumer fixture と公開 API baseline。async API の compile scenario の追加先
- `0120`（open）: `MediaChannel.getStats()` の async 化（snapshot 型・cancellation と exactly-once）を担当する
- `0152`（open）: 公開 Sendable 設定型と `Sora.connect` の新 overload。async 版の引数型（`Configuration` か公開設定型か）の最終形に影響する
- `0153`（open）: `webRTCConfiguration` 引数の整理。async 版は同じ扱いに揃える。実装は `0153` の完了後に着手する

## スコープ外

- `MediaChannel.getStats()` の async 化: `0120` が担当する
- `CameraVideoCapturer` の各 API の async 化: 別 issue で検討する
- 内部実装（`PeerChannel`・`SignalingChannel` 等）の Swift Concurrency 対応
- 既存の completionHandler ベース API の削除・非推奨化（後方互換のない変更）

## 完了条件

- `Sora.connect()` の async 版（`async throws -> MediaChannel`）が追加されていること
- 既存の completionHandler ベースの `Sora.connect()` の挙動が変わらないこと
- `webRTCConfiguration` 引数の扱いが `0153` の完了後の仕様（optional・`nil` 既定値・正本の上書き・指定時は引数優先）と一致していること
- Task キャンセル時に接続試行が終端し、接続関連の callback が 1 回だけ呼ばれること
- `CHANGES.md` の `## develop` セクションに `[ADD]` として追記されていること。`shiguredo-changelog` の規約ではエントリを種別順（CHANGE → ADD → UPDATE → FIX）に並べるため、現在 `[UPDATE]` から始まる develop セクションでは `[UPDATE]` エントリの前に置く。エントリは次のとおり

```
- [ADD] Sora.connect() に async/await 版 API を追加する
  - @voluntas
```
