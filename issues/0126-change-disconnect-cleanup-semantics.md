# 切断クリーンアップが完了しない場合のタイムアウトと強制 teardown を追加する

- Priority: Medium
- Created: 2026-08-28
- Completed:
- Branch: feature/change-disconnect-cleanup-semantics
- Polished: 2026-11-25
- Refreshed: 2026-11-24

## 目的

`MediaChannel.beginDisconnect()` 経由の切断が遅延パスに入り、非同期処理（`createAnswer` 等）の完了が返らない場合、`basicDisconnect()` が実行されず、`onDisconnect` が発火しないまま `MediaChannel.state == .disconnecting` とリソース（WebSocket / RTCPeerConnection、および Sora の接続管理への登録）が残留し続ける。SDK 側に「`pendingDisconnect` が `basicDisconnect()` に渡るまでの待機」の上限を設け、期限内に渡らない場合は強制 teardown して `basicDisconnect()` の既存経路で `onDisconnect` を 1 回発火させ、永久待ちを防ぐ。

本 issue の対象は `ConnectionStateOwner` の `pendingDisconnect` が滞留する経路に限る。`MediaChannel` の切断準備（画面キャプチャ停止、映像ハードミュートの解放）、カメラ停止、WebSocket のクローズ完了が返らない場合は対象外であり、`onDisconnect` の 1 回発火は `MediaChannel` の切断準備とカメラ停止の完了を前提にする（WebSocket のクローズ完了は待たない）。

なお「`onDisconnect` を後始末の完了後に発火させる」変更自体は、0010（MediaChannel の接続ライフサイクル再実装）により既に現行実装へ反映済みである（現状を参照）。本 issue の残作業は、完了しない場合のタイムアウト、タイムアウト時の通知 API（`SoraError.disconnectCleanupTimeout`）、および doc の明記である。

## 優先度根拠

現行実装では `onDisconnect` 発火時点で PeerChannel の後始末は完了しており、旧実装の「早すぎる通知」は解消済みである。残る問題は、非同期コールバックが返らない場合に切断が永遠に完了しないことである。発生するのはコールバック消失・無限待ちという稀な経路だが、発生すると `MediaChannel.beginDisconnect()` 経由の切断では `MediaChannel.state == .disconnecting` に固定され、リソースと Sora の接続管理が残留するため、破棄も再利用もできず接続ごとに蓄積する。切断完了の待機に上限がないという SDK の堅牢性の問題であり、確定したバグというより運用上の停止条件であるため Medium とする。

## 現状

### onDisconnect の発火タイミング（対応済み）

`MediaChannel.beginDisconnect()` は `state = .disconnecting` を設定して `peerChannel.disconnect(error:reason:)` を呼ぶ。クリーンアップ完了後、`PeerChannel.finishBasicDisconnect()` の `internalHandlers.onDisconnect` を経由して `MediaChannel.finishDisconnect()` が `state = .disconnected` と `handlers.onDisconnect`（`SoraCloseEvent`）を 1 回だけ実行する。`onDisconnect` より前に完了するのは、PeerConnection の close、AudioSession lease の解放、stream の終端、カメラ停止、MediaChannel の切断準備（画面キャプチャ停止、映像ハードミュートの解放）までである。`signalingChannel.disconnect()` は WebSocket のクローズ要求を非同期に投入するだけで、クローズ完了は待たない。したがって現在は同期パス・遅延パスのどちらでも、`onDisconnect` はこれらの後始末の完了後に発火し、MediaChannel の class doc「いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます」とも一致している（WebSocket のクローズ完了を除く）。

### 残っている問題

`ConnectionStateOwner.requestDisconnect(error:reason:shouldCancelDisconnectTimerBasedDisconnect:isConnectHandlerHeld:)` は、切断要求を即時実行するか遅延保存するかを分岐する。

- **同期パス**（`asyncOperationCount == 0`、または接続試行中で `asyncOperationCount == 1` かつ接続完了 callback を保持している場合）: `disconnectAccepted`（または `disconnectAcceptedWhileConnecting`）を適用し、`PeerChannel.disconnect(error:reason:)` が戻り値の `PendingDisconnect` を受けて `basicDisconnect()` を実行する。`asyncOperationCount == 0` でも、猶予タイマー由来の要求が接続の回復により取り消される場合は実行しない。
- **遅延パス**（`isStartingConnection` の区間中、または上記のいずれにも該当しない場合）: private な `pendingDisconnect` に保存するだけで即 return する。保存された要求は、非同期処理の完了時（`ConnectionStateOwner.endAsyncOperation()`）または signaling 開始の確定時（`prepareSignalingStart` / `finishSignalingStart`）に取り出され、猶予タイマー由来で接続が回復していれば破棄され、そうでなければ `basicDisconnect()` が実行される。

