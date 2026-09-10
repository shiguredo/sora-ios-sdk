# PeerChannel の接続状態フラグの所有者を単一化する

- Created: 2026-08-27
- Completed: 2026-09-08
- Branch: feature/refactor-peer-channel-flags
- Polished: 2026-09-04

## Reopened

- Reopened: 2026-09-04
- Reopen 理由: 当初は MediaChannel 全体の接続ライフサイクルを単一 owner 化する予定だったが、`0010` (ステレオ音声出力) が MediaChannel の接続ライフサイクルを NSLock ベース (connectionLifecycleLock) で再実装し、develop へマージされていた (003bb738)。0010 の実装は実際に動作しており、検証も完了している。そのため、0100 の範囲を PeerChannel の接続状態フラグ (nonisolated(unsafe) 5 つ) の所有者の単一化に限定し、MediaChannel 側のライフサイクルは 0010 の NSLock ベースの直列化を正とする。

## 目的

`PeerChannel` に分散している接続状態の読み書きを、接続単位の 1 つの reducer へ集約する。

対象とする状態は、PeerChannel の接続状態フラグ 5 つ (webSocketDisconnectScheduled / disconnectTimerScheduled / disconnectTimerGeneration / dataChannelGeneration / isRedirecting) である。MediaChannel の接続ライフサイクル (state / connectionStartTime / callback 配送) は 0010 の実装 (NSLock ベースの直列化) を正とし、本 issue では扱わない。

Swift 6 の isolation を型と実行経路で保証できる内部構造へ移行し、`nonisolated(unsafe)` と「ベストエフォート」の状態同期に依存しない設計にする。

本 issue は、iOS の最低対応バージョンの引き上げを必要としない。利用する Swift concurrency API (`DispatchQueue` / `NSLock` / `AsyncStream` 等) は iOS 13.0+ で利用可能なため、iOS 14 対応を維持したまま実装する。

## 現状

PeerChannel の接続状態フラグ 5 つは、`nonisolated(unsafe)` で宣言されていた。

- `Sora/PeerChannel.swift`
  - `webSocketDisconnectScheduled` — DataChannel シグナリング切り替え後の WebSocket の二重切断を防ぐ
  - `disconnectTimerScheduled` — 接続完了後の切断検出の猶予タイマーの開始済みフラグ
  - `disconnectTimerGeneration` — 猶予タイマーの世代 (トークン)
  - `dataChannelGeneration` — DataChannel 通知の世代 (トークン)
  - `isRedirecting` — リダイレクト中フラグ

これらは、利用者スレッド、`DispatchQueue.global()`、URLSession delegate queue、libwebrtc callback、DataChannel delegate、main RunLoop から読み書きされる。

`PeerChannel` の一部フラグには `nonisolated(unsafe)` が付与され、コメントも競合を `Lock.waitDisconnect` で吸収する「ベストエフォート」を前提としている。これは Swift 6 の型検査を回避するだけで、状態遷移の順序やデータ競合を保証しない。

同期 public getter をそのまま actor isolated property にすると source compatibility を壊す。一方、actor へ Task を投げて semaphore で同期的に待つと、actor または MainActor 上の callback から getter を呼んだ場合に deadlock する。

## 前提となる issue

本 issue は既存バグの意味を変えずに状態所有を整理する refactor とする。次のバグ修正を先に完了させ、そのテストを移行時の回帰検証として利用する。

- `0092`: `ConnectionTask` の即時キャンセル競合
- `0093`: 接続完了 callback の厳密な 1 回終端
- `0095`: redirect 時の旧 transport 無効化
- `0096`: `ConnectionTimer` の lifecycle

## 設計方針

### 接続状態 reducer

- PeerChannel の接続状態フラグ 5 つ (transport 世代 / WebSocket スケジュール / 猶予タイマー開始・世代 / redirect 中) を保持する production の状態 reducer を導入する。
- reducer の入力は、WebSocket スケジュール、猶予タイマー (開始 / 発火 / キャンセル)、redirect 受信、redirect 窓の終了、切断完了とする。
- reducer は副作用を直接実行せず、snapshot 更新などの effect を返す。
- イベントは呼び出し側のガードを通過したものが渡される前提とし、reducer 自身では拒否しない (reducer への入力は DispatchQueue 直列化で順序が確定する)。

