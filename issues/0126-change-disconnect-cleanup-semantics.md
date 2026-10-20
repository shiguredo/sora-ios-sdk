# 切断クリーンアップが完了しない場合のタイムアウトと強制 teardown を追加する

- Priority: Medium
- Created: 2026-08-28
- Completed:
- Branch: feature/change-disconnect-cleanup-semantics
- Polished: 2026-09-16

## 目的

遅延パスで非同期処理（`createAnswer` 等）の完了が返らない場合、`basicDisconnect()` が実行されず、`onDisconnect` が発火しないまま `state == .disconnecting` とリソース（WebSocket / RTCPeerConnection、および Sora の接続管理への登録）が残留し続ける。SDK 側に切断クリーンアップのタイムアウトを設け、期限内にクリーンアップが完了しない場合は強制 teardown して `onDisconnect` を必ず 1 回発火させ、永久待ちを防ぐ。

なお「`onDisconnect` をクリーンアップ完了後に発火させる」変更自体は、0010（MediaChannel の接続ライフサイクル再実装）により既に現行実装へ反映済みである（現状を参照）。本 issue の残作業は、完了しない場合のタイムアウト、タイムアウト時の通知 API（`SoraError.disconnectCleanupTimeout`）、および doc の明記である。

## 優先度根拠

現行実装では `onDisconnect` 発火時点でクリーンアップは完了しており、旧実装の「早すぎる通知」は解消済みである。残る問題は、非同期コールバックが返らない場合に切断が永遠に完了しないことである。発生するのはコールバック消失・無限待ちという稀な経路だが、発生すると `state == .disconnecting` に固定され、リソースと Sora の接続管理が残留するため、破棄も再利用もできず接続ごとに蓄積する。切断完了の待機に上限がないという SDK の堅牢性の問題であり、確定したバグというより運用上の停止条件であるため Medium とする。

## 現状

### onDisconnect の発火タイミング（対応済み）

`MediaChannel.beginDisconnect()` は `state = .disconnecting` を設定して `peerChannel.disconnect(error:reason:)` を呼ぶ。クリーンアップ完了後、`PeerChannel.finishBasicDisconnect()` の `internalHandlers.onDisconnect` を経由して `MediaChannel.finishDisconnect()` が `state = .disconnected` と `handlers.onDisconnect`（`SoraCloseEvent`）を 1 回だけ実行する。したがって現在は同期パス・遅延パスのどちらでも、`onDisconnect` 発火時点でクリーンアップは完了しており、MediaChannel の class doc「いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます」とも一致している。

### 残っている問題

`PeerChannel.Lock.waitDisconnect()` は `count` により分岐する。

- **同期パス**（`count == 0`、または接続試行中で `count == 1` かつ `onConnect != nil`）: `basicDisconnect()` を同期的に実行してから返る。
- **遅延パス**（`count >= 2`、または `count == 1` かつ `onConnect == nil`）: `shouldDisconnect` に保存するだけで即 return する。`basicDisconnect()` は非同期完了時の `Lock.unlock()` から実行される。

遅延パスで非同期コールバック（`createAnswer` 等）が返らない場合、`Lock.unlock()` が呼ばれず `basicDisconnect()` は実行されない。このとき `onDisconnect` は発火せず、`state` は `.disconnecting` のまま、PeerConnection・WebSocket・Sora の `_mediaChannels` 登録などが残留し続ける。クリーンアップ完了を待つ上限が存在しないことが本 issue の対象である。

## 設計方針

### 切断クリーンアップタイムアウト

遅延パスで `shouldDisconnect` を保存した時点でタイマーを開始する。`Configuration.disconnectCleanupTimeout` 秒以内に `Lock.unlock()` 経由で `basicDisconnect()` が実行されない場合、SDK が強制 teardown する。タイマーは `basicDisconnect()` の実行時（正常・強制を問わず）に cancel する。

```swift
// Configuration.swift
/// 遅延パスで切断クリーンアップ完了を待つ最大秒数。0 はタイムアウトなし（非推奨）。
public var disconnectCleanupTimeout: Int = 30
```

デフォルト 30 秒（`connectionTimeout` と同値）。0 はデバッグ用途のみと doc に明記する。

タイマーの開始・cancel・強制 teardown は `PeerChannel.Lock` の状態（`count` / `isDisconnecting` / `shouldDisconnect`）と直列化する必要があるため、`Lock` の管理下に置く（`lock()` / `unlock()` / `waitDisconnect()` と同じ排他領域から操作する）。タイマーは世代を持ち、cancel 済みの旧タイマーが遅れて発火しても何もしないようにする（`disconnectTimer` / `ConnectionTimer` と同じ方式）。

### タイムアウト時の処理