遅延パスで非同期コールバック（`createAnswer` 等）が返らない場合、`endAsyncOperation()` が呼ばれず `pendingDisconnect` は保存されたままになる。このとき `onDisconnect` は発火せず、`MediaChannel.beginDisconnect()` 経由の切断では `MediaChannel.state` は `.disconnecting` のまま、PeerConnection・WebSocket・Sora の `_mediaChannels` 登録などが残留し続ける。`DataChannel` の closed 通知や `RTCPeerConnectionState` の `.failed` / `.closed` は `PeerChannel.disconnect()` を直接呼ぶため、これらの経路では `MediaChannel.state` が `.disconnecting` にならないまま同じ滞留が起こる。クリーンアップ完了を待つ上限が存在しないことが本 issue の対象である。

## 設計方針

### 切断クリーンアップタイムアウト

遅延パスで `pendingDisconnect` を保存した時点でタイマーを開始する。保存済みの要求が新しい要求で上書きされた場合は、タイマーを再開始して最後に保存された要求から `Configuration.disconnectCleanupTimeout` 秒を保証する。`disconnectCleanupTimeout` 秒以内に、保存した要求が `endAsyncOperation()` / `prepareSignalingStart()` / `finishSignalingStart()` のいずれかから `basicDisconnect()` に渡らない場合、SDK が強制 teardown する。タイマーは `basicDisconnect()` の実行時（正常・強制を問わず）、または保存した要求が破棄されたときに cancel する。

タイマー発火時も、`resolvePendingDisconnect` と同じ `shouldCancelDisconnectTimerBasedDisconnect(pending.reason)` を評価する。猶予タイマー由来の要求が保存された後に接続が回復している場合は、保存した要求を破棄してタイマーを cancel し、強制 teardown しない（回復した接続を切断しないという既存の契約を維持する）。判定は、`requestDisconnect` に渡している `shouldCancelDisconnectTimerBasedDisconnect` と同じ判定を `[weak peerChannel]` で包んだ closure として保持し、タイマー発火時に呼ぶ。

タイマーは `Timer` / `ConnectionTimer` ではなく、`PeerChannel.scheduleDisconnectTimerIfNeeded()` と同じ `DispatchQueue.global(qos: .background).asyncAfter` と世代照合で実装する。`ConnectionTimer` は接続試行中の timeout 用で、`ConnectionMonitor` の接続状態を前提とするため流用しない。`ConnectionStateOwner` の `eventQueue` 上で `asyncAfter` すると、発火後の `eventQueue.sync` が再入になって deadlock するため使わない。

```swift
// Configuration.swift
/// 遅延パスで切断クリーンアップ完了を待つ最大秒数。0 以下はタイムアウトなし（デバッグ用途のみ）。
public var disconnectCleanupTimeout: Int = 30
```

デフォルト 30 秒（`connectionTimeout` と同値）。0 以下はタイムアウトなし（デバッグ用途のみ）と doc に明記する。

タイマーの開始・cancel・再開始・強制 teardown は `ConnectionStateOwner` の状態（`asyncOperationCount` / `isDisconnecting` / `isStartingConnection` / `pendingDisconnect`）と直列化する必要があるため、`ConnectionStateOwner` の直列 queue と `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionStateReducer` で扱う（`requestDisconnect` / `endAsyncOperation` / `resolvePendingDisconnect` と同じ排他領域から操作する）。タイマーは世代を持ち、cancel 済みの旧タイマーが遅れて発火しても何もしないようにする（`disconnectTimerGeneration` と同じ方式）。

### タイムアウト時の処理

