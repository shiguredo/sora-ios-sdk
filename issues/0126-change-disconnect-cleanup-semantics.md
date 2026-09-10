# onDisconnect をクリーンアップ完了後に発火させ、切断クリーンアップタイムアウトを追加する

- Priority: Medium
- Created: 2026-08-28
- Completed:
- Branch: feature/change-disconnect-cleanup-semantics
- Polished:

## 目的

`onDisconnect` を SDK としての切断処理（`PeerChannel.basicDisconnect()`）完了後に 1 回だけ発火させ、doc の「すべてのチャネルが解除される」と実装を一致させる。遅延パスで非同期完了を待てない場合は SDK 側タイムアウト後に強制 teardown し、永久待ちを防ぐ。タイムアウト時は `SoraError.disconnectCleanupTimeout` を `.error` で通知し、元の切断理由を保持する。

## 優先度根拠

遅延パスでは `state == .disconnected` と `onDisconnect` が `basicDisconnect()` より先に来ており、利用者が「切断済み」と判断した時点で WebSocket / PeerConnection が残り得る。0047 で提案されていた `onDisconnectComplete` は 2 段 API となり、発火しない経路やアプリ側タイムアウトを利用者に押し付ける。`onDisconnect` 自体を終端イベントとして正す方が API として自然であるため Medium とする。

## 現状

`MediaChannel.internalDisconnect()` は `peerChannel.disconnect()` 呼び出し直後に `state = .disconnected` と `handlers.onDisconnect` を発火する。

`PeerChannel.Lock.waitDisconnect()` は `count` により分岐する。

- **同期パス**（`count == 0`、または接続試行中で `count == 1` かつ `onConnect != nil`）: `basicDisconnect()` を同期的に実行してから返る。この経路では `onDisconnect` 発火時点でクリーンアップ済みである。
- **遅延パス**（`count >= 2`、または `count == 1` かつ `onConnect == nil`）: `shouldDisconnect` に保存するだけで即 return する。`basicDisconnect()` は非同期完了時の `Lock.unlock()` から実行される。この経路では `onDisconnect` がクリーンアップ前に来る。

`MediaChannel` の class doc には「シグナリング・Peer・WebSocket を含むすべてのチャネルの接続が解除される」とあるが、遅延パスでは doc と矛盾する。

非同期コールバック（`createAnswer` 等）が返らない場合、`basicDisconnect()` は実行されず、現状は `onDisconnect` だけ先に発火してリソースが残留し得る。

## 設計方針

### `onDisconnect` の発火タイミング

`handlers.onDisconnect` は `basicDisconnect()` 完了後に 1 回だけ発火する。`state = .disconnected` も同タイミングに設定する。それまで `state` は `.disconnecting` のままとする。

同期パスでは observable な挙動はほぼ変わらない（既にクリーンアップ後に通知に近い）。遅延パスだけ「早すぎる通知」が修正される。

UI を切断開始時点で更新したい利用者向けの別イベントは本 issue のスコープ外とする。

### 切断クリーンアップタイムアウト

遅延パスで `shouldDisconnect` を保存した時点でタイマーを開始する。`Configuration.disconnectCleanupTimeout` 秒以内に `Lock.unlock()` 経由で `basicDisconnect()` が走らない場合、SDK が強制 teardown する。

```swift
// Configuration.swift
/// 遅延パスで切断クリーンアップ完了を待つ最大秒数。0 はタイムアウトなし（非推奨）。
public var disconnectCleanupTimeout: Int = 30
```

デフォルト 30 秒（`connectionTimeout` と同値）。0 はデバッグ用途のみと doc に明記する。

タイムアウト時の処理:

1. `Lock.isDisconnecting = true`、`count = 0` にリセット
2. `basicDisconnect()` を強制実行（進行中の非同期は abandon）
3. WebSocket が生存していれば `sendDisconnectMessageIfNeeded` で NO-ERROR 送信（best-effort）
4. `state = .disconnected`
5. `handlers.onDisconnect` を 1 回発火