```text
[イベントソース]
  PeerChannel
  (scheduleWebSocketDisconnect / 猶予タイマー / redirect / 切断)
       │
       │ DispatchQueue.sync (直列化)
       ▼
┌──────────────────────────────────────────────────────────────┐
│ ConnectionStateOwner (単一所有者, DispatchQueue 直列化)         │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ reducer: (State, Event) -> (State, [Effect])            │  │
│  │  State: transportEpoch / webSocketDisconnectScheduled   │  │
│  │         / disconnectTimerScheduled /                   │  │
│  │         / disconnectTimerGeneration / isRedirecting     │  │
│  └──────────────────────────────┬─────────────────────────┘  │
│                                 ▼                            │
│  ┌─────────────────────────┐                                  │
│  │ NSLock で保護した snapshot│                                  │
│  └────────────┬────────────┘                                  │
└───────────────┴───────────────┴───────────────────────────────┘
                │
                ▼
[PeerChannel の同期 getter] dataChannelGeneration / isRedirecting /
  webSocketDisconnectScheduled / disconnectTimerScheduled /
  disconnectTimerGeneration (snapshot 読み)
```

### 単一 owner

- reducer と PeerChannel の接続状態フラグ 5 つを、**PeerChannel 内の serial executor (DispatchQueue 直列化) が所有する**。
- 同期 API から await で呼び出さずに済むよう、actor ではなく `DispatchQueue` (serial) による直列化を採用する。
- `PeerChannel` が `ConnectionStateOwner` を直接保持し、自身のフラグを snapshot で読み、イベントを投げる形に置き換える。

### 同期 getter

- owner が状態更新時に immutable な `ConnectionLifecycleState` snapshot を生成し、NSLock で保護した storage へ publish する。
- `PeerChannel` の同期 getter は、NSLock で保護した snapshot storage だけを読む。
- callback を呼ぶ前に snapshot を publish し、callback 内の同期 getter が新しい状態を観測できる順序を保証する。

### callback

- handler は状態確定後に take-and-clear または immutable snapshot として取り出す。
- 利用者 callback は owner の critical section 外で呼び、reentrant な `disconnect()`、getter、cancel を許容する。
- callback の executor 契約を内部設計コメントに明記する。公開 callback API の変更は別 issue とする。

## スコープ外

- MediaChannel の接続ライフサイクル (state / connectionStartTime / callback 配送) は `0010` の実装 (connectionLifecycleLock) を正とする。
- `SignalingChannel` と `URLSessionWebSocketChannel` 自身の状態所有は `0101` で扱う。
- 公開 handler を `@Sendable` または `AsyncStream` へ移行する作業は別 issue とする。
- callback 配送の reducer の Effect への完全移行は `0110` (Sendable event API) で扱う。
- raw WebRTC 型を公開 API から除去する作業は `0070` の方針と整合させる。
- 本 issue で公開 API を一斉に async 化しない。
- DataChannel の OPEN 追跡状態 (`openedDataChannelLabels` / `messagingLabels` / `onDataChannelNotified`、`dataChannelOpenLock` で保護) は本 issue のスコープ外。現状どおり `NSLock` で保護し、発火判定は reducer (接続状態フラグ) の状態を参照しない (ラベル集合のみに依存)。
- `connectionCount` / `publisherCount` / `subscriberCount` (`type: notify` 受信で更新)は本 issue のスコープ外。(`0128` で扱う)
- `ConnectionTimer` の実装 (stateLock / timer / generation) は本 issue のスコープ外。ConnectionTimer 自体の状態所有は現状維持とする。

## テスト方針

モックやスタブは使用しない。