1. `ConnectionStateOwner` の直列 queue 上で、発火したタイマーの世代が `ConnectionLifecycleState` の現在の世代と一致するかを照合し、一致しない場合は何もしない。一致する場合は保存済みの `pendingDisconnect` があるかを確認する（無い場合は何もしない）
2. ある場合は `shouldCancelDisconnectTimerBasedDisconnect(pending.reason)` を評価し、true なら保存した要求を破棄してタイマーを cancel し、以降の処理を行わない
3. タイムアウト用の `ConnectionEvent` を適用し、`isDisconnecting = true`、`asyncOperationCount = 0` にリセットする
4. `pendingDisconnect` を取り出し、`eventQueue.sync` の復帰後に `PeerChannel` を弱参照するコールバックへ渡す（timer callback のスレッドから `eventQueue` を保持したまま `basicDisconnect()` を呼ばない）
5. `PeerChannel` は queue の外で `original` を組み立て、`basicDisconnect(error: SoraError.disconnectCleanupTimeout(original:), reason: .disconnectCleanupFailed)` を強制実行する（進行中の非同期の完了は待たない。以後の `endAsyncOperation()` は `isDisconnecting` ガードで無視される）。`original` は保存済みの error を `MediaChannel.makeDisconnectEvent(error:)` と同じ規則で `SoraCloseEvent` に変換して作る。error が nil の場合は `.ok(code: 1000, reason: "NO-ERROR")` とする。ただし reason が `.dataChannelClosed` で `dataChannelSignalingClose` がある場合は、`basicDisconnect()` と同じく error を `SoraError.dataChannelClosed(statusCode:reason:)` に置き換えてから `makeDisconnectEvent` で変換する（結果は `.ok(code: reason:)` になる）
6. `basicDisconnect()` の既存経路（`sendDisconnectMessageIfNeeded` → `signalingChannel.disconnect()` → `finishBasicDisconnect()` → `MediaChannel.finishDisconnect()`）がそのまま `state = .disconnected` と `handlers.onDisconnect` の 1 回発火を実行する。強制 teardown 専用の `state` 遷移や handler 呼び出しは追加しない（二重発火を防ぐため）
7. `basicDisconnect(error:reason:)` の内部で呼ばれる `sendDisconnectMessageIfNeeded(reason: .disconnectCleanupFailed, error:)` で NO-ERROR を送信する（best-effort。この分岐では error を使わない）。`sendDisconnectMessageIfNeeded()` の `state == .failed` による早期 return は `.peerConnectionStateDisconnected` のみ除外しているため、`.disconnectCleanupFailed` も同様に除外する（`.failed` でも WebSocket は生存している可能性があり、サーバー側セッションの解放が目的のため）。NO-ERROR を送信する `switch reason` の分岐は `.user` / `.noError` と `.peerConnectionStateDisconnected` の 2 つがあるが、`.disconnectCleanupFailed` は DataChannel の生死が不明なため `.peerConnectionStateDisconnected` と同じ WebSocket のみの送信分岐へ追加する

`MediaChannel.makeDisconnectEvent(error:)` は `SoraError` を既定で `.error` へ変換するため、`onDisconnect` には `.error(SoraError.disconnectCleanupTimeout(original:))` として通知される。

### 公開 API: `SoraError.disconnectCleanupTimeout`

```swift
/// 切断クリーンアップがタイムアウトし、強制 teardown したことを示します。
/// original には、タイムアウト前に確定していた切断理由を保持します。
case disconnectCleanupTimeout(original: SoraCloseEvent)
```

`original` は `pendingDisconnect` から必ず組み立てられるため optional にしない。`onDisconnect` への通知:

```swift
SoraCloseEvent.error(
  SoraError.disconnectCleanupTimeout(original: originalCloseEvent)
)
```

`.ok(code, reason: "DISCONNECT-CLEANUP-FAILED")` のように `.ok` に載せない。`.ok` は正常終了（WebSocket / DataChannel の close code / reason、または error の無い切断で SDK が合成する 1000 / "NO-ERROR"）に使い、SDK が検出したエラーや運用上の停止は `.error` とする。

### 内部: `DisconnectReason.disconnectCleanupFailed`

`sendDisconnectMessageIfNeeded` 等の SDK 内部分岐用。アプリには直接公開しない。

### 0147 との関係

0147（`SoraError` の粒度の検討）は pending であり、方針は未確定である。本 issue は `connectionTimeout` / `rpcTimeout` と同じ「特定の事象ごとに専用 case を追加する」前例に従って `disconnectCleanupTimeout` を追加し、associated value の形は本 issue で確定する。0147 の方針が決まった場合は、その方針に従って関連する case の見直しを行う。