1. `Lock` 内で `isDisconnecting = true`、`count = 0` にリセットし、保存済みの切断パラメータ（error / reason）を引き取る
2. `basicDisconnect(error:reason:)` を強制実行する（進行中の非同期の完了は待たない。以後の `unlock()` は `isDisconnecting` ガードで無視される）
3. `basicDisconnect()` の既存経路（`sendDisconnectMessageIfNeeded` → `signalingChannel.disconnect()` → `finishBasicDisconnect()` → `MediaChannel.finishDisconnect()`）がそのまま `state = .disconnected` と `handlers.onDisconnect` の 1 回発火を実行する。強制 teardown 専用の `state` 遷移や handler 呼び出しは追加しない（二重発火を防ぐため）
4. `sendDisconnectMessageIfNeeded(reason: .disconnectCleanupFailed, error: <元の error>)` で NO-ERROR を送信する（best-effort）。`sendDisconnectMessageIfNeeded()` の `state == .failed` による早期 return は `.peerConnectionStateDisconnected` のみ除外しているため、`.disconnectCleanupFailed` も同様に除外する（`.failed` でも WebSocket は生存している可能性があり、サーバー側セッションの解放が目的のため）
5. タイムアウト前に確定していた切断理由から `SoraCloseEvent` を組み立て、`SoraError.disconnectCleanupTimeout(original:)` として error に載せる。`MediaChannel.makeDisconnectEvent()` は `SoraError` を既定で `.error` へ変換するため、`onDisconnect` には `.error(SoraError.disconnectCleanupTimeout(original:))` として通知される

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

本 issue は 0047（`onDisconnectComplete` 追加）の後継として、2 段 API ではなく `onDisconnect` 自体を終端イベントとして正す方針を引き継ぐ。`onDisconnectComplete` は追加しない。切断開始時点で UI を更新したい利用者向けの別イベントも本 issue のスコープ外とする。

### 0129 との関係

0129（`PeerChannel.Lock` の統合）は `Lock` の統合先（`connectionLifecycleLock` または接続状態 reducer）を決定する。本 issue のタイマーと強制 teardown は `Lock` の状態と直列化が必要であるため、0129 が先行して完了する場合は、統合先の状態機械へ同様のタイマーと強制 teardown を設計する。

## 完了条件

- 遅延パスで `shouldDisconnect` を保存した後、`disconnectCleanupTimeout` 秒を超えても `basicDisconnect()` が実行されない場合に強制 teardown され、`onDisconnect` が `.error(SoraError.disconnectCleanupTimeout(original:))` で 1 回発火すること
- タイムアウト通知の `original` に、タイムアウト前に確定していた切断理由（`SoraCloseEvent`）が保持されていること
- タイムアウト後も同一 `channelId` で `connect()` できること
- 強制 teardown 後も `state == .disconnected` になり、Sora の接続管理からの除去等、MediaChannel の後始末が完了すること
- 通常の切断（非同期が返る場合）ではタイマーが cancel され発火しないこと。同期パス・遅延パスとも `onDisconnect` の発火タイミングに実質的な後退がないこと（既存 E2E が通ること）
- タイムアウト待ち中は `state == .disconnecting`、完了後は `.disconnected` であること
- `onDisconnect` / `SoraCloseEvent` / `Configuration.disconnectCleanupTimeout` の doc にセマンティクス（`.ok` = プロトコル理由、SDK 運用問題 = `.error`）が明記されていること
- 単体テスト（タイムアウト強制 teardown、タイマー cancel、同期 / 遅延パスの発火順序）が追加されていること
- `CHANGES.md` の `develop` セクションに `[ADD]` エントリが追記されていること

## 解決方法

### 実装

1. `Configuration` に `disconnectCleanupTimeout` を追加する
2. `SoraError` に `disconnectCleanupTimeout(original: SoraCloseEvent?)` を追加する（`errorDescription` も追加する）
3. `DisconnectReason` に `disconnectCleanupFailed` を追加する
4. `PeerChannel.Lock` にタイマーを追加し、`waitDisconnect()` の遅延パスで開始、`basicDisconnect()` 実行時に cancel する（世代管理で旧タイマーを無効化する）
5. タイムアウト時は `Lock` 内で `isDisconnecting = true`、`count = 0` にリセットし、`basicDisconnect(error:reason:)` を強制実行する
6. `sendDisconnectMessageIfNeeded()` の `state == .failed` 早期 return へ `.disconnectCleanupFailed` も除外として追加する
7. タイムアウト通知用に、保存済みの error / reason から `SoraCloseEvent` を組み立てる変換を `MediaChannel.makeDisconnectEvent()` と共通化し、`SoraError.disconnectCleanupTimeout(original:)` を error として渡す
8. `MediaChannel` class doc と `onDisconnect` / `SoraCloseEvent` / `Configuration` の doc を更新する

```
- [ADD] 切断クリーンアップのタイムアウト (Configuration.disconnectCleanupTimeout) と SoraError.disconnectCleanupTimeout を追加する
  - @voluntas
```

`onDisconnect` をクリーンアップ完了後に発火させる変更は 0010 で反映済みのため、`[CHANGE]` エントリは本 issue では追加しない。

### テスト

- **単体テスト**: 遅延パスでタイマーが発火し強制 teardown されること、`disconnectCleanupTimeout(original:)` が 1 回通知されること、通常完了時にタイマーが cancel されること、同期 / 遅延パスの発火順序を検証する
- **E2E**: 既存切断 E2E（`testSendonlyReconnect` 等）が回帰しないこと。E2E コメントの「DUPLICATED-CHANNEL-ID 回避の 1 秒待機」は本 issue の目的とは無関係であるため、本 issue では削除・変更しない（別途整理可）
