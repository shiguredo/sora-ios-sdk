# type: notify で更新される接続人数の状態競合を修正する

- Created: 2026-09-03
- Completed:
- Priority: Medium
- Branch: feature/fix-notify-connection-count-races
- Polished: 2026-09-03

## 目的

`MediaChannel` の `connectionCount` / `publisherCount` / `subscriberCount` は `type: notify` 受信時に WebSocket delegate スレッドから更新され、利用者が任意のスレッドから同期 getter で読む。現状は NSLock の保護がなく、データ競合のリスクがある。NSLock で保護する。

## 現状

- 更新元: `MediaChannel.onReceiveSignaling` の `.notify` 分岐 (WebSocket delegate スレッド)
- 読む側: 利用者の同期 getter (`connectionCount` / `publisherCount` / `subscriberCount`。任意スレッド)
- 保護: なし

## 設計方針

- `MediaChannel` にこれらの 3 値を保護する NSLock を追加する (既存の `dataChannelOpenLock` / `connectionTimer.stateLock` と同じパターン)。
- 更新 (`connectionCount` / `publisherCount` / `subscriberCount` の代入) はロック配下で行う。
- getter の読み出しも lock 配下で行う。
- handler (`onReceiveSignaling`) の呼び出しはロックの外で行う (利用者コードがロックを保持したまま実行されないようにする)。
- これは 0100 のスコープ外として確定した事項であり、本 issue は 0100 とは独立に実装する。

## スコープ外

- `state` / `connectionStartTime` の snapshot 化 (`MediaChannelSnapshot`) は `0100` で扱う。`connectionCount` 系は 0100 のスコープ外 (0100 の「スコープ外」に明記) であり、本 issue で扱う。
- `onReceiveSignaling` の Sendable 化 / event API 化は `0110` で扱う。

## テスト方針

- 更新と読み出しを複数スレッドから並行して行う concurrency テスト (Thread Sanitizer 有効) を追加する。モックやスタブは使用しない。
- 実 Sora からの notify 受信で、更新が正しく反映されることを確認する。

## 完了条件

- `connectionCount` / `publisherCount` / `subscriberCount` が NSLock で保護されること。
- Thread Sanitizer 有効のテストでデータ競合が検出されないこと。
- 既存の全テストが成功すること。

## 解決方法
