# WebSocketChannelInternalHandlers.onDisconnectWithError を改名する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-ondisconnectwitherror-rename

## 目的

`onDisconnectWithError` というハンドラ名は ObjC / Swift の命名慣習に照らすと不適切である。`with` は引数の前置詞であり、コールバック名に含めても意味を持たない。命名規則に沿って `onError` へ改名し、旧名は後方互換のため deprecated として残す。

## 優先度根拠

- 命名の改善が目的であり、動作上の不具合は無い。
- 不急のリファクタリングであるため Low とする。

## 現状

`onDisconnectWithError` が WebSocket チャネルの内部ハンドラとして定義・利用されている。`WebSocketChannelInternalHandlers` のプロパティとして宣言されている。

```swift
final class WebSocketChannelInternalHandlers {
  public var onConnect: ((URLSessionWebSocketChannel) -> Void)?
  public var onDisconnectWithError: ((URLSessionWebSocketChannel, Error) -> Void)?
  public var onReceive: ((WebSocketMessage) -> Void)?
  public init() {}
}
```

`Sora/WebSocketChannel.swift:143` で宣言している。切断時に error がある場合に発火する。

```swift
if let error {
  Logger.debug(
    type: .webSocketChannel,
    message: "[\(host)] error: \(error.localizedDescription)")
  internalHandlers.onDisconnectWithError?(self, error)
}
```

`Sora/URLSessionWebSocketChannel.swift:90` で発火し、`Sora/URLSessionWebSocketChannel.swift:77` のコメントでも名称を参照している。ハンドラの設定は `Sora/SignalingChannel.swift:156` で行われている。

```swift
ws.internalHandlers.onDisconnectWithError = { [weak self] ws, error in
```

`WebSocketChannelInternalHandlers` 自体はアクセス修飾子のない `final class`（internal）であり、プロパティに `public` が付いていてもコンテナ型が internal のためモジュール外からは参照できない。

## 設計方針

- `onDisconnectWithError` を命名規則に沿った `onError` へ改名する。
  - 「error がセットされたとき（切断やネットワークエラー時）に発火する」という当該ハンドラの実態を端的に表し、`with` のような無意味な前置詞を含まない。
- 後方互換のため旧名 `onDisconnectWithError` を削除せず deprecated 化して残す。
  - 真の格納プロパティを新名 `onError` とし、`onDisconnectWithError` は `onError` へ委譲する computed property（`get` / `set`）として残す。
  - `@available(*, deprecated, message: "Use onError instead.")` を付与する。
- 内部の設定箇所・発火箇所（`URLSessionWebSocketChannel` / `SignalingChannel`）はすべて新名 `onError` を参照するよう更新する。
- 発火タイミング・引数（`(URLSessionWebSocketChannel, Error)`）は変更しない。

## 完了条件

- `WebSocketChannelInternalHandlers` に新名 `onError` の格納プロパティが追加され、内部の設定・発火箇所がすべて新名を参照していること。
- 旧名 `onDisconnectWithError` が新名への委譲として残り、deprecated 化されていること。
- ハンドラの発火タイミング・引数が変更前後で同一であること。
- 関連コメント（`Sora/URLSessionWebSocketChannel.swift:77` 等）の名称が新名に更新されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [CHANGE] WebSocketChannelInternalHandlers.onDisconnectWithError を onError へ改名し、旧名を deprecated にする
    - @担当者
  ```

## 解決方法
