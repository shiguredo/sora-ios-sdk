# 切断クリーンアップが完了しない場合のタイムアウトと強制 teardown を追加する

- Priority: Medium
- Created: 2026-08-28
- Completed:
- Branch: feature/change-disconnect-cleanup-semantics
- Polished: 2026-09-16
- Refreshed: 2026-11-24

## 目的

遅延パスで非同期処理（`createAnswer` 等）の完了が返らない場合、`basicDisconnect()` が実行されず、`onDisconnect` が発火しないまま `state == .disconnecting` とリソース（WebSocket / RTCPeerConnection、および Sora の接続管理への登録）が残留し続ける。SDK 側に切断クリーンアップのタイムアウトを設け、期限内にクリーンアップが完了しない場合は強制 teardown して `onDisconnect` を必ず 1 回発火させ、永久待ちを防ぐ。

なお「`onDisconnect` をクリーンアップ完了後に発火させる」変更自体は、0010（MediaChannel の接続ライフサイクル再実装）により既に現行実装へ反映済みである（現状を参照）。本 issue の残作業は、完了しない場合のタイムアウト、タイムアウト時の通知 API（`SoraError.disconnectCleanupTimeout`）、および doc の明記である。

## 優先度根拠

現行実装では `onDisconnect` 発火時点でクリーンアップは完了しており、旧実装の「早すぎる通知」は解消済みである。残る問題は、非同期コールバックが返らない場合に切断が永遠に完了しないことである。発生するのはコールバック消失・無限待ちという稀な経路だが、発生すると `state == .disconnecting` に固定され、リソースと Sora の接続管理が残留するため、破棄も再利用もできず接続ごとに蓄積する。切断完了の待機に上限がないという SDK の堅牢性の問題であり、確定したバグというより運用上の停止条件であるため Medium とする。

## 現状

### onDisconnect の発火タイミング（対応済み）

`MediaChannel.beginDisconnect()` は `state = .disconnecting` を設定して `peerChannel.disconnect(error:reason:)` を呼ぶ。クリーンアップ完了後、`PeerChannel.finishBasicDisconnect()` の `internalHandlers.onDisconnect` を経由して `MediaChannel.finishDisconnect()` が `state = .disconnected` と `handlers.onDisconnect`（`SoraCloseEvent`）を 1 回だけ実行する。したがって現在は同期パス・遅延パスのどちらでも、`onDisconnect` 発火時点でクリーンアップは完了しており、MediaChannel の class doc「いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます」とも一致している。

### 残っている問題

`ConnectionStateOwner.requestDisconnect(error:reason:shouldCancelDisconnectTimerBasedDisconnect:isConnectHandlerHeld:)` は、切断要求を即時実行するか遅延保存するかを分岐する。

- **同期パス**（`asyncOperationCount == 0`、または接続試行中で `asyncOperationCount == 1` かつ接続完了 callback を保持している場合）: `disconnectAccepted`（または `disconnectAcceptedWhileConnecting`）を適用し、`PeerChannel.disconnect(error:reason:)` が戻り値の `PendingDisconnect` を受けて `basicDisconnect()` を実行する。`asyncOperationCount == 0` でも、猶予タイマー由来の要求が接続の回復により取り消される場合は実行しない。
- **遅延パス**（`isStartingConnection` の区間中、または上記のいずれにも該当しない場合）: private な `pendingDisconnect` に保存するだけで即 return する。保存された要求は、非同期処理の完了時（`ConnectionStateOwner.endAsyncOperation()`）または signaling 開始の確定時（`prepareSignalingStart` / `finishSignalingStart`）に取り出され、猶予タイマー由来で接続が回復していれば破棄され、そうでなければ `basicDisconnect()` が実行される。

遅延パスで非同期コールバック（`createAnswer` 等）が返らない場合、`endAsyncOperation()` が呼ばれず `pendingDisconnect` は保存されたままになる。このとき `onDisconnect` は発火せず、`state` は `.disconnecting` のまま、PeerConnection・WebSocket・Sora の `_mediaChannels` 登録などが残留し続ける。クリーンアップ完了を待つ上限が存在しないことが本 issue の対象である。

