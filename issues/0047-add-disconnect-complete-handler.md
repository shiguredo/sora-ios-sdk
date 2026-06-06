# 切断処理の完了を示すイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-disconnect-complete-handler
- Polished: 2026-06-06

## 目的

`basicDisconnect()` のすべてのクリーンアップが完了した後に発火する `onDisconnectComplete` ハンドラを `MediaChannelHandlers` に追加する。アプリ側が「サーバー側のチャンネルが解放されるタイミングに最も近い時点」を検知できるようにし、安全な再接続を可能にする。

## 優先度根拠

切断完了ハンドラの欠如は `0042`（DUPLICATED-CHANNEL-ID）の根本原因の一つ。本 issue は 0042 の設計方針 B（根本解決策）として参照されている。ただし 0042 の防衛的修正（方針 A: `.disconnecting` 中の `connect()` ガード）が先行実装されれば緊急度は下がる。そのため Medium とする。

## 現状

SDP ハンドシェイク等の非同期処理が進行中（`lock.count > 0`）に切断が発生すると:

1. `MediaChannel.internalDisconnect()`（`MediaChannel.swift:517`）が `state = .disconnecting` をセットして `peerChannel.disconnect()` を呼ぶ
2. `peerChannel.disconnect()` は `lock.waitDisconnect()` を実行するが、`count > 0` のため `shouldDisconnect = true` を立てるだけで即座に返る（`basicDisconnect()` は未実行）
3. `internalDisconnect()` 続行: `state = .disconnected`、`handlers.onDisconnect` がアプリに発火
4. **アプリが `onDisconnect` を受けて即座に `connect()` を呼ぶ**
5. ところが `basicDisconnect()` はまだ実行されておらず、WebSocket も未クローズ（`signalingChannel.disconnect()` 未実行）
6. サーバーは旧接続が生きていると認識しているため `DUPLICATED-CHANNEL-ID` が発生

`count == 0` の場合は `peerChannel.disconnect()` 内で `basicDisconnect()` が同期実行されてから返るため上記の問題は発生しないが、両経路で一貫したタイミング制御を提供するために `onDisconnectComplete` を追加する。

### `basicDisconnect()` の関連する処理順序

`PeerChannel.basicDisconnect()`（`PeerChannel.swift:1160`）の終盤は以下の順に実行される:

- `signalingChannel.disconnect()`（`PeerChannel.swift:1204`）: WebSocket クローズ（`webSocketTask.cancel()` + `urlSession.invalidateAndCancel()` を呼ぶ。これが SDK がコントロールできる切断処理の最終ステップ）
- `internalHandlers.onDisconnect?(error, reason)`（`PeerChannel.swift:1207`）
- `onConnect?(error)` 呼び出し（`PeerChannel.swift:1209-1213`。接続試行中に切断が発生した場合のみ）

`basicDisconnect()` は `Lock.waitDisconnect()` と `Lock.unlock()` の構造上、一度の接続につき高々一度しか呼ばれない（`MediaChannel` は再利用不可: `MediaChannel.swift:64`）。

## 設計方針

**案 A（採用）**: `MediaChannelHandlers` に `onDisconnectComplete: (() -> Void)?` を追加する。

案 A を採用する理由:
- ユーザー起因・サーバー起因・タイムアウト起因いずれの切断でも発火する（`internalDisconnect()` は全経路から呼ばれるため）
- 案 B（`disconnect(completionHandler:)` 引数）はユーザー起因の切断にしか対応できず、サーバー起因の切断後の再接続を安全にできない。また `disconnect()` のシグネチャを変える破壊的変更が必要になる

**`onDisconnect` との役割の差異**:
- `onDisconnect`: `MediaChannel.internalDisconnect()` の末尾（`MediaChannel.swift:572`）で発火。`count > 0` のケースでは `basicDisconnect()` 完了前に発火する場合がある。切断の通知・UI 更新・ログ記録を行う用途
- `onDisconnectComplete`: `basicDisconnect()` の `signalingChannel.disconnect()` 完了後（`internalHandlers.onDisconnect?` 発火後）に発火。WebSocket を閉じた後であり、再接続のタイミング制御に使用する用途。引数なし（`() -> Void`）とする。切断理由・エラー情報が必要な場合は先に発火する `onDisconnect` のクロージャキャプチャで取得できるため

**`internalHandlers` と `handlers` の扱い**:
`internalDisconnect()` では `handlers.onDisconnect?` のみを呼ぶ（`MediaChannel.swift:572`）。`onDisconnectComplete` も同様に `handlers.onDisconnectComplete?()` のみを呼ぶ。`internalHandlers.onDisconnectComplete` は追加しない。

