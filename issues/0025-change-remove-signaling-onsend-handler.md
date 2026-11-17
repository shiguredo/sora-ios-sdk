# 送信シグナリングメッセージを書き換え可能な onSend ハンドラを削除する

- Priority: Low
- Created: 2026-06-03
- Completed: 2026-11-17
- Model: Opus 4.8
- Branch: feature/refactor-remove-signaling-onsend-handler
- Polished: 2026-09-02
- Refreshed: 2026-11-16

## 目的

送信するシグナリングメッセージを任意に書き換え可能な内部ハンドラ `SignalingChannelInternalHandlers.onSend` を削除する。`onSend` は非公開クラスの非公開プロパティであり外部ユーザーからは到達不能だが、SDK 内部コードが誤って `onSend` を設定することで送信メッセージが予期せず書き換えられるリスクを排除するため、送信メッセージを差し替える内部経路自体を取り除く。

## 優先度根拠

- `onSend` は SDK 開発者のみが設定可能な非公開内部 API であり、外部ユーザーからは到達不能。セキュリティリスクは外部攻撃ではなく SDK 内部コードによる意図しない誤用である。
- 緊急の実害はなく、`onSend` を設定していない通常利用には影響しない。外部ユーザーへの影響がない内部コードの整理であり時間があれば対応する Low とする。

## 現状

`SignalingChannelInternalHandlers`（非公開 class）に、送信メッセージを差し替えるクロージャ `onSend` が定義されている。

```swift
/// シグナリング送信時に呼ばれるクロージャー
var onSend: ((Signaling) -> Signaling)?
```

`Sora/SignalingChannel.swift` の `send(message:)` では、送信直前にこのクロージャでメッセージを差し替える経路がある。

```swift
Logger.debug(type: .signalingChannel, message: "send message")
let message = self.internalHandlers.onSend?(message) ?? message
let encoder = JSONEncoder()
```

`onSend` のコード上の参照は `Sora/SignalingChannel.swift` 内の上記 2 箇所のみであり、`onSend` を設定している箇所は存在しない。これとは別に、`SoraTests/PeerChannelRedirectInvalidationTests.swift` のコメントに `onSend` への言及が 1 箇所ある（コードからの参照ではない）。 `SignalingChannelInternalHandlers` は `class` （非公開）であり、外部から型にアクセスすることはできない。

## 設計方針

- `Sora/SignalingChannel.swift` の `send(message:)` 内の `let message = self.internalHandlers.onSend?(message) ?? message` を削除し、受け取った `message` をそのまま利用する。
- `Sora/SignalingChannel.swift` の `SignalingChannelInternalHandlers.onSend` 宣言（および Swift Doc コメント 1 行）を完全に削除する。 `SignalingChannelInternalHandlers` は非公開クラスであり外部から参照不能なため、 `@available(*, unavailable)` による移行猶予期間は不要である。
- 削除に伴い、 `onSend` を参照している箇所が他に無いことを grep で確認してから実施する。 `SoraTests/PeerChannelRedirectInvalidationTests.swift` のコメントの言及も、削除後の状態に合わせて更新する。

## テスト方針

モック・スタブは使用しない。既存のシグナリング動作が変わらないことを以下で確認すること:

- 既存の全テストがパスすること（Xcode の `Sora-Package` scheme でテストを実行する。CI は `.github/workflows/e2e-test.yml` で `xcodebuild build-for-testing -scheme Sora-Package` の後に `xcodebuild test-without-building` を実行している）。
- 手動テストとして、通常の接続・切断・シグナリング送受信が引き続き正常に動作することを実機または Simulator で確認すること。

## 完了条件

- `SignalingChannel` の送信経路から `onSend` による差し替えが取り除かれていること。
- `SignalingChannelInternalHandlers` から `onSend` 宣言が完全に削除されていること。
- 既存の通常のシグナリング送受信の挙動が変わらないこと。
- `CHANGES.md` の `## develop` セクションに `### misc` サブセクション（無ければ新設）を設け、種別順（`[CHANGE]` → `[ADD]` → `[UPDATE]` → `[FIX]`）に従って以下を追記すること:
  ```
  - [UPDATE] 送信シグナリングメッセージを書き換え可能な内部ハンドラ `onSend` を削除する
    - @voluntas
  ```

## 解決方法

`SignalingChannelInternalHandlers` から `onSend` の宣言と Doc コメントを削除し、 `SignalingChannel.send(message:)` の `let message = self.internalHandlers.onSend?(message) ?? message` を削除した。送信経路は受け取った `Signaling` をそのまま JSON エンコードする。

- `onSend` を設定している箇所は 0 件であり、削除前後で送信メッセージの内容・送信順序・ログ・エラー経路は変わらない
- `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `onSend` に言及していたコメントは、 `signalingChannel.send(message:)` は呼ばれるが WebSocket への実送信は行われない、という現状に合わせて更新した
- `git grep` でコード上の `onSend` の参照が 0 件であることを確認した（`CHANGES.md` の履歴にある別シンボル `WebSocketChannelHandlers.onSend` と `issues/` 配下の記述を除く）
- `xcodebuild build-for-testing -scheme Sora-Package` の成果物を `simctl spawn` で実行し、全 587 件（skip 40）が失敗 0 件で成功した。1 回目のみ `StatisticsSnapshotTests` の解放タイミング依存と見られる 2 件が失敗したが、再実行した 2 回はいずれも失敗 0 件だった
- 実機で通常の接続・切断・シグナリング送受信が正常に動作することを確認した
- `CHANGES.md` の `## develop` / `### misc` に `[UPDATE]` エントリを追加した。`SignalingChannelInternalHandlers` は internal であり公開 API の変更はないため、API baseline の更新は不要である
