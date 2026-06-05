# WebSocketChannelInternalHandlers.onDisconnectWithError を改名する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-ondisconnectwitherror-rename
- Polished: 2026-06-06

## 目的

`onDisconnectWithError` というハンドラ名は冗長であり、`onConnect` との対称性もない。`onConnect` / `onReceive` の命名パターンに揃え、`onDisconnect` へ改名する。

`WebSocketChannelInternalHandlers` は internal な final class であり、モジュール外に公開されていない。内部の全呼び出し箇所は一括更新できるため、deprecated による移行期間は設けずに直接リネームする。

## 優先度根拠

- 命名の改善が目的であり、動作上の不具合は無い。
- 不急のリファクタリングであるため Low とする。

## 現状

`WebSocketChannelInternalHandlers`（`Sora/WebSocketChannel.swift:141`）は `onConnect` / `onDisconnectWithError` / `onReceive` の 3 ハンドラを持つ。

`onDisconnectWithError` は以下の 4 箇所で参照される。

- 宣言: `Sora/WebSocketChannel.swift:143`
- 発火: `Sora/URLSessionWebSocketChannel.swift:90`（`if let error { ... }` ブロック内のみで発火する）
- 設定: `Sora/SignalingChannel.swift:156`
- コメント参照: `Sora/URLSessionWebSocketChannel.swift:77`

発火箇所の構造は以下のとおりで、エラーが nil でない場合にのみ発火する。

```swift
if let error {
  Logger.debug(
    type: .webSocketChannel,
    message: "[\(host)] error: \(error.localizedDescription)")
  internalHandlers.onDisconnectWithError?(self, error)
}
```

## 設計方針

- `onDisconnectWithError` を `onDisconnect` へ改名する。
  - `onConnect` の対称形であり、接続・切断イベントが自然なペアとして理解できる。
  - シグネチャ `(URLSessionWebSocketChannel, Error)` の `Error` 引数がエラー発生を型として表現するため、名前への `WithError` は不要。
- `onDisconnect` は現状エラーがある場合にのみ発火する（`if let error { ... }` ガード）。`onConnect` が全接続ケースで発火するのと非対称だが、シグネチャが常に `Error` を受け取る設計であり呼び出し側は必ずエラーが渡されると理解できる。`Sora/URLSessionWebSocketChannel.swift:77` のコメントを更新してエラー発生時のみ発火する旨を明示する。
- `SignalingChannelInternalHandlers`（`Sora/SignalingChannel.swift:23`）にも `onDisconnect` が存在するため、改名後の `SignalingChannel.swift` 内には `ws.internalHandlers.onDisconnect`（`WebSocketChannelInternalHandlers` のもの）と `weakSelf.internalHandlers.onDisconnect`（`SignalingChannelInternalHandlers` のもの）の 2 種類が共存する。コンパイルエラーは生じないが、`SignalingChannel.swift:156` の設定箇所のコメントで型の文脈（`WebSocketChannelInternalHandlers` であること）を明示する。
- 発火タイミング・引数（`(URLSessionWebSocketChannel, Error)`）は変更しない。

## テスト方針

モック・スタブは使用しない。

- `WebSocketChannelInternalHandlers` を直接テストするケースは存在しないため、コンパイルエラーが発生しないことを確認する。
- 既存のテストがすべてパスすること。

## 完了条件

- `Sora/WebSocketChannel.swift:143` の `onDisconnectWithError` プロパティが `onDisconnect` へ改名されていること。
- `Sora/URLSessionWebSocketChannel.swift:90` の発火箇所が `onDisconnect` を参照していること。
- `Sora/SignalingChannel.swift:156` の設定箇所が `onDisconnect` を参照しており、`WebSocketChannelInternalHandlers` の `onDisconnect` であることをコメントで明示していること。
- `Sora/URLSessionWebSocketChannel.swift:77` のコメントが `onDisconnect` を反映し、エラー発生時のみ発火する旨を示していること。
- `Sora/SignalingChannel.swift:155` 付近の切断時 error 挙動を説明するコメントが `onDisconnect` という新名と整合していること。
- ハンドラの発火タイミング・引数が変更前後で同一であること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること:
  ```
  - [UPDATE] WebSocketChannelInternalHandlers.onDisconnectWithError を onDisconnect へ改名する
    - @voluntas
  ```

## 解決方法
