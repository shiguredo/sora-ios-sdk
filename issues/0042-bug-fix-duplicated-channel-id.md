# 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-duplicated-channel-id
- Polished: 2026-06-06

## 目的

アプリで切断と接続を短い間隔で繰り返すと、Sora サーバーから `DUPLICATED-CHANNEL-ID` エラーが返ることがある。SDK 側で `state == .disconnecting` 中の `connect()` 呼び出しをガードしていないため、切断処理が完了する前に次の接続シグナリングが送られ、多重接続が発生する。この競合状態を解消する。

## 優先度根拠

`DUPLICATED-CHANNEL-ID` が発生すると接続が失敗し、ユーザーが手動で再操作しなければならない。ただし再現性が低く（非確定的）、致命的なデータ損失はないため Medium とする。

## 現状

### コードの実態

`MediaChannel.connect()` は `state.isConnecting`（`ConnectionState.swift:18`）のみで排他制御しており、`isConnecting` は `state == .connecting` のみ `true` を返す（`.disconnecting` は含まない）。

`MediaChannel.internalDisconnect()` の処理は以下の順序で実行される：

1. `state = .disconnecting`
2. `connectionTimer.stop()`
3. `peerChannel.disconnect(...)` — WebSocket / シグナリングの非同期クリーンアップを開始
4. `state = .disconnected`（`peerChannel.disconnect` の完了を待たずに同期的にセット）
5. `handlers.onDisconnectLegacy?(error)` — アプリ側の `onDisconnect` ハンドラを呼ぶ（その直前に `internalHandlers.onDisconnectLegacy?(error)` も呼ばれる）

アプリ側が `onDisconnect` ハンドラ内で即座に `connect()` を呼ぶと、`state == .disconnected` であるため `state.isConnecting` は `false` となり、`connect()` が実行される。しかしこの時点では `peerChannel.disconnect()` の WebSocket / シグナリングクリーンアップがサーバー側でまだ完了していない可能性があり、同一チャンネル ID での多重接続が発生して `DUPLICATED-CHANNEL-ID` エラーを引き起こす。

`DUPLICATED-CHANNEL-ID` は Sora サーバーからシグナリングエラーとして返され、`SoraError.webSocketClosed(code:reason:)` の形式で切断ハンドラに伝わる。

### 再現条件

- `onDisconnect` ハンドラ内で即座に `connect()` を呼ぶ
- 再現性は低い（非確定的）。サーバー側のチャンネルクリーンアップのタイミング依存

## 設計方針

修正方針は以下の 2 つが候補であり、どちらか一方、または両方を適用する：

**方針 A**: `MediaChannel.connect()` の state チェックを拡張し、`state == .disconnecting` の間も接続不可として `SoraError.connectionBusy` を返すようにする（`MediaChannel.swift:367` の `state.isConnecting` を `state.isConnecting || state == .disconnecting` に変更するか、`isConnecting` の定義を拡張する）

**方針 B**: `0047-add-disconnect-complete-handler.md` の切断完了ハンドラを先行実装し、アプリ側が「サーバー側のクリーンアップが完了したタイミング」で `connect()` を呼べるようにする（根本解決）

方針 A は SDK 側の防衛的修正として単独で適用可能。方針 B は 0047 の実装を要するが、アプリ側での正確なタイミング制御を可能にする根本解決策。

## 完了条件

- `state == .disconnecting` の間に `connect()` を呼んだ場合に `SoraError.connectionBusy` が返ること（方針 A を採用した場合）
- 切断 → 即時再接続のパターンで `DUPLICATED-CHANNEL-ID` エラーが発生しないこと
- 通常の接続・切断フローに影響がないこと
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する問題を修正する
  - @voluntas
```

## 関連 issue

- `0047-add-disconnect-complete-handler.md`: 切断完了ハンドラの追加（本 issue の方針 B に対応する根本解決策）