### 0047 との関係

本 issue は 0047（`onDisconnectComplete` 追加）の後継として、2 段 API ではなく `onDisconnect` 自体を終端イベントとして正す方針を引き継ぐ。`onDisconnectComplete` は追加しない。切断開始時点で UI を更新したい利用者向けの別イベントも本 issue のスコープ外とする。

### 0129 との関係

0129（`PeerChannel.Lock` の統合）は 2026-09-29 に完了しており、`PeerChannel.Lock` は削除済みである。`Lock` が管理していた状態（`count` / `isDisconnecting` / `isStartingConnection` / `shouldDisconnect`）は、`Sora/ConnectionLifecycle.swift` の `ConnectionStateOwner` / `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionStateReducer` が担う。本 issue のタイマーと強制 teardown は、この状態機械へ `ConnectionLifecycleState` の追加状態と `ConnectionEvent` の追加ケースとして組み込む。

## 完了条件

- 遅延パスで `pendingDisconnect` を保存した後、`disconnectCleanupTimeout` 秒を超えても `basicDisconnect()` に渡らない場合に強制 teardown され、`onDisconnect` が `.error(SoraError.disconnectCleanupTimeout(original:))` で 1 回発火すること（`MediaChannel` の切断準備とカメラ停止が完了している場合）
- タイムアウト通知の `original` に、タイムアウト前に確定していた切断理由（`SoraCloseEvent`）が保持されていること。error が nil の要求では、`.dataChannelClosed` かつ `dataChannelSignalingClose` がある場合を除き `.ok(code: 1000, reason: "NO-ERROR")` が入り、`.dataChannelClosed` かつ `dataChannelSignalingClose` がある場合は `.ok(code: reason:)` が入ること
- 猶予タイマー由来の要求が保存された後に接続が回復した場合、`disconnectCleanupTimeout` が経過しても強制 teardown されず、保存した要求が破棄されること
- 保存済みの要求が上書きされた場合、最後に保存された要求から `disconnectCleanupTimeout` 秒が計測されること
- 強制 teardown 後も `MediaChannel.state == .disconnected` になり、Sora の接続管理（`Sora.mediaChannels`）から除去される等、MediaChannel の後始末が完了すること
- 通常の切断（非同期が返る場合）ではタイマーが cancel され発火しないこと。同期パス・遅延パスとも `onDisconnect` の発火タイミングに実質的な後退がないこと（既存 E2E が通ること）
- `onDisconnect` / `SoraCloseEvent` / `Configuration.disconnectCleanupTimeout` の doc にセマンティクス（`.ok` = 正常終了、`.error` = SDK が検出したエラー・運用上の問題）が明記されていること
- `ConnectionLifecycleState.isDisconnecting` と `endAsyncOperation` の doc に、タイムアウト経路が残高を強制的に 0 にする例外であることが明記されていること
- 単体テスト（タイムアウト強制 teardown、タイマー cancel、回復時の取消、上書き時の再開始、世代不一致の旧タイマーの無視、`PendingDisconnect` の引き渡し、PeerChannel レベルでの `onDisconnect` 1 回発火と `original`、同期 / 遅延パスの発火順序）が追加されていること
- `CHANGES.md` の `develop` セクションに `[ADD]` エントリが追記されていること
- 公開 API の追加に伴い、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` が再生成され、`make api-check-fresh` が成功すること

## 解決方法

### 実装

1. `Sora/Configuration.swift` に `disconnectCleanupTimeout` を追加する。`PeerChannel` は `Configuration` ではなく `ConnectionConfigurationSnapshot` を保持するため、`Sora/ConnectionConfigurationSnapshot.swift` にも追加して `ConnectionStateOwner` へ渡す
2. `Sora/SoraError.swift` に `disconnectCleanupTimeout(original: SoraCloseEvent)` を追加する（`errorDescription` も追加する）
3. `Sora/PeerChannel.swift` の `DisconnectReason` に `disconnectCleanupFailed` を追加する
4. `Sora/ConnectionLifecycle.swift` の `ConnectionStateOwner` / `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionStateReducer` にタイマー状態を追加する。`requestDisconnect()` の遅延パスで開始、上書きで再開始、`basicDisconnect()` の実行時または保存した要求の破棄時に cancel する。`DispatchQueue.global(qos: .background).asyncAfter` と世代照合で実装し、`ConnectionStateOwner` の init を変える場合は `SoraTests/ConnectionStateOwnerTests.swift` と `SoraTests/ConcurrencyStressTests.swift` の呼び出しも更新する
5. `Sora/PeerChannel.swift` にタイマー発火時の入口を追加する。タイマー発火時は `ConnectionStateOwner` の直列 queue 上で世代を照合し、次に回復判定を行い、破棄しない場合だけ `isDisconnecting = true`、`asyncOperationCount = 0` にするイベントを適用して `PendingDisconnect` を取り出す（保存が無い場合は何もしない）。`eventQueue.sync` の復帰後に、`PeerChannel` を弱参照するコールバックへ渡し、`PeerChannel` が queue の外で `basicDisconnect(error: SoraError.disconnectCleanupTimeout(original:), reason: .disconnectCleanupFailed)` を強制実行する
6. `sendDisconnectMessageIfNeeded()` の `state == .failed` 早期 return へ `.disconnectCleanupFailed` も除外として追加し、`.disconnectCleanupFailed` を `.peerConnectionStateDisconnected` と同じ WebSocket のみの NO-ERROR 送信分岐へ追加する
7. タイムアウト通知用に、保存済みの error から `SoraCloseEvent` を組み立てる変換を `MediaChannel.makeDisconnectEvent(error:)` と共通化し、`SoraError.disconnectCleanupTimeout(original:)` を error として渡す。`dataChannelSignalingClose` の反映は `basicDisconnect()` と同じ規則にする
8. `Sora/MediaChannel.swift` の `MediaChannel` class doc と `onDisconnect` / `SoraCloseEvent` / `Configuration` の doc を更新する。あわせて `ConnectionLifecycleState.isDisconnecting` と `endAsyncOperation` の doc にタイムアウト経路の例外を追記する
9. 公開 API を追加するため、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功することを確認する

```
- [ADD] 切断クリーンアップのタイムアウト (Configuration.disconnectCleanupTimeout) と SoraError.disconnectCleanupTimeout を追加する
  - @voluntas