遅れて返る `lock.unlock()` は既存の `isDisconnecting` ガードで無視する。WebRTC コールバックの `generation` ガードは既存どおり維持する。

### 公開 API: `SoraError.disconnectCleanupTimeout`

```swift
/// 切断クリーンアップがタイムアウトし、強制 teardown したことを示します。
/// original には、タイムアウト前に確定していた切断理由を保持します。
case disconnectCleanupTimeout(original: SoraCloseEvent?)
```

`onDisconnect` への通知:

```swift
SoraCloseEvent.error(
  SoraError.disconnectCleanupTimeout(original: originalCloseEvent)
)
```

`.ok(code, reason: "DISCONNECT-CLEANUP-FAILED")` のように `.ok` に載せない。`.ok` の `reason` は Sora / WebSocket プロトコル上の切断理由用であり、`connectionTimeout` 等と同様 SDK 運用問題は `.error` とする。

### 内部: `DisconnectReason.disconnectCleanupFailed`

`sendDisconnectMessageIfNeeded` 等の SDK 内部分岐用。アプリには直接公開しない。

### 0047 との関係

本 issue は 0047（`onDisconnectComplete` 追加）を置き換える。`onDisconnectComplete` は追加しない。

## 完了条件

- 遅延パスで `onDisconnect` が `basicDisconnect()` 完了後に 1 回だけ発火すること
- 同期パスでの `onDisconnect` 発火タイミングに実質的な後退がないこと（既存 E2E が通ること）
- `disconnectCleanupTimeout` 超過時に強制 teardown され、`.error(SoraError.disconnectCleanupTimeout(original:))` が 1 回通知されること
- タイムアウト後も同一 `channelId` で `connect()` できること
- クリーンアップ待ち中は `state == .disconnecting`、`完了後は .disconnected` であること
- `onDisconnect` / `SoraCloseEvent` / `Configuration.disconnectCleanupTimeout` の doc にセマンティクス（`.ok` = プロトコル理由、SDK 運用問題 = `.error`）が明記されていること
- 単体テスト（タイムアウト強制 teardown、同期 / 遅延パスの発火順序）が追加されていること
- `CHANGES.md` の `develop` セクションに `[CHANGE]` と `[ADD]` エントリが追記されていること

## 解決方法

### 実装

1. `Configuration` に `disconnectCleanupTimeout` を追加する
2. `SoraError` に `disconnectCleanupTimeout(original: SoraCloseEvent?)` を追加する
3. `DisconnectReason` に `disconnectCleanupFailed` を追加する
4. `MediaChannel.internalDisconnect()` を変更し、`handlers.onDisconnect` と `state = .disconnected` を `basicDisconnect()` 完了後に移動する（遅延パス用の完了通知経路を `PeerChannel` から `MediaChannel` へ配線する）
5. 遅延パス開始時にクリーンアップタイマーを開始し、通常完了または `disconnect()` 再入で cancel する
6. タイムアウト時は `Lock` を強制解放して `basicDisconnect(error:reason:)` を呼び、`originalCloseEvent` を組み立てて `onDisconnect` に `.error(disconnectCleanupTimeout(original:))` を渡す
7. `MediaChannel` class doc と `onDisconnect` doc を更新する

```
- [CHANGE] onDisconnect を切断クリーンアップ完了後に発火するよう変更する
  - @voluntas
- [ADD] 切断クリーンアップのタイムアウト (Configuration.disconnectCleanupTimeout) と SoraError.disconnectCleanupTimeout を追加する
  - @voluntas
```

### テスト

- **単体テスト**: 遅延パスで `onDisconnect` が `basicDisconnect()` 後に来ること、タイムアウト強制 teardown と `disconnectCleanupTimeout(original:)` 通知、タイマー cancel を検証する
- **E2E**: 既存切断 E2E（`testSendonlyReconnect` 等）が回帰しないこと。E2E コメントの「DUPLICATED-CHANNEL-ID 回避の 1 秒待機」は本 issue の目的とは無関係であるため、本 issue では削除・変更しない（別途整理可）
