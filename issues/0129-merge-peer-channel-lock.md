# PeerChannel.Lock を接続状態 reducer へ統合する

- Created: 2026-09-03
- Completed:
- Priority: Medium
- Branch: feature/merge-peer-channel-lock
- Polished: 2026-09-03

## 目的

`PeerChannel.Lock` (count / isDisconnecting / shouldDisconnect、NSLock で保護) の扱いを再検討する。`0010` が MediaChannel の接続ライフサイクルを `connectionLifecycleLock` (NSLock) で再実装しており、`0100` は PeerChannel の接続状態フラグ (nonisolated(unsafe) 5 つ) のみの reducer に限定されている。そのため、Lock の統合先は 0010 の `connectionLifecycleLock` と 0100 の reducer のどちらにすべきかを決定する。

`0100` では `PeerChannel.Lock` を現状維持とし、この統合を本 issue で扱う。

## 現状

`PeerChannel` には `final class Lock` が存在し、進行中の非同期処理数 (count)、切断開始フラグ (isDisconnecting)、遅延切断要求 (shouldDisconnect) を NSLock で保護している。

- `lock()`: count をインクリメント。isDisconnecting 中は false を返す
- `unlock()`: count をデクリメント。count == 0 になると遅延保存した切断要求を実行
- `waitDisconnect(error:reason:)`: count > 0 の間は切断要求を保存し、count == 0 または接続試行中 (count == 1) の解除時に `basicDisconnect` を実行

この Lock は `0100` で導入する PeerChannel の接続状態フラグの状態と密接に関係するが、0100 ではスコープ外とした。

## 前提となる issue

- `0010`: MediaChannel の接続ライフサイクルを `connectionLifecycleLock` (NSLock) で再実装 (0069 / 0038 と密接)
- `0100`: PeerChannel の接続状態フラグの reducer (完了後に対象)

## 設計方針

- 統合先を決定する。`0010` の `connectionLifecycleLock` と同じ領域へ組み込むか、`0100` の reducer へ組み込むかを検討し、どちらか 1 つに選定する。
- 接続処理の直列化と PeerChannel の状態遷移を単一の ingress で処理する。
- `waitDisconnect` の遅延実行セマンティクス (接続試行中の切断要求、猶予タイマー発動時のキャンセル等) を維持する。
- callback の再入 (basicDisconnect から lock/unlock を呼ぶ場合) が deadlock しないことを保証する。

## スコープ外

- transport 世代 (dataChannelGeneration) の管理は `0100` (PeerChannel の接続状態フラグ reducer)。
- 接続 phase / callback 完了状態の管理は、本 issue で扱わない (MediaChannel の接続ライフサイクルは `0010` の connectionLifecycleLock が担い、単一化の対象となる issue は別途検討)。

## テスト方針

- Lock の各エッジケース (接続試行中切断、猶予タイマーキャンセル、遅延切断の上書き、redirect 中切断) を検証する。モックやスタブは使用しない。
- 実 Sora と実 WebRTC を使い、connect / cancel / redirect / disconnect / timeout event を反復する。
- Thread Sanitizer を補助的に有効化する。
- テストには、検証するイベント順を日本語コメントで明記する。

## 完了条件

- `PeerChannel.Lock` が削除され、その管理状態が統合先 (0010 の `connectionLifecycleLock` または 0100 の reducer) に移行されていること。
- 統合先の完了条件が引き続き満たされていること。
- 既存の全テストが成功すること。

## 解決方法
