# 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-duplicated-channel-id
- Polished: 2026-07-27

## 目的

アプリで切断と接続を短い間隔で繰り返すと、Sora サーバーから `DUPLICATED-CHANNEL-ID` エラーが返ることがある。SDK 側で `state == .disconnecting` 中の `connect()` 呼び出しをガードしていないため、切断処理が完了する前に次の接続シグナリングが送られ、多重接続が発生する。この競合状態を解消する。

## 優先度根拠

`DUPLICATED-CHANNEL-ID` が発生すると接続が失敗し、ユーザーが手動で再操作しなければならない。ただし再現性が低く（非確定的）、致命的なデータ損失はないため Medium とする。

## 現状

### コードの実態

`MediaChannel.connect()` は `state.isConnecting`（`ConnectionState.swift:18`）のみで排他制御しており、`isConnecting` は `state == .connecting` のみ `true` を返す（`.disconnecting` は含まない）。

`MediaChannel.internalDisconnect()` の処理は `PeerChannel.Lock.count` の値によって異なる:

- **count == 0 の場合**: `peerChannel.disconnect()` 内で `Lock.waitDisconnect()`（`PeerChannel.swift:108-122`）が `basicDisconnect()` を同期的に実行してから返るため、WebSocket / シグナリングのクリーンアップが完了した後に `state = .disconnected` がセットされる。この場合、競合は発生しない
- **count > 0 の場合**: `Lock.waitDisconnect()` は `shouldDisconnect` にパラメータを保存するだけで即座には `basicDisconnect()` を呼ばない。`internalDisconnect()` は `peerChannel.disconnect()` の完了を待たずに `state = .disconnected` を同期的にセットし、`handlers.onDisconnectLegacy?(error)` を呼ぶ。この時点では WebSocket / シグナリングのクリーンアップがサーバー側でまだ完了していない

`count > 0` の場合、アプリ側が `onDisconnect` ハンドラ内で即座に `connect()` を呼ぶと、`state == .disconnected` であるため接続が実行される。しかし `Sora.connect()` は新しい `MediaChannel` インスタンスを生成する（`Sora.swift:180`）ため、旧インスタンスの state ガードは再接続経路に介入できない。サーバー側のチャンネルクリーンアップが完了していない状態で同一チャンネル ID の接続シグナリングが送られ、`DUPLICATED-CHANNEL-ID` エラーを引き起こす。

`DUPLICATED-CHANNEL-ID` は Sora サーバーからシグナリングエラーとして返され、`SoraError.webSocketClosed(code:reason:)` の形式で切断ハンドラに伝わる。

### 再現条件

- `onDisconnect` ハンドラ内で即座に `connect()` を呼ぶ
- 再現性は低い（非確定的）。サーバー側のチャンネルクリーンアップのタイミング依存

## 設計方針

修正方針は以下の 2 つが候補であり、優先度順に示す:

**方針 A（推奨）**: `0047-add-disconnect-complete-handler.md` の切断完了ハンドラを先行実装し、アプリ側が「サーバー側のクリーンアップが完了したタイミング」で `connect()` を呼べるようにする（根本解決）

**方針 B（防衛的修正）**: `Sora.connect()` レベルで、同一 channelId を持つ既存の `MediaChannel` の切断が未完了の場合に `SoraError.connectionBusy` を返すガードを追加する。`MediaChannel.connect()` の state チェックは新インスタンスに対して機能しないため（`Sora.connect()` が毎回新しい `MediaChannel` を生成する）、ガードは `Sora` レベルに置く必要がある。ガード条件の観測には `PeerChannel.Lock.count`（`private`）や `MediaChannel.state`（`count > 0` でも `.disconnected` が同期的にセットされる）は使えないため、`basicDisconnect()` 完了を追跡する新しいフラグ（例: `MediaChannel` または `Sora` 上の `disconnectCompleted` フラグ）の導入が必要

方針 A はアプリ側での正確なタイミング制御を可能にする根本解決策。方針 B は SDK 側の防衛的修正だが、サーバー側のクリーンアップ完了を保証するものではないため、方針 A の代替にはならない。両方を適用することも可能。

## 完了条件

- 切断 → 即時再接続のパターンで `DUPLICATED-CHANNEL-ID` エラーが発生しないこと
- 方針 B を採用した場合: `Sora.connect()` 呼び出し時に既存チャンネルの切断が未完了であれば `SoraError.connectionBusy` が返ること
- 通常の接続・切断フローに影響がないこと
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する問題を修正する
  - @voluntas
```

## 関連 issue

- `0047-add-disconnect-complete-handler.md`: 切断完了ハンドラの追加（本 issue の方針 A に対応する根本解決策）
