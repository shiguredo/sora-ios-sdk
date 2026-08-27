# ConnectionTimer の旧タイマーが新しい接続を切断する問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-connection-timer-lifecycle
- Polished:

## 目的

`ConnectionTimer.run()` を複数回呼んだときに、参照を失った旧 Timer が main RunLoop 上で発火し、新しい接続を timeout として切断する問題を修正する。

Timer の生成、停止、再実行、破棄を一貫して管理し、過去の接続試行に属する timeout が現在の接続状態へ作用しないことを保証する。

## 現状

`Sora/ConnectionTimer.swift` の `ConnectionTimer.run(timeout:handler:)` は、新しい `Timer` を生成して `timer` プロパティへ代入するが、既存の Timer を invalidate しない。

既存 Timer は main RunLoop に保持されているため、プロパティを上書きしても発火できる。旧 Timer の callback 内で `self.stop()` を呼ぶと、`timer` プロパティが指している新 Timer を invalidate する。

このため、次の実行順が成立する。

1. 接続 A の timeout Timer を開始する。
2. Timer を明示的に停止しないまま、接続 B のために `run()` を再実行する。
3. `timer` プロパティが接続 B の Timer に置き換わる。
4. main RunLoop に残っている接続 A の Timer が発火する。
5. 接続 A の callback が現在の monitor を timeout として切断し、`stop()` が接続 B の Timer を停止する。

また、`ConnectionTimer` が Timer を保持し、Timer closure が `self` を強参照しているため、Timer が発火または invalidate されない場合は循環参照が残る。

`run()` と `stop()` は `MediaChannel` の接続処理、PeerChannel callback、切断処理、Timer callback から呼ばれ、`timer` と `isRunning` の読み書きも同期されていない。

## 再現手順

1. 短い timeout で `ConnectionTimer.run()` を呼ぶ。
2. 最初の期限前に、異なる timeout で `run()` を再実行する。
3. 最初の期限を経過した時点で、新しい Timer と monitor の状態を記録する。
4. 旧 Timer が handler を呼ぶ、または新 Timer が停止されることを確認する。

`run`、`stop`、`run` の順序や、新旧 deadline が逆転する条件も反復して確認する。

## 設計方針

- `run()` の開始時に既存 Timer を必ず invalidate し、プロパティを nil にする。
- Timer ごとに generation または接続試行 ID を保持し、callback 発火時に現在の generation と一致する場合だけ timeout 処理を行う。
- Timer closure は `self` を weak capture する。
- `stop()` は対象 Timer を invalidate した後、同じ排他領域で `timer = nil` と `isRunning = false` を設定する。
- Timer の状態を 1 つの executor または lock の下で管理する。main RunLoop への登録が必要な場合も、呼び出し元のスレッドから直接 Timer state を変更しない。
- timeout handler と monitor の `disconnect()` は内部 lock の外で呼ぶ。
- 本 issue では `ConnectionTimer` の lifecycle bug だけを修正する。接続状態全体の actor / serial executor への集約は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- 実際の `ConnectionTimer` を main RunLoop 上で動かし、`run -> run`、`run -> stop -> run`、`run -> stop` を検証する。
- 旧 deadline が新 deadline より先に来る場合と後に来る場合の両方を検証する。
- generation が一致しない Timer callback が handler と monitor の切断を実行しないことを確認する。
- Timer 停止後に `ConnectionTimer` が解放されることを weak 参照で確認する。
- 実接続で timeout Timer の再設定を行い、旧 timeout による切断が起きないことを確認する。
- テストには、新旧 Timer のどちらを発火させる順序なのかを日本語コメントで明記する。

## 完了条件

- `run()` の再実行前に旧 Timer が無効化されること。
- 旧 generation の Timer callback が現在の接続を切断しないこと。
- 旧 Timer の callback が新 Timer を停止しないこと。
- `run()` と `stop()` が競合しても `timer` と `isRunning` が矛盾しないこと。
- Timer と `ConnectionTimer` の循環参照が残らないこと。
- timeout handler と monitor の切断を内部 lock の外で呼んでいること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