## 設計方針

### 切断クリーンアップタイムアウト

遅延パスで `pendingDisconnect` を保存した時点でタイマーを開始する。`Configuration.disconnectCleanupTimeout` 秒以内に、保存した要求が `endAsyncOperation()` / `prepareSignalingStart()` / `finishSignalingStart()` のいずれかから `basicDisconnect()` に渡らない場合、SDK が強制 teardown する。タイマーは `basicDisconnect()` の実行時（正常・強制を問わず）、または保存した要求が接続の回復により破棄されたときに cancel する。

```swift
// Configuration.swift
/// 遅延パスで切断クリーンアップ完了を待つ最大秒数。0 はタイムアウトなし（非推奨）。
public var disconnectCleanupTimeout: Int = 30
```

デフォルト 30 秒（`connectionTimeout` と同値）。0 はデバッグ用途のみと doc に明記する。

タイマーの開始・cancel・強制 teardown は `ConnectionStateOwner` の状態（`asyncOperationCount` / `isDisconnecting` / `isStartingConnection` / `pendingDisconnect`）と直列化する必要があるため、`ConnectionStateOwner` の直列 queue と `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionStateReducer` で扱う（`requestDisconnect` / `endAsyncOperation` / `resolvePendingDisconnect` と同じ排他領域から操作する）。タイマーは世代を持ち、cancel 済みの旧タイマーが遅れて発火しても何もしないようにする（`disconnectTimerGeneration` / `ConnectionTimer` と同じ方式）。

### タイムアウト時の処理

1. `ConnectionStateOwner` の直列 queue 上で、保存済みの `pendingDisconnect` がある場合だけタイムアウト用の `ConnectionEvent` を適用し、`isDisconnecting = true`、`asyncOperationCount = 0` にリセットする（無い場合は何もしない）
2. 取り出した `pendingDisconnect`（error / reason）を `PendingDisconnect` として返し、`PeerChannel` が queue の外で `basicDisconnect(error:reason:)` を強制実行する（進行中の非同期の完了は待たない。以後の `endAsyncOperation()` は `isDisconnecting` ガードで無視される）
3. `basicDisconnect()` の既存経路（`sendDisconnectMessageIfNeeded` → `signalingChannel.disconnect()` → `finishBasicDisconnect()` → `MediaChannel.finishDisconnect()`）がそのまま `state = .disconnected` と `handlers.onDisconnect` の 1 回発火を実行する。強制 teardown 専用の `state` 遷移や handler 呼び出しは追加しない（二重発火を防ぐため）
4. `basicDisconnect(error:reason:)` の内部で呼ばれる `sendDisconnectMessageIfNeeded(reason: .disconnectCleanupFailed, error:)` で NO-ERROR を送信する（best-effort。error には手順 5 のタイムアウトの error が渡るが、この分岐では error を使わない）。`sendDisconnectMessageIfNeeded()` の `state == .failed` による早期 return は `.peerConnectionStateDisconnected` のみ除外しているため、`.disconnectCleanupFailed` も同様に除外する（`.failed` でも WebSocket は生存している可能性があり、サーバー側セッションの解放が目的のため）。あわせて、NO-ERROR を送信する `switch reason` の分岐は現状 `.user` / `.noError`（と `.peerConnectionStateDisconnected`）だけであるため、`.disconnectCleanupFailed` も同じ送信分岐へ追加する
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

0129（`PeerChannel.Lock` の統合）は 2026-09-29 に完了しており、`PeerChannel.Lock` は削除済みである。`Lock` が管理していた状態（`count` / `isDisconnecting` / `isStartingConnection` / `shouldDisconnect`）は、`Sora/ConnectionLifecycle.swift` の `ConnectionStateOwner` / `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionStateReducer` が担う。本 issue のタイマーと強制 teardown は、この状態機械へ `ConnectionLifecycleState` の追加状態と `ConnectionEvent` の追加ケースとして組み込む。

## 完了条件

