# 接続ライフサイクルの状態所有者を単一化する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-connection-state-owner
- Polished: 2026-09-02

## 目的

`MediaChannel`、`PeerChannel`、`ConnectionTask`、接続 timeout に分散している接続状態の読み書きを、接続単位の 1 つの actor または serial executor へ集約する。

Swift 6 の isolation を型と実行経路で保証できる内部構造へ移行し、`nonisolated(unsafe)` と「ベストエフォート」の状態同期に依存しない設計にする。

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

- `0092`: `ConnectionTask` の即時キャンセル競合
- `0093`: 接続完了 callback の厳密な 1 回終端
- `0095`: redirect 時の旧 transport 無効化
- `0096`: `ConnectionTimer` の lifecycle

## 設計方針

### 接続状態 reducer

- 接続 phase、論理接続 ID、transport epoch、完了済み callback 台帳を保持する production の状態 reducer を導入する。
- reducer の入力は、利用者操作、signaling event、PeerConnection event、DataChannel event、timeout、redirect、切断とする。
- reducer は副作用を直接実行せず、WebRTC 操作、callback 配送、snapshot 更新などの effect を返す。
- 不正な状態遷移と stale epoch のイベントを明示的に拒否する。

### 単一 owner

- reducer と接続に属する mutable state を、接続単位の actor または serial executor が所有する。
- iOS 14 への back deployment を維持できる Swift concurrency API、`DispatchQueue`、`NSLock` の範囲で実装する。
- custom executor や新しい同期 primitive を利用する場合は、最低 iOS バージョンでの availability を確認してから採用する。
- Objective-C / libwebrtc delegate 自体を actor isolated witness にせず、薄い `NSObject` adapter から ordered ingress へイベントを渡す。
- callback ごとに独立した unstructured `Task` を生成しない。複数 queue から届くイベントの順序を 1 本の ingress で確定する。

### 同期 public getter

- owner が状態更新時に immutable な `MediaChannelSnapshot` を生成する。
- public の同期 getter は `NSLock` 等で保護した snapshot storage だけを読む。
- 複数 getter 間の整合した組み合わせが必要な利用者向けに、version 付き snapshot getter を追加できる構造にする。
- callback を呼ぶ前に snapshot を publish し、callback 内の同期 getter が新しい状態を観測できる順序を保証する。

### callback

- handler は状態確定後に take-and-clear または immutable snapshot として取り出す。
- 利用者 callback は owner の critical section 外で呼び、reentrant な `disconnect()`、getter、cancel を許容する。
- callback の executor 契約を内部設計コメントに明記する。公開 callback API の変更は別 issue とする。

## スコープ外

- `SignalingChannel` と `URLSessionWebSocketChannel` 自身の状態所有は `0101` で扱う。
- 公開 handler を `@Sendable` または `AsyncStream` へ移行する作業は別 issue とする。
- raw WebRTC 型を公開 API から除去する作業は `0070` の方針と整合させる。
- 本 issue で公開 API を一斉に async 化しない。

## テスト方針

モックやスタブは使用しない。

- production の状態 reducer に実際のイベント型を入力し、connect、cancel、timeout、redirect、disconnect の順列を検証する。
- すべてのイベント列で、接続 phase と callback 完了台帳が矛盾せず、終端が 1 回であることを確認する。
- 実 Sora と実 WebRTC を使い、同時 connect、即時 cancel、callback 内 disconnect、redirect、再接続を反復する。
- public callback 内からすべての同期 getter を呼び、deadlock せず最新 snapshot を取得できることを確認する。
- Thread Sanitizer と actor data race checks を補助的に有効化する。
- テストには、検証するイベント順と stale event を拒否すべき理由を日本語コメントで明記する。

## 完了条件

- 接続 phase、論理接続 ID、transport epoch、callback 完了状態の所有者が 1 つであること。
- `PeerChannel` の接続状態フラグから `nonisolated(unsafe)` が除去されていること。
- Objective-C / libwebrtc callback が単一の ordered ingress を経由すること。
- callback ごとの独立した Task 生成にイベント順序を依存していないこと。
- public の同期 getter が actor の同期 wait を行わず、lock-backed snapshot を参照すること。
- callback の呼び出し前に状態と snapshot が確定していること。
- callback 内から同期 getter、cancel、disconnect を呼んでも deadlock しないこと。
- iOS 14 で利用できない concurrency API を無条件に使用していないこと。
- `0092`、`0093`、`0095`、`0096` の回帰テストを含む全テストが成功すること。

## 解決方法
