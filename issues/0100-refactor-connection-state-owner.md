# 接続ライフサイクルの状態所有者を単一化する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-connection-state-owner
- Polished: 2026-09-04

## 目的

`MediaChannel`、`PeerChannel`、`ConnectionTask`、接続 timeout に分散している接続状態の読み書きを、接続単位の 1 つの actor へ集約する。

対象とする状態は、接続 phase (`MediaChannel.state`)、論理接続 ID、transport epoch (`dataChannelGeneration` / `disconnectTimerGeneration` の対応)、配送済み callback 台帳の 4 つである。`ConnectionTask.state` と `ConnectionTimer` の実装は本 issue で扱わない (それぞれ 0092 の実装と 0096 の実装の現状維持、および「スコープ外」を参照)。

Swift 6 の isolation を型と実行経路で保証できる内部構造へ移行し、`nonisolated(unsafe)` と「ベストエフォート」の状態同期に依存しない設計にする。

本 issue は、iOS の最低対応バージョンの引き上げを必要としない。Swift 6 言語モード対応にあたって iOS 14 サポートが手間を増やす場合のみ iOS 15 へ引き上げる方針とし、0100 で利用する Swift concurrency API (`AsyncStream` / actor / async / await / `Task`) は iOS 13.0+ で利用可能なため、iOS 14 対応を維持したまま実装する。

## 現状

接続ライフサイクルに関する状態は、複数の型と executor に分散している。

- `Sora/MediaChannel.swift`
  - `state`
  - `connectionStartTime`
  - 接続人数
  - DataChannel の OPEN 追跡状態
  - 利用者 handler と内部 handler
- `Sora/PeerChannel.swift`
  - `nativeChannel`
  - `streams`、`iceCandidates`、`dataChannels`
  - `onConnect`
  - `webSocketDisconnectScheduled`
  - `disconnectTimerScheduled` と generation
  - `dataChannelGeneration`
  - `isRedirecting`
  - RPC と signaling offer の状態
- `Sora/Sora.swift`
  - `ConnectionTask.state`
  - `ConnectionTask.peerChannel`（実体は private な `_peerChannel`）
- `Sora/ConnectionTimer.swift`
  - Timer、monitor、timeout、`isRunning`

これらは、利用者スレッド、`DispatchQueue.global()`、URLSession delegate queue、libwebrtc callback、DataChannel delegate、main RunLoop から読み書きされる。

`PeerChannel` の一部フラグには `nonisolated(unsafe)` が付与され、コメントも競合を `Lock.waitDisconnect` で吸収する「ベストエフォート」を前提としている。これは Swift 6 の型検査を回避するだけで、状態遷移の順序やデータ競合を保証しない。

同期 public getter をそのまま actor isolated property にすると source compatibility を壊す。一方、actor へ Task を投げて semaphore で同期的に待つと、actor または MainActor 上の callback から getter を呼んだ場合に deadlock する。

## 前提となる issue

本 issue は既存バグの意味を変えずに状態所有を整理する refactor とする。次のバグ修正を先に完了させ、そのテストを移行時の回帰検証として利用する。

- `ConnectionTimer` の timeout 判定 (`ConnectionMonitor`) と `Lock.unlock()` の解除判定が読む `PeerChannel.state` は WebRTC 状態起点の computed property であり、これを `MediaChannel.state` の置き換え (接続 phase) と混同しない。timeout 判定の意味変化は本 issue では導入しない。

- `0092`: `ConnectionTask` の即時キャンセル競合
- `0093`: 接続完了 callback の厳密な 1 回終端
- `0095`: redirect 時の旧 transport 無効化
- `0096`: `ConnectionTimer` の lifecycle

## 設計方針

### 接続状態 reducer

- 接続 phase、論理接続 ID、transport epoch、配送済み callback 台帳を保持する production の状態 reducer を導入する。
- reducer の入力は、利用者操作、signaling event、PeerConnection event、DataChannel event、timeout、redirect、切断とする。
- reducer は副作用を直接実行せず、WebRTC 操作、callback 配送、snapshot 更新などの effect を返す。
- 不正な状態遷移と stale epoch のイベントを明示的に拒否する。
- reducer が所有する接続 phase は、利用者から観測される `MediaChannel.state` (`ConnectionState`) を置き換える。`PeerChannel.state` (computed property) と `ConnectionTask.state` は既存のままとする (後述の「単一 owner」の `ConnectionTask.state` の扱い、および「スコープ外」を参照)。

