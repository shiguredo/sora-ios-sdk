# 画面共有の再開始後に旧フレームが送信される問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-screen-capture-frame-generation
- Polished:

## 目的

画面共有を停止して直ちに再開始したときに、停止前に送信 queue へ投入された旧フレームが、古い `MediaStream` を使って送信される問題を修正する。

各フレームを画面共有の capture ID に紐付け、現在の capture と一致しないフレームを送信前に必ず破棄する。

## 現状

`Sora/ScreenCapture.swift` の `ScreenCaptureController` は、`startCapture` の非同期完了を管理するために `captureID` と `activeCaptureID` を保持している。

一方、`handleSampleBuffer(sampleBuffer:sampleBufferType:error:)` が取得する `CaptureContext` には次の情報しか含まれない。

- `senderStream`
- `videoSampleBufferTransformer`

取得した context と sample buffer は `sendVideoFrameQueue` へ投入される。queue 上の処理は `isReadyToSend()` で現在の `captureState` を確認するが、context を取得した capture と現在の capture が同一かは確認しない。

このため、次の実行順が成立する。

1. capture A のフレームが context A とともに `sendVideoFrameQueue` へ投入される。
2. queue 上で処理される前に capture A を停止する。
3. capture B を直ちに開始し、状態が再び `.running` になる。
4. capture A の queued frame が `isReadyToSend()` を通過する。
5. context A が保持する古い sender stream へフレームを送信する。

start completion の世代管理だけでは、既に enqueue 済みの frame を無効化できない。

## 再現手順

1. 実際の ReplayKit 画面共有を開始する。
2. フレームが連続して到着している間に停止し、直ちに再開始する。
3. 停止前後の capture ID、sender stream、送信 frame を記録する。
4. 再開始後に、停止前の capture ID または sender stream でフレームが送られることを反復して確認する。

queue の混雑を発生させるために transformer 処理を意図的に重くする方法は、利用者提供の実処理を用い、stub による遅延注入は行わない。

## 設計方針

- `CaptureContext` に、context 作成時点の capture ID を含める。
- `captureContext()` は `activeCaptureID`、sender stream、transformer を同じ lock 区間で snapshot 化する。
- `sendVideoFrameQueue` 上でフレームを変換・送信する直前に、context の capture ID と現在の `activeCaptureID` を照合する。
- capture ID の不一致、停止中、sender stream の変更を検出した場合はフレームを破棄する。
- stop 開始時に `activeCaptureID` を無効化し、それ以前に enqueue されたフレームを即座に stale とする。
- semaphore はすべての早期 return で確実に signal する現在の `defer` 構造を維持する。
- 本 issue は capture generation の不一致による誤送信だけを対象とする。`CMSampleBuffer` と非 Sendable closure の executor 越境は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- production code の capture generation 判定へ、start、frame enqueue、stop、restart、frame execute のイベント列を入力し、旧 ID が拒否されることを検証する。
- 実 ReplayKit と実 `MediaStream` を使用し、停止と即時再開始を反復する。
- capture A の停止後に capture A の frame が送信されないことを、capture ID と送信記録で確認する。
- capture B の開始後は capture B の frame が正常に送信されることを確認する。
- transformer が frame を drop する経路と VideoFrame 変換失敗経路でも semaphore が回復することを確認する。
- テストには、capture state だけでは旧 frame を識別できない理由を日本語コメントで明記する。

## 完了条件

- `CaptureContext` が作成元の capture ID を保持していること。
- frame 送信直前に context の capture ID と `activeCaptureID` を照合していること。
- stop 開始前に enqueue された frame が、restart 後に送信されないこと。
- stale frame を破棄した後も semaphore が回復し、現行 capture の送信が継続すること。
- stop、restart、frame callback が競合しても古い sender stream を利用しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
