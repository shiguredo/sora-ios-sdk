# async/await に対応する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-async-await
- Polished:

## 概要

Swift Concurrency（async/await）に対応した API を追加する。既存の completionHandler ベースの API は維持し、async/await 版を新規追加する。

## 背景

Swift 5.5（Xcode 13）で導入された async/await は Swift の非同期処理の標準となっており、iOS SDK を使う開発者の多くが async/await ベースのコードを書いている。SDK が completionHandler のみを提供し続けることで、利用者側に余分なラッパーコードが生じている。

## 対応方針

### Phase 1：公開 API に async/await バージョンを追加する

既存の `completionHandler` を受け取る API に対して `async throws` 版を追加する。

```swift
// 既存（維持）
func connect(completionHandler: @escaping (Error?) -> Void)

// 追加
func connect() async throws
```

主な対象:
- `MediaChannel.connect()`
- `MediaChannel.disconnect()`
- その他 completionHandler を持つ公開 API

### Phase 2：内部実装を Swift Concurrency で書き直す（将来）

- `PeerChannel`、`SignalingChannel` 等の内部実装を async/await + `Actor` で整理する
- `MainActor` の利用方針は `0027`（VideoRenderer MainActor 移行）と整合させる
- Phase 2 は破壊的変更を伴う可能性があるため慎重に判断する

## 根拠

Swift Concurrency は Swift 5.5 以降の標準的な非同期処理モデルであり、iOS SDK の利用者にとっても async/await で接続・切断処理を書けることは使いやすさの向上に直結する。