```text
[イベントソース]
  利用者操作        signaling   PeerConnection   DataChannel    timer
  (disconnect)     (offer)      (didOpen)        (opened)       (timeout)
       │              │              │               │            │
       └──────────────┴──────┬───────┴───────────────┴────────────┘
                              │ yield
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 接続単位の actor (単一 owner)                                   │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Intake: AsyncStream<ConnectionEvent> を逐次消費          │  │
│  └──────────────────────────────┬─────────────────────────┘  │
│                                 │                            │
│                                 ▼                            │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ reducer: (State, Event) -> (State, [Effect])            │  │
│  │  State: phase / logicalConnectionID / transportEpoch    │  │
│  │         / deliveryTracker                               │  │
│  └──────────────────────────────┬─────────────────────────┘  │
│                                 │                            │
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
│  │ lock-backed snapshot    │                                  │
│  │ (NSLock で保護)          │                                  │
│  └────────────┬────────────┘                                  │
└───────────────┼───────────────┴───────────────────────────────┘
                │
                ▼
[同期 getter] state / isAvailable / connectionTime ...
[callback]    onConnect / onDisconnect ... (owner 外)
```

### 単一 owner

- reducer と接続に属する mutable state (接続 phase、論理接続 ID、transport epoch、配送済み callback 台帳) を、**接続単位の `actor`** が所有する。
- `ConnectionTask.state` は 0092 の実装 (`NSLock` + `InternalState`) を**現状維持**する。reducer の接続 phase と `ConnectionTask.state` の関係は、0092 で確立した「attach / markCanceled / complete の意味」を変えず、キャンセル要求 (cancel) の受け渡しが 0092 と同じ経路 (ConnectionTask -> PeerChannel) を維持する。
- iOS の最低対応バージョンの引き上げは、Swift 6 言語モード対応にあたって iOS 14 サポートが手間を増やす場合にのみ行う方針とする。0100 で利用する Swift concurrency API (`AsyncStream` / actor / async / await / `Task`) は iOS 13.0+ で利用可能であり、iOS 14 対応を維持したまま実装できる。iOS 14 で利用できない API (対象外の例: `Clock` / `ContinuousClock` / `AsyncTimerSequence` は iOS 16+) は無条件に使用しない。
- custom executor や新しい同期 primitive を利用する場合は、最低 iOS バージョンでの availability を確認してから採用する。
- Objective-C / libwebrtc delegate 自体を actor isolated witness にせず、薄い `NSObject` adapter から ordered ingress へイベントを渡す。
- callback ごとに独立した unstructured `Task` を生成しない。複数 queue から届くイベントの順序を 1 本の ingress (`AsyncStream<Event>` の consumer) で確定する。
- `PeerChannel.Lock` は現状維持。reducer と Lock の責任の境界は、この issue で設計・実装し、Lock の統合 (reducer へ) は別 issue (実装前に起票予定) で扱う。
- `nonisolated(unsafe)` 除去の対象は、`PeerChannel` の `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `disconnectTimerGeneration` / `dataChannelGeneration` / `isRedirecting` の 5 つである。これらは reducer (単一 owner) に集約して統合する。`PeerChannel.state` (computed property) 自体は削除せず、reducer の phase に依存する読み出しは snapshot 経由に置き換える。ただし `PeerChannel.Lock` の `unlock()` 内の `state` 読み出しは Lock 側のコードを変更しない (`PeerChannel.state` のまま)。`isRedirecting` の取得のみ reducer の snapshot 経由に置き換える。

### 同期 public getter

- owner が状態更新時に immutable な `MediaChannelSnapshot` を生成する。
- snapshot の publish は **接続 phase の遷移時および transport epoch の変更時**に行う。`connectionCount` 等 (notify で更新される値) は snapshot に含めず、現状どおり個別の getter で読む (スコープ外)。
- public の同期 getter は `NSLock` 等で保護した snapshot storage だけを読む。
- 複数 getter 間の整合した組み合わせが必要な利用者向けに、version 付き snapshot getter を追加できる構造にする。
- callback を呼ぶ前に snapshot を publish し、callback 内の同期 getter が新しい状態を観測できる順序を保証する。

### callback

- handler は状態確定後に take-and-clear または immutable snapshot として取り出す。
- 利用者 callback は owner の critical section 外で呼び、reentrant な `disconnect()`、getter、cancel を許容する。
- callback の executor 契約を内部設計コメントに明記する。公開 callback API の変更は別 issue とする。
- callback の配送を reducer の Effect (`deliverConnectCallback` 等) に全面的に移す作業は行わない。接続完了 callback の 1 回終端は既存の `invokeConnectHandler` (take-and-clear) で担保し、`deliveryTracker` は状態記録として reducer に保持する。Effect への完全移行は `0110` (Sendable event API) で扱う。

## スコープ外

- `SignalingChannel` と `URLSessionWebSocketChannel` 自身の状態所有は `0101` で扱う。
- 公開 handler を `@Sendable` または `AsyncStream` へ移行する作業は別 issue とする。
- callback 配送の reducer の Effect への完全移行は `0110` (Sendable event API) で扱う。`deliverConnectCallback` 等の Effect は 0100 では状態記録として保持し、実行する側の接続は行わない。
- raw WebRTC 型を公開 API から除去する作業は `0070` の方針と整合させる。
- 本 issue で公開 API を一斉に async 化しない。
- DataChannel の OPEN 追跡状態 (`openedDataChannelLabels` / `messagingLabels` / `onDataChannelNotified`、`dataChannelOpenLock` で保護) は本 issue のスコープ外。現状どおり `NSLock` で保護し、発火判定は reducer (接続 phase) の状態を参照しない (ラベル集合のみに依存)。
- `connectionCount` / `publisherCount` / `subscriberCount` (`type: notify` 受信で更新)は本 issue のスコープ外。snapshot は phase 遷移時および transport epoch の変更時に publish し、notify による更新は現状維持 (これらの値は接続 phase と独立に更新されるため、snapshot の整合性に影響しない)。
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

- 接続 phase、論理接続 ID、transport epoch、配送済み callback 台帳の所有者が 1 つであること。
- `dataChannelGeneration` が transport epoch として reducer に含まれ、DataChannel delegate の世代照合が sync な read (snapshot) で行われること。epoch 変更時も snapshot が publish されること。
- `PeerChannel` の接続状態フラグから `nonisolated(unsafe)` が除去されていること。
  - 対象: `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `disconnectTimerGeneration` / `dataChannelGeneration` / `isRedirecting` の 5 つ
  - `ConnectionTask.state` の `NSLock` は 0092 の実装を現状維持する (除去対象ではない)。
  - `PeerChannel` 以外の `nonisolated(unsafe)` (CameraVideoCapturer / DeviceInfo / Logger / MediaChannelConfiguration / MediaStream、および `Sora.swift` の `webRTCCallbackLogger`) はスコープ外。(`webRTCCallbackLogger` は `0111` の対象)
- Objective-C / libwebrtc callback が単一の ordered ingress を経由すること。
  - 状態を変更するイベント (redirect / disconnect / timer 等) は `handleConnectionEvent` を経由して `ConnectionStateOwner` (DispatchQueue 直列化) に集約され、順序が確定すること。libwebrtc の delegate そのものは直接 reducer には接続しない (状態を変えない通知は従来どおり)。
- callback ごとの独立した Task 生成にイベント順序を依存していないこと。
- public の同期 getter が actor の同期 wait を行わず、lock-backed snapshot を参照すること。
- callback の呼び出し前に状態と snapshot が確定していること。
- callback 内から同期 getter、cancel、disconnect を呼んでも deadlock しないこと。
- iOS 14 では利用できない concurrency API (iOS 16+ 限定 `Clock` / `ContinuousClock` / `AsyncTimerSequence` 等) を無条件に使用していないこと。
- `0092`、`0093`、`0095`、`0096` の回帰テストを含む全テストが成功すること。

## 解決方法