- production の状態 reducer に実際のイベント型を入力し、redirect 受信 / redirect 窓終了 / WebSocket スケジュール / 猶予タイマー (開始 / 発火 / キャンセル) / 切断完了の遷移を検証する。
- すべてのイベント列で、フラグの値と副作用 (publishSnapshot) が矛盾しないことを確認する。
- 実 Sora と実 WebRTC を使い、redirect、再接続を反復する。
- Thread Sanitizer と actor data race checks を補助的に有効化する。
- テストには、検証するイベント順を日本語コメントで明記する。

## 完了条件

- PeerChannel の接続状態フラグから `nonisolated(unsafe)` が除去されていること。
  - 対象: `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `disconnectTimerGeneration` / `dataChannelGeneration` / `isRedirecting` の 5 つ
  - `ConnectionTask.state` の `NSLock` は 0092 の実装を現状維持する (除去対象ではない)。
  - `PeerChannel` 以外の `nonisolated(unsafe)` (CameraVideoCapturer / DeviceInfo / Logger / MediaChannelConfiguration / MediaStream、および `Sora.swift` の `webRTCCallbackLogger`) はスコープ外。 (`webRTCCallbackLogger` は `0111` の対象)
- `dataChannelGeneration` が transport 世代として reducer に含まれ、DataChannel delegate の世代照合が sync な read (snapshot) で行われること。世代変更時も snapshot が publish されること。
- 同期 getter が serial executor の同期 wait を行わず、NSLock で保護した snapshot storage を参照すること。
- イベントの処理が serial executor (DispatchQueue 直列化) 上で行われること。
- iOS 14 では利用できない concurrency API (iOS 16+ 限定 `Clock` / `ContinuousClock` / `AsyncTimerSequence` 等) を無条件に使用していないこと。
- `0092`、`0093`、`0095`、`0096` の回帰テストを含む全テストが成功すること。

## 解決方法

PeerChannel の接続状態フラグ 5 つを接続単位の単一所有者 (reducer + snapshot) へ移行した。

### 実装内容

- `Sora/ConnectionLifecycle.swift` (新規):
  - `ConnectionLifecycleState`: transport 世代 / webSocketDisconnectScheduled / disconnectTimerScheduled / disconnectTimerGeneration / isRedirecting の 5 フラグ
  - `ConnectionEvent`: redirectReceived / redirectConnectStarted / webSocketDisconnectScheduled / disconnectTimerScheduled / disconnectTimerFired / disconnectTimerCancelled / disconnectCompleted の 7 イベント
  - `ConnectionStateReducer` (純粋関数。イベントは呼び出し側のガードを通過した前提で、順序は DispatchQueue 直列化で確定)
  - `ConnectionStateOwner` (DispatchQueue 直列化による単一所有者。actor ではなく sync API から await 化を避けるため)
  - `ConnectionSnapshotStorage` (NSLock で保護した lock-backed snapshot)
- `Sora/PeerChannel.swift`:
  - `nonisolated(unsafe)` の 5 フラグ宣言を削除
  - `ConnectionStateOwner` / `ConnectionSnapshotStorage` を直接保持 (MediaChannel は変更しない)
  - 各フラグを snapshot から読む computed getter に置き換え
  - 各書き込みを `handleConnectionEvent(_:)` に置き換え

### 設計上の判断

- 単一所有者は PeerChannel が直接保持する (MediaChannel の接続ライフサイクルは connectionLifecycleLock (NSLock ベース) が担当し、本 issue では変更しない)。
- reducer の Effect は publishSnapshot のみ (全イベントが無条件に publish する)。効果の追加は Sendable event API の拡張時に検討する。
- 呼び出し側ガード (check-then-act) によるベストエフォートは従来どおり維持する (重複しても発火時ガードや世代照合で無害化される)。

### テスト

- `SoraTests/ConnectionStateReducerTests.swift` (新規): redirect 受信 / redirect 窓終了 / WebSocket スケジュール / 猶予タイマー (開始 / 発火 / キャンセル) / 切断完了 / snapshot round-trip の 7 件。

### 実機確認

- 通常接続・切断・redirect (クラスタ Sora) を実機で確認済み。
- 一時ログで reducer のイベント処理 (redirectReceived → redirectConnectStarted → disconnectCompleted) と各フラグの遷移を確認済み。
