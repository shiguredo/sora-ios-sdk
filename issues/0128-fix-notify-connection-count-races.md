# type: notify で更新される接続人数の状態競合を修正する

- Created: 2026-09-03
- Completed:
- Priority: Medium
- Branch: feature/fix-notify-connection-count-races
- Polished: 2026-11-10
- Refreshed: 2026-11-10

## 目的

`MediaChannel` の `connectionCount` / `publisherCount` / `subscriberCount` は `type: notify` 受信時に WebSocket の受信スレッドまたは DataChannel シグナリング利用時の DataChannel の delegate スレッドから更新され、利用者が任意のスレッドから同期 getter で読む。現状は NSLock の保護がなく、データ競合のリスクがある。NSLock で保護する。

## 現状

- 更新元: `MediaChannel.basicConnect(connectionTask:)` が `peerChannel.internalHandlers.onReceiveSignaling` に設定する closure の `.notify` 分岐。この closure は `PeerChannel.handleSignalingOverWebSocket(_:)` と `PeerChannel.handleSignalingOverDataChannel(_:)` から呼ばれる
- 更新スレッド: WebSocket 経由は `SignalingStateOwner` が作る直列の `OperationQueue` (`jp.shiguredo.sora-ios-sdk.websocket-delegate`) 上で処理される。DataChannel シグナリング利用時は libwebrtc の DataChannel delegate スレッドから呼ばれる
- 読む側: 利用者の同期 getter (`connectionCount` / `publisherCount` / `subscriberCount`。任意スレッド)
- 保護: なし

## 設計方針

- `MediaChannel` に 3 値を保護する NSLock を追加する。stored property のままでは getter を lock 配下にできないため、3 値は `state` と同じく `get` / `set` を明示した `public private(set) var` の computed property にし、`set` は lock 配下で値を書く private メソッドへ集約する。lock は `dataChannelOpenLock` / `MediaChannelStateStorage` と同じく、保持したまま他の lock を取らない葉 lock として扱う。
- 更新 (`connectionCount` / `publisherCount` / `subscriberCount` の代入) はロック配下で行う。
- getter の読み出しも lock 配下で行う。
- handler (`onReceiveSignaling`) の呼び出しはロックの外で行う (利用者コードがロックを保持したまま実行されないようにする)。
- これは `0100` (PeerChannel の接続状態フラグの所有者を単一化する、完了 2026-09-08) のスコープ外として確定した事項であり、`0100` はこの 3 値を本 issue に委ねている。本 issue は `0100` とは独立に実装する。

## スコープ外

- `state` / `connectionStartTime` は本 issue では扱わない。MediaChannel の接続ライフサイクルは `0010` の `connectionLifecycleLock` による直列化を正とし、`state` は `0180` (完了 2026-10-05) で `MediaChannelStateStorage` (NSLock 付き storage) を読む computed property になり、書き込みは `connectionLifecycleLock` を保持した区間の `setState(_:)` に限られる。`connectionStartTime` は `connectionLifecycleLock` を保持した区間で書くが、`connectionTime` は lock を取らずに読む。本 issue で扱うのは `connectionCount` / `publisherCount` / `subscriberCount` のみ
- `onReceiveSignaling` の Sendable 化は `0110` (完了 2026-10-07) では行われていない。`0110` は legacy handler の型を変更せず、Sendable な event API (`MediaChannel.subscribeEvents(bufferingPolicy:)` / `SoraEvent`) を追加した。接続人数の event 化は本 issue では扱わない。

## 変更対象

- `Sora/MediaChannel.swift`: 3 値を保護する NSLock と computed property の追加、`.notify` 分岐の更新
- `SoraTests/`: 更新と読み出しを複数スレッドから交差させる concurrency テストの追加
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: computed property 化で公開 ABI の dump が変わるため、`make api-baseline` で再生成する

## テスト方針

- 更新と読み出しを複数スレッドから並行して行う concurrency テスト (Thread Sanitizer 有効) を追加する。モックやスタブは使用しない。
- 実 Sora からの notify 受信で、更新が正しく反映されることを確認する。

## 完了条件

- `connectionCount` / `publisherCount` / `subscriberCount` が NSLock で保護されること。
- 追加した concurrency テストを Thread Sanitizer 有効で実行し、データ競合が検出されないこと。
- `make api-check-fresh` が成功すること。
- 既存の全テストが成功すること。

## 解決方法
