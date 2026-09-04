# PeerChannel.Lock を接続状態 reducer へ統合する

- Created: 2026-09-03
- Completed:
- Priority: Medium
- Branch: feature/merge-peer-channel-lock
- Polished: 2026-09-03

## 目的

`PeerChannel.Lock` (count / isDisconnecting / shouldDisconnect、NSLock で保護) を `0100` で導入する接続状態 reducer へ統合し、接続処理の直列化と接続 phase の状態管理を単一の owner に集約する。

`0100` では `PeerChannel.Lock` を現状維持とし、この統合を本 issue で扱う。

## 現状

`PeerChannel` には `final class Lock` が存在し、進行中の非同期処理数 (count)、切断開始フラグ (isDisconnecting)、遅延切断要求 (shouldDisconnect) を NSLock で保護している。

- `lock()`: count をインクリメント。isDisconnecting 中は false を返す
- `unlock()`: count をデクリメント。count == 0 になると遅延保存した切断要求を実行
- `waitDisconnect(error:reason:)`: count > 0 の間は切断要求を保存し、count == 0 または接続試行中 (count == 1) の解除時に `basicDisconnect` を実行

この Lock は `0100` で導入する接続 phase の状態と密接に関係するが、iOS 14 対応制約や実装量の都合から `0100` ではスコープ外とした。

## 前提となる issue

- `0100`: 接続状態 reducer / 単一 owner の導入 (完了後に対象)

## 設計方針

- `0100` の reducer が接続 phase を所有するのと同じ actor に、`Lock` が管理する count / isDisconnecting / shouldDisconnect を集約する。
- 接続処理の直列化と接続 phase の遷移を単一の ingress で処理する。
- `waitDisconnect` の遅延実行セマンティクス (接続試行中の切断要求、猶予タイマー発動時のキャンセル等) を維持する。
- `Lock` の NSLock を撤廃し、actor の状態として管理する。
- callback の再入 (basicDisconnect から lock/unlock を呼ぶ場合) が deadlock しないことを保証する。

## スコープ外

- 接続 phase / transport epoch / callback 完了台帳の導入は `0100`。
- `0100` で導入した状態 owner の設計自体の変更は本 issue では行わない。

## テスト方針

- `0100` 導入後、`Lock` の各エッジケース (接続試行中切断、猶予タイマーキャンセル、遅延切断の上書き、redirect 中切断) を reducer イベント列として検証する。モックやスタブは使用しない。
- 実 Sora と実 WebRTC を使い、connect / cancel / redirect / disconnect / timeoutevent を反復する。
- Thread Sanitizer と actor data race checks を補助的に有効化する。
- テストには、検証するイベント順と stale event を拒否すべき理由を日本語コメントで明記する。

## 完了条件

- `PeerChannel.Lock` が削除され、その管理状態が `0100` の owner に統合されていること。
- `0100` の完了条件が引き続き満たされていること。
- 既存の全テストが成功すること。

## 解決方法
