# SignalingChannel と URLSessionWebSocketChannel の状態所有者を統一する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-signaling-state-owner
- Polished: 2026-09-02

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
- delegate callback 由来の終端状態（`didCloseWith` / `didCompleteWithError` の 2 系統）

クラスコメントは「URLSession delegate と `SignalingChannel` が単一の直列 queue を利用する」ことを安全性の根拠としているが、すべての public / internal entry point をその queue へ強制する構造はない。

`didCloseWith`、`didCompleteWithError`、receive completion、send completion、利用者切断が競合した場合に、状態更新と handler の呼び出し順を 1 箇所で決定できない。

## 設計方針

### signaling owner

- signaling の phase、接続 URL、data_channel_signaling / ignore_disconnect_websocket のフラグ、接続中 / 候補の WebSocket 参照を 1 つの owner が保持する。
  - 状態機械 (phase / URL / フラグ) は `SignalingState` + `SignalingEvent` + 純粋な reducer として `Sora/SignalingState.swift` (新規) に置く。0100 の ConnectionLifecycle と同じ構成とする。
  - 非 Sendable な `URLSessionWebSocketChannel` の参照 (current / candidates) は reducer の state に含めず、owner のメソッド (`addCandidate` / `adopt` / `removeCandidate` / `clear`) で直列 queue 上のみで管理する。
  - redirect generation は `0095` / `0100` の transport epoch と整合する概念とし、新たな独立カウンタを追加しない。旧 callback の拒否は `0095` の制約に従い、session / task identity で判定する。
- `connect`、`send`、`redirect`、`disconnect` を含むすべての entry point を owner の直列 queue へ enqueue する。再入 (delegate callback から操作 API を呼ぶ場合) は queue 上かどうかを検出して直接実行し、デッドロックしない。
- URLSession の delegate queue には owner と同じ直列 queue を設定する。delegate callback と操作が同じ queue を通ることで順序を確定する。
- `PeerChannel` / `MediaChannel` が同期参照する `contactUrl`、`connectedUrl`、`state`、`dataChannelSignaling`、`ignoreDisconnectWebSocket` は、`0100` の同期 getter 方針と同じく lock 保護の snapshot で維持し、owner への同期 wait で実現しない。
- `webSocketChannel` の同期 accessor は Channel 参照を返さず、切断などの操作メソッド (`disconnectCurrentWebSocket()` 等) を owner の queue へ enqueue する形にする。Channel の状態 (`isClosing` 等) を owner queue 外から操作させない。

### delegate adapter

- `URLSessionWebSocketChannel` 自身が `URLSessionDelegate` / `URLSessionWebSocketDelegate` を実装する (小さい adapter への分離は行わない)。delegate callback は owner と同じ直列 queue 上で呼ばれるため、callback 内で identity を snapshot 化して別の ingress へ渡す必要がない。
- callback ごとに独立した Task を生成しない。
- 古い session / task の callback は identity（`URLSession` / `URLSessionWebSocketTask` の同一性）の不一致で拒否する。
- Channel の可変状態 (`urlSession` / `webSocketTask` / `isClosing`) は owner の直列 queue 上でのみ読み書きする。

### 終端と callback

- `didCloseWith` と `didCompleteWithError` が両方届いても、1 接続につき切断通知を厳密に 1 回にする。1 回保証は Channel 自身の `isClosing` (owner queue 上でのみ読み書き) で行う。owner に終端済みの台帳 (墓石) は残さない。
- send / receive completion は、対象 transport が current であることを owner queue 上で再確認する。
- handler は状態更新と take-and-clear の後に呼ぶ。ここでの「critical section 外」は「状態変更ブロックの外」を意味し、handler 呼び出しも owner queue 上で行う。handler 内から操作 API を呼ぶ再入は queue 上の直接実行で安全に処理される。handler 内で別スレッドの完了を同期的に待つことは避ける (owner queue を占有するため)。
- redirect では旧 transport の close と新 transport の開始を identity で分離する。

### 互換性

- `URLSessionWebSocketChannel` は internal であるため、公開対象は `WebSocketChannelHandlers` などの既存 handler API の公開シグネチャであり、これを維持する。
- `URLSessionWebSocketChannel` の `@unchecked Sendable` は残す。可変状態へのアクセスを owner の直列 queue に限定することでデータ競合が発生しないことを、クラスコメントで説明する。
- proxy、CA 証明書、認証 challenge の既存挙動を変更しない。

## スコープ外

- `MediaChannel` / `PeerChannel` 全体の接続状態所有は `0100` と `0010` が分担する。 (MediaChannel は `0010` の `connectionLifecycleLock`、PeerChannel の接続状態フラグは `0100` の reducer)
- redirect 時の旧 DataChannel / RPC 無効化は `0095` で扱う。
- 公開 callback API の `@Sendable` 化は別 issue とする。
- WebRTC C API への移行は `0070` で扱う。
- WebSocket クライアント証明書対応 (`0063`) は本 issue と同一ファイル・同一 symbol を変更するため、着手前に順序を調整する。`0025` / `0033` の handler symbol 変更も同様に調整する。

## テスト方針

モックやスタブは使用しない。

- 実 `URLSessionWebSocketTask` と実 signaling endpoint を使用し、connect、send、receive、disconnect の順序を検証する。
- redirect の実環境検証は `0095` と同様にリダイレクトを発生させるサーバー構成が必要なため自動テスト対象外とし、実機での手動確認とする。
- 利用者切断と `didCloseWith` / `didCompleteWithError` を競合させ、切断通知が 1 回であることを確認する。
- 古い task の receive / send completion が新しい接続の handler を呼ばないことを確認する。
- proxy は自動テスト基盤が存在しないため、認証 challenge の挙動維持は実機での手動確認で担保する。CA 証明書検証は既存の `ConfigurationTests` と実機確認で維持する。
- `SignalingState` / `SignalingEvent` / reducer を実際の transport event 列で入力し、phase / URL / フラグの遷移と stale event の拒否を検証する。
- Thread Sanitizer を補助的に有効化する。
- テストには、delegate queue の直列化だけでは entry point 全体を保護できない理由を日本語コメントで明記する。

## 完了条件

- signaling の mutable state の所有者が 1 つであること (`SignalingStateOwner`)。
- `connect`、`send`、`redirect`、`disconnect`、delegate callback が同じ ordered ingress (owner の直列 queue) を通ること。
- 古い session / task の callback が current state を変更しないこと (identity の不一致で拒否)。
- `didCloseWith` と `didCompleteWithError` が競合しても切断通知が厳密に 1 回であること (Channel の `isClosing` を owner queue で保護)。
- handler が状態変更ブロックの外 (状態更新と take-and-clear の後) で呼ばれていること。
- `PeerChannel` / `MediaChannel` からの同期読み取り (`contactUrl`、`connectedUrl`、`state`、`dataChannelSignaling`、`ignoreDisconnectWebSocket`) が owner への同期 wait なしで成立すること (lock 保護の snapshot)。
- `webSocketChannel` への操作が owner queue 経由で行われ、Channel の状態が owner queue 外から操作されないこと。
- `URLSessionWebSocketChannel` の `@unchecked Sendable` の安全性がクラスコメントで説明されていること (可変状態のアクセスが owner queue に限定される)。
- `SignalingState` / `SignalingEvent` / reducer のテストが存在すること。
- proxy、CA 証明書、redirect の既存挙動が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
