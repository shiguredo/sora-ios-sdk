# MediaStream に connectionId を追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-mediastream-connection-id

## 目的

`MediaStream`（内部実装は `BasicMediaStream`）が公開している `streamId` は、実質的に Sora の `connectionId` と同じ値である。しかしプロパティ名が `streamId` のため、これが接続 ID であることがわかりにくい。`connectionId` という名前のプロパティを追加し、ユーザーが接続 ID を直感的に取得できるようにする。

## 依存関係

`0013-investigate-local-stream-id-connection-id`（送信側ストリームの streamId 改善検討）と関連する。本 issue は受信側 MediaStream を対象としており論点は異なるが、connectionId の扱いについて整合を取ること。

## 優先度根拠

Low とする。具体的な不具合報告ではなく、API のわかりやすさ向上を目的とした改善であるため、緊急性は低い。

## 現状

`streamId` は `MediaStream` プロトコルで公開されている。

```swift
/// ストリーム ID
var streamId: String { get }
```

`Sora/MediaStream.swift:40`

`BasicMediaStream` が `streamId` を保持している。

```swift
var streamId: String = ""
```

`Sora/MediaStream.swift:118`

初期化時に `RTCMediaStream` の `streamId` を代入している。

```swift
streamId = nativeStream.streamId
```

`Sora/MediaStream.swift:260`

このため、サブスクライバーが受信したストリームの接続 ID を知りたい場合でも `streamId` という名前のプロパティを参照する必要があり、それが接続 ID であることが API 上明示されていない。

## 設計方針

後方互換性を維持するため、既存の `streamId` は削除せずそのまま残す。新たに `connectionId` プロパティを追加し、`streamId` をラップする（同じ値を返す）形で実装する。

具体的には、`Sora/MediaStream.swift:40` 付近のプロトコル定義に `var connectionId: String { get }` を追加し、`BasicMediaStream` には `streamId` を返すだけの computed property として実装する。

```swift
/// 接続 ID
/// 内部的には streamId と同じ値を返します。
var connectionId: String { streamId }
```

`connectionId` と `streamId` が一致することを検証するテストは `SoraTests/` に追加する。

`streamId` を非推奨にするかどうかはドキュメントとの整合性を含めて判断が必要だが、本 issue では後方互換を優先し、まずは `connectionId` の追加のみを行う。

## 完了条件

- `MediaStream` プロトコルに `connectionId` プロパティが追加されていること。
- `BasicMediaStream` が `connectionId` を実装し、`streamId` と同じ値を返すこと。
- 既存の `streamId` の挙動が変更されていない（後方互換が保たれている）こと。
- `connectionId` が `streamId` と一致することを検証するテストを追加すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] MediaStream に connectionId プロパティを追加する
    - @担当者
  ```

## 解決方法

