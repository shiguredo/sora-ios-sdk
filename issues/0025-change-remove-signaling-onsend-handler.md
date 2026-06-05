# 送信シグナリングメッセージを書き換え可能な onSend ハンドラを削除する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-remove-signaling-onsend-handler
- Polished: 2026-06-06

## 目的

送信するシグナリングメッセージを任意に書き換え可能な内部ハンドラ `SignalingChannelInternalHandlers.onSend` を削除する。`onSend` は非公開クラスの非公開プロパティであり外部ユーザーからは到達不能だが、SDK 内部コードが誤って `onSend` を設定することで送信メッセージが予期せず書き換えられるリスクを排除するため、送信メッセージを差し替える内部経路自体を取り除く。

## 優先度根拠

- `onSend` は SDK 開発者のみが設定可能な非公開内部 API であり、外部ユーザーからは到達不能。セキュリティリスクは外部攻撃ではなく SDK 内部コードによる意図しない誤用である。
- 緊急の実害はなく、`onSend` を設定していない通常利用には影響しない。外部ユーザーへの影響がない内部コードの整理であり時間があれば対応する Low とする。

## 現状

`SignalingChannelInternalHandlers` に送信メッセージを差し替えるクロージャ `onSend` が定義されている。

```swift
// Sora/SignalingChannel.swift:32
/// シグナリング送信時に呼ばれるクロージャー
var onSend: ((Signaling) -> Signaling)?
```

`send(message:)` では、送信直前にこのクロージャでメッセージを差し替える経路がある。

```swift
// Sora/SignalingChannel.swift:282
Logger.debug(type: .signalingChannel, message: "send message")
let message = internalHandlers.onSend?(message) ?? message
let encoder = JSONEncoder()
```

`onSend` の参照は `Sora/SignalingChannel.swift` 内の上記 2 箇所のみであり、それ以外の参照は存在しない。 `SignalingChannelInternalHandlers` は `class` （非公開）であり、外部から型にアクセスすることはできない。

## 設計方針

- `Sora/SignalingChannel.swift:282` の `let message = internalHandlers.onSend?(message) ?? message` を削除し、受け取った `message` をそのまま利用する。
- `Sora/SignalingChannel.swift:32` の `var onSend: ((Signaling) -> Signaling)?` 宣言（および Swift Doc コメント 1 行）を完全に削除する。 `SignalingChannelInternalHandlers` は非公開クラスであり外部から参照不能なため、 `@available(*, unavailable)` による移行猶予期間は不要である。
- 削除に伴い、 `onSend` を参照している箇所が他に無いことを grep で確認してから実施する。

## テスト方針

モック・スタブは使用しない。既存のシグナリング動作が変わらないことを以下で確認すること:

- 既存の全テストがパスすること（`swift test` または Xcode でテストを実行）。
- 手動テストとして、通常の接続・切断・シグナリング送受信が引き続き正常に動作することを実機または Simulator で確認すること。

## 完了条件

- `SignalingChannel` の送信経路から `onSend` による差し替えが取り除かれていること。
- `SignalingChannelInternalHandlers` から `onSend` 宣言が完全に削除されていること。
- 既存の通常のシグナリング送受信の挙動が変わらないこと。
- `CHANGES.md` の `develop` セクションの `### misc` に、既存の `[CHANGE]` エントリの末尾（`[UPDATE]` エントリより前）に以下を追記すること:
  ```
  - [CHANGE] 送信シグナリングメッセージを書き換え可能な内部ハンドラ `onSend` を削除する
    - @voluntas
  ```

## 解決方法