- 遅延パスで `pendingDisconnect` を保存した後、`disconnectCleanupTimeout` 秒を超えても `basicDisconnect()` が実行されない場合に強制 teardown され、`onDisconnect` が `.error(SoraError.disconnectCleanupTimeout(original:))` で 1 回発火すること
- タイムアウト通知の `original` に、タイムアウト前に確定していた切断理由（`SoraCloseEvent`）が保持されていること
- タイムアウト後も同一 `channelId` で `connect()` できること
- 強制 teardown 後も `state == .disconnected` になり、Sora の接続管理からの除去等、MediaChannel の後始末が完了すること
- 通常の切断（非同期が返る場合）ではタイマーが cancel され発火しないこと。同期パス・遅延パスとも `onDisconnect` の発火タイミングに実質的な後退がないこと（既存 E2E が通ること）
- タイムアウト待ち中は `state == .disconnecting`、完了後は `.disconnected` であること
- `onDisconnect` / `SoraCloseEvent` / `Configuration.disconnectCleanupTimeout` の doc にセマンティクス（`.ok` = プロトコル理由、SDK 運用問題 = `.error`）が明記されていること
- 単体テスト（タイムアウト強制 teardown、タイマー cancel、同期 / 遅延パスの発火順序）が追加されていること
- `CHANGES.md` の `develop` セクションに `[ADD]` エントリが追記されていること
- 公開 API の追加に伴い、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` が再生成され、`make api-check-fresh` が成功すること

## 解決方法

### 実装

1. `Configuration` に `disconnectCleanupTimeout` を追加する。`PeerChannel` は `Configuration` ではなく `ConnectionConfigurationSnapshot` を保持するため、同 snapshot にも追加して `ConnectionStateOwner` へ渡す
2. `SoraError` に `disconnectCleanupTimeout(original: SoraCloseEvent?)` を追加する（`errorDescription` も追加する）
3. `DisconnectReason` に `disconnectCleanupFailed` を追加する
4. `ConnectionStateOwner` と `ConnectionStateReducer` にタイマー状態を追加し、`requestDisconnect()` の遅延パスで開始、`basicDisconnect()` の実行時または保存した要求の破棄時に cancel する（世代管理で旧タイマーを無効化する）
5. タイムアウト時は `ConnectionStateOwner` の直列 queue 上で `isDisconnecting = true`、`asyncOperationCount = 0` にするイベントを適用して `PendingDisconnect` を取り出し（保存が無い場合は何もしない）、queue の外で `basicDisconnect(error:reason:)` を強制実行する
6. `sendDisconnectMessageIfNeeded()` の `state == .failed` 早期 return へ `.disconnectCleanupFailed` も除外として追加し、NO-ERROR の送信分岐にも `.disconnectCleanupFailed` を追加する
7. タイムアウト通知用に、保存済みの error から `SoraCloseEvent` を組み立てる変換を `MediaChannel.makeDisconnectEvent(error:)` と共通化し、`SoraError.disconnectCleanupTimeout(original:)` を error として渡す
8. `MediaChannel` class doc と `onDisconnect` / `SoraCloseEvent` / `Configuration` の doc を更新する
9. 公開 API を追加するため、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功することを確認する

```
- [ADD] 切断クリーンアップのタイムアウト (Configuration.disconnectCleanupTimeout) と SoraError.disconnectCleanupTimeout を追加する
  - @voluntas
```

`onDisconnect` をクリーンアップ完了後に発火させる変更は 0010 で反映済みのため、`[CHANGE]` エントリは本 issue では追加しない。

### テスト

- **単体テスト**: 遅延パスでタイマーが発火し強制 teardown されること、`disconnectCleanupTimeout(original:)` が 1 回通知されること、通常完了時にタイマーが cancel されること、同期 / 遅延パスの発火順序を検証する
- **E2E**: 既存切断 E2E（`testSendonlyReconnect` 等）が回帰しないこと。E2E コメントの「DUPLICATED-CHANNEL-ID 回避の 1 秒待機」は本 issue の目的とは無関係であるため、本 issue では削除・変更しない（別途整理可）
