# SignalingChannel と URLSessionWebSocketChannel の状態所有者を統一する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-signaling-state-owner
- Polished:

## 目的

`SignalingChannel` と `URLSessionWebSocketChannel` の mutable state を signaling 専用の 1 つの actor または serial executor へ集約し、接続、送信、redirect、切断、URLSession delegate callback の順序を保証する。

`URLSessionWebSocketChannel: @unchecked Sendable` が依存している未成立の前提を除去し、Swift 6 の isolation を実行経路で説明できる構造にする。

## 現状

`Sora/SignalingChannel.swift` は URLSession delegate callback 用の `OperationQueue` を `maxConcurrentOperationCount = 1` で作成している。

ただし、この queue が直列化するのは URLSession delegate callback だけである。次の操作は同じ queue に限定されていない。

- `connect`
- signaling message の `send`
- `redirect`
- 利用者または `PeerChannel` からの `disconnect`
- WebSocket 切断遅延処理

`Sora/URLSessionWebSocketChannel.swift` は `@unchecked Sendable` で、次の mutable state を保持する。

- internal handler と利用者 handler
- `isClosing`
- `urlSession`
- `webSocketTask`
- delegate callback の終端状態

クラスコメントは「URLSession delegate と `SignalingChannel` が単一の直列 queue を利用する」ことを安全性の根拠としているが、すべての public / internal entry point をその queue へ強制する構造はない。

`didCloseWith`、`didCompleteWithError`、receive completion、send completion、利用者切断が競合した場合に、状態更新と handler の呼び出し順を 1 箇所で決定できない。

## 設計方針

### signaling owner

- signaling の phase、接続 URL、redirect generation、session / task identity、切断理由、完了済み通知を 1 つの owner が保持する。
- `connect`、`send`、`redirect`、`disconnect` を含むすべての entry point を owner へ enqueue する。
- URLSession delegate queue は transport callback の受信に限定し、状態の正本にしない。

### delegate adapter

- `URLSessionDelegate` / `URLSessionWebSocketDelegate` は小さい `NSObject` adapter へ分離する。
- adapter は callback 内で session / task identity、generation、必要な値だけを snapshot 化し、ordered ingress へ渡す。
- callback ごとに独立した Task を生成しない。
- 古い session / task の callback は identity と generation の不一致で拒否する。

### 終端と callback

- `didCloseWith` と `didCompleteWithError` が両方届いても、1 接続につき切断通知を厳密に 1 回にする。
- send / receive completion は、対象 transport が current であることを owner 上で再確認する。
- handler は状態更新と take-and-clear の後、owner の critical section 外で呼ぶ。
- redirect では旧 transport の close と新 transport の開始を generation で分離する。

### 互換性

- `WebSocketChannel` と既存 handler の公開シグネチャは維持する。
- `@unchecked Sendable` を残す必要がある場合は、delegate adapter などの小さい internal 型だけに限定し、所有 state を持たせない。
- proxy、CA 証明書、認証 challenge の既存挙動を変更しない。

## スコープ外

- `MediaChannel` / `PeerChannel` 全体の接続状態所有は `0100` で扱う。
- redirect 時の旧 DataChannel / RPC 無効化は `0095` で扱う。
- 公開 callback API の `@Sendable` 化は別 issue とする。
- WebRTC C API への移行は `0070` で扱う。

## テスト方針

モックやスタブは使用しない。

- 実 `URLSessionWebSocketTask` と実 signaling endpoint を使用し、connect、send、receive、redirect、disconnect の順序を検証する。
- 利用者切断と `didCloseWith` / `didCompleteWithError` を競合させ、切断通知が 1 回であることを確認する。
- 古い task の receive / send completion が新しい generation の handler を呼ばないことを確認する。
- 実際の proxy と CA 証明書検証経路を利用し、認証 challenge の挙動が変わらないことを確認する。
- production の signaling state reducer を導入する場合は、実際の transport event を入力して順序を検証する。
- Thread Sanitizer を補助的に有効化する。
- テストには、delegate queue の直列化だけでは entry point 全体を保護できない理由を日本語コメントで明記する。

## 完了条件

- signaling の mutable state の所有者が 1 つであること。
- `connect`、`send`、`redirect`、`disconnect`、delegate callback が同じ ordered ingress を通ること。
- 古い session / task の callback が current state を変更しないこと。
- `didCloseWith` と `didCompleteWithError` が競合しても切断通知が厳密に 1 回であること。
- handler を owner の critical section 外で呼んでいること。
- `URLSessionWebSocketChannel` 全体の `@unchecked Sendable` が不要になるか、安全性を説明できる小さい adapter に限定されていること。
- proxy、CA 証明書、redirect の既存挙動が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
