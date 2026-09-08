# PeerChannel の接続状態フラグの所有者を単一化する

- Created: 2026-08-27
- Completed:
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

PeerChannel の接続状態フラグ 5 つは、`nonisolated(unsafe)` で宣言されている。

- `Sora/PeerChannel.swift`
  - `webSocketDisconnectScheduled` (239 行) — DataChannel シグナリング切り替え後の WebSocket の二重切断を防ぐ
  - `disconnectTimerScheduled` (246 行) — 接続完了後の切断検出の猶予タイマーの開始済みフラグ
  - `disconnectTimerGeneration` (253 行) — 猶予タイマーの世代 (トークン)
  - `dataChannelGeneration` (259 行) — DataChannel 通知の世代 (トークン)
  - `isRedirecting` (266 行) — リダイレクト中フラグ

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

- 接続 phase、論理接続 ID、transport 世代、配送済み callback 台帳を保持する production の状態 reducer を導入する。
- reducer の入力は、利用者操作、signaling event、PeerConnection event、DataChannel event、timeout、redirect、切断とする。
- reducer は副作用を直接実行せず、WebRTC 操作、callback 配送、snapshot 更新などの effect を返す。
- 不正な状態遷移と stale epoch のイベントを明示的に拒否する。

```text
[イベントソース]
  利用者操作        signaling   PeerConnection   DataChannel    timer
  (disconnect)     (offer)      (didOpen)        (opened)       (timeout)
       │              │              │               │            │
       └──────────────┴──────┬───────┴───────────────┴────────────┘
                              │ yield
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 接続単位の DispatchQueue 直列化オブジェクト (単一所有者)         │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Intake: AsyncStream<ConnectionEvent> を逐次消費          │  │
│  └──────────────────────────────┬─────────────────────────┘  │
│                                 ▼                            │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ reducer: (State, Event) -> (State, [Effect])            │  │
│  │  State: phase / logicalConnectionID / transportEpoch    │  │
│  │         / deliveryTracker                               │  │
│  └──────────────────────────────┬─────────────────────────┘  │
│                        ┌────────┴─────────┐                  │
│                        ▼                  ▼                  │
│  ┌─────────────────────────┐    ┌─────────────────────────┐  │
│  │ snapshot を publish      │    │ effect を実行            │  │
│  │ (phase 遷移時 / epoch 変更時) │  │  WebRTC 操作            │  │
│  └────────────┬────────────┘    │  callback 配送          │  │
│               │                 │  (critical section 外) │  │
│               │                 └─────────────────────────┘  │
│               ▼                                                │
│  ┌─────────────────────────┐                                  │
│  │ NSLock で保護した snapshot│                                  │
│  └────────────┬────────────┘                                  │
└───────────────┴───────────────┴───────────────────────────────┘
                │
                ▼
[同期 getter] dataChannelGeneration / isRedirecting / ... (PeerChannel 内)
```

### 単一 owner

- reducer と接続に属する mutable state (接続 phase、論理接続 ID、transport 世代、配送済み callback 台帳) を、**接続単位の serial executor (DispatchQueue 直列化)** が所有する。
- 同期 API (`connect` / `disconnect`) から await で呼び出さずに済むよう、actor ではなく `DispatchQueue` (serial) による直列化を採用する。
- `PeerChannel` の接続状態フラグは、この owner の snapshot を読み、イベントを投げる形に置き換える。

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
- DataChannel の OPEN 追跡状態 (`openedDataChannelLabels` / `messagingLabels` / `onDataChannelNotified`、`dataChannelOpenLock` で保護) は本 issue のスコープ外。現状どおり `NSLock` で保護し、発火判定は reducer (接続 phase) の状態を参照しない (ラベル集合のみに依存)。
- `connectionCount` / `publisherCount` / `subscriberCount` (`type: notify` 受信で更新)は本 issue のスコープ外。snapshot は phase 遷移時および transport 世代の変更時に publish し、notify による更新は現状維持 (これらの値は接続 phase と独立に更新されるため、snapshot の整合性に影響しない)。
- `ConnectionTimer` の実装 (stateLock / timer / generation) は本 issue のスコープ外。接続 phase の更新は reducer 経由で行うが、ConnectionTimer 自体の状態所有は現状維持とする。

## テスト方針

モックやスタブは使用しない。

- production の状態 reducer に実際のイベント型を入力し、connect、cancel、timeout、redirect、disconnect の順列を検証する。
- すべてのイベント列で、接続 phase と配送済み callback 台帳が矛盾せず、終端が 1 回であることを確認する。
- 実 Sora と実 WebRTC を使い、同時 connect、即時 cancel、callback 内 disconnect、redirect、再接続を反復する。
- public callback 内からすべての同期 getter を呼び、deadlock せず最新 snapshot を取得できることを確認する。
- Thread Sanitizer と actor data race checks を補助的に有効化する。
- テストには、検証するイベント順と stale event を拒否すべき理由を日本語コメントで明記する。

## 完了条件

- PeerChannel の接続状態フラグから `nonisolated(unsafe)` が除去されていること。
  - 対象: `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `disconnectTimerGeneration` / `dataChannelGeneration` / `isRedirecting` の 5 つ
  - `ConnectionTask.state` の `NSLock` は 0092 の実装を現状維持する (除去対象ではない)。
  - `PeerChannel` 以外の `nonisolated(unsafe)` (CameraVideoCapturer / DeviceInfo / Logger / MediaChannelConfiguration / MediaStream、および `Sora.swift` の `webRTCCallbackLogger`) はスコープ外。 (`webRTCCallbackLogger` は `0111` の対象)
- `dataChannelGeneration` が transport 世代として reducer に含まれ、DataChannel delegate の世代照合が sync な read (snapshot) で行われること。世代変更時も snapshot が publish されること。
- 同期 getter が serial executor の同期 wait を行わず、NSLock で保護した snapshot storage を参照すること。
- callback の呼び出し前に状態と snapshot が確定していること。
- iOS 14 では利用できない concurrency API (iOS 16+ 限定 `Clock` / `ContinuousClock` / `AsyncTimerSequence` 等) を無条件に使用していないこと。
- `0092`、`0093`、`0095`、`0096` の回帰テストを含む全テストが成功すること。

## 解決方法