**`onDisconnect` → `onDisconnectComplete` の発火順序の保証**:

`count == 0` と `count > 0` で実行経路が異なるため、フラグ方式で順序を保証する。

`basicDisconnectCompleted` フラグを `MediaChannel` のインスタンスプロパティとして追加する（`var basicDisconnectCompleted = false`）。`MediaChannel` は再利用不可のため、このフラグを再初期化する必要はない。

`MediaChannel.basicConnect()` 内で `peerChannel.internalHandlers.onDisconnect` を設定している箇所（`MediaChannel.swift:408`。同 `basicConnect()` 内には `signalingChannel.internalHandlers.onDisconnect` の設定もあるが、本 issue では `peerChannel.internalHandlers` 側）の直後に `onBasicDisconnectComplete` ハンドラを追加する:

```swift
peerChannel.internalHandlers.onBasicDisconnectComplete = { [weak self] in
    guard let weakSelf = self else { return }
    weakSelf.basicDisconnectCompleted = true
    // onDisconnect（handlers.onDisconnect）が既に発火済み（= state が .disconnected）なら
    // onDisconnectComplete も続けて発火する
    if weakSelf.state == .disconnected {
        weakSelf.handlers.onDisconnectComplete?()
    }
}
```

`internalDisconnect()` 内の `handlers.onDisconnect?` 発火後（`MediaChannel.swift:572` の直後）に以下を追加する（既存の 572 行目は変更せず、その直後に挿入する）:

```swift
// basicDisconnect が完了済み（count == 0 の同期パス）なら onDisconnectComplete もここで発火
if basicDisconnectCompleted {
    handlers.onDisconnectComplete?()
}
```

この方式の発火順序:
- **`count == 0`**: `basicDisconnect()` 同期実行 → `onBasicDisconnectComplete` でフラグが立つ（この時点で `state` は `.disconnecting` なので `onDisconnectComplete` は発火しない）→ `peerChannel.disconnect()` 返る → `state = .disconnected` → `handlers.onDisconnect?` 発火 → フラグが立っているので `handlers.onDisconnectComplete?()` も続けて発火
- **`count > 0`**: `peerChannel.disconnect()` 即座に返る → `state = .disconnected` → `handlers.onDisconnect?` 発火（フラグ未設定なので `onDisconnectComplete` はまだ発火しない）→ 後で `basicDisconnect()` 実行 → `onBasicDisconnectComplete` → `state == .disconnected` なので `handlers.onDisconnectComplete?()` 発火

**スレッドセーフ性**:
`count > 0` のケースでは `basicDisconnect()` は WebRTC スタックの任意スレッドから実行される可能性がある。`internalDisconnect()` が別スレッドから呼ばれる場合も考慮すると、`basicDisconnectCompleted` フラグへの concurrent アクセスが起き得る。`NSLock` または `OSAllocatedUnfairLock` による `basicDisconnectCompleted` フラグ読み書きの保護が必要である。

**`PeerChannelInternalHandlers` への追加**:
`PeerChannelInternalHandlers`（`PeerChannel.swift:32` 周辺）に `onBasicDisconnectComplete: (() -> Void)?` プロパティを追加する。`basicDisconnect()` の `internalHandlers.onDisconnect?(error, reason)`（`PeerChannel.swift:1207`）と `if onConnect != nil {`（`PeerChannel.swift:1209`）の間で `internalHandlers.onBasicDisconnectComplete?()` を呼ぶ。

## 完了条件

- `MediaChannelHandlers` に `onDisconnectComplete: (() -> Void)?` が追加されていること
- `onDisconnectComplete` は `basicDisconnect()` の `signalingChannel.disconnect()` 完了後に発火すること
- `onDisconnect` が `onDisconnectComplete` より先に発火すること
- `onDisconnectComplete` ハンドラ内で `connect()` を呼んだ場合に `DUPLICATED-CHANNEL-ID` が発生しないこと（通常条件下で。サーバー側の旧接続解放には TCP レベルのラグが存在するため完全な保証ではない）
- `basicDisconnectCompleted` フラグへの concurrent アクセスがロックで保護されていること
- `CHANGES.md` の `## develop` セクションにある既存の `[ADD]` エントリの最後に以下を追記すること

```
- [ADD] 切断処理完了後に呼ばれる MediaChannelHandlers.onDisconnectComplete ハンドラを追加する
  - @voluntas
```