```

`onDisconnect` を後始末の完了後に発火させる変更は 0010 で反映済みのため、`[CHANGE]` エントリは本 issue では追加しない。

### テスト

- **単体テスト（ConnectionStateOwner）**: `ConnectionStateOwner` を直接使ったテストで、遅延パスのタイムアウトで `PendingDisconnect` がコールバックへ渡ること、回復時に発火しないこと、上書き時に再開始されること、世代不一致の旧タイマーが無視されること、通常完了時に cancel されること、同期 / 遅延パスの発火順序を検証する。`disconnectCleanupTimeout` は 1 秒にして実時間で検証し、モックやスタブは使わない
- **単体テスト（PeerChannel）**: 実 `PeerChannel` を使い、`beginAsyncOperation()` の後に `disconnect()` を呼んで遅延パスを作り、`disconnectCleanupTimeout` を 1 秒にしてタイマーを実時間で発火させる。`internalHandlers.onDisconnect` が `SoraError.disconnectCleanupTimeout(original:)` で 1 回呼ばれること、`original` が error nil の `.ok(code: 1000, reason: "NO-ERROR")` と `.dataChannelClosed` + `dataChannelSignalingClose` の `.ok(code: reason:)` で期待どおりになることを検証する。モックやスタブは使わない
- **状態遷移と登録解除**: 強制 teardown は `basicDisconnect()` → `finishBasicDisconnect()` → `MediaChannel.finishDisconnect()` の既存経路を使うため、新しい `state` 遷移は追加しない。`MediaChannel.state` の `.disconnecting` → `.disconnected` と `Sora.mediaChannels` からの除去は、既存の通常切断のテストと E2E で回帰を確認する
- **E2E**: 既存切断 E2E（`testSendonlyReconnect` 等）が回帰しないこと。タイムアウトを実サーバーで誘発する手段が無いため、強制 teardown の確認は単体テストで行い、E2E は通常切断の回帰に限定する。ローカルでは `SORA_SIGNALING_URL` が未設定のため skip され、CI の `e2e-test.yml` で実行する。E2E コメントの「DUPLICATED-CHANNEL-ID 回避の 1 秒待機」は本 issue の目的とは無関係であるため、本 issue では削除・変更しない（別途整理可）
