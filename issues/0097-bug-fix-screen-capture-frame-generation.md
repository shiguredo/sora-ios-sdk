# 画面共有の再開始後に旧フレームが送信される問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-screen-capture-frame-generation
- Polished: 2026-08-27

## 目的

画面共有を停止して直ちに再開始したときに、停止前に送信 queue へ投入された旧フレームが、古い `MediaStream` を使って送信される問題を修正する。

各フレームを画面共有の capture ID に紐付け、現在の capture と一致しないフレームを送信前に必ず破棄する。

## 現状

`Sora/ScreenCapture.swift` の `ScreenCaptureController` は、`startCapture` の非同期完了を管理するために `captureID` と `activeCaptureID` を保持している。

一方、`handleSampleBuffer(sampleBuffer:sampleBufferType:error:)` が取得する `CaptureContext` には次の情報しか含まれない。

- `senderStream`
- `videoSampleBufferTransformer`

取得した context と sample buffer は `sendVideoFrameQueue` へ投入される。queue 上の処理は `isReadyToSend()` で現在の `captureState` を確認するが、context を取得した capture と現在の capture が同一かは確認しない。

このため、次の実行順が成立する。`sendVideoFrameSemaphore` は単発 flight のため queue に滞留する frame は最大 1 件で即時実行される。送信処理のうち `isReadyToSend()` 通過から `context.senderStream.send(videoFrame:)` までの間には transformer という長い利用者処理が入るため、この間に stop / restart が完了すると旧 frame が送信される。

1. capture A のフレームが context A とともに `sendVideoFrameQueue` へ投入され、`isReadyToSend()` を通過する。
2. transformer 実行などの送信処理中に capture A を停止し、capture B を直ちに開始して状態が再び `.running` になる。
3. 送信処理が続行し、`context.senderStream.send(videoFrame:)` が context A が保持する古い sender stream へフレームを送信する。

`isReadyToSend()` は実行時点の `captureState` しか確認しないため、stop / restart 後に再び `.running` になった状態では旧 capture の frame を識別できない。start completion の世代管理（`captureID` 照合）だけでも、既に `isReadyToSend()` を通過した frame を無効化できない。

## 再現手順

1. 実際の ReplayKit 画面共有を開始する。
2. フレームが連続して到着している間に停止し、直ちに再開始する。
3. 停止前後の capture ID、sender stream、送信 frame を記録する。
4. 再開始後に、停止前の capture ID または sender stream でフレームが送られることを反復して確認する。

transformer 実行中に stop / restart が完了する間合いを作るため、利用者提供の実 transformer で重い処理を使う。stub による遅延注入は行わない。

## 設計方針

- `CaptureContext` に、context 作成時点の capture ID を含める。
- `captureContext()` は `activeCaptureID`、sender stream、transformer を同じ lock 区間で snapshot 化する。
- `sendVideoFrameQueue` 上で `context.senderStream.send(videoFrame:)` の直前（transformer 実行後）に、context の capture ID と現在の `activeCaptureID` を照合する。transformer は長い利用者処理になり得るため、queue 先頭付近の照合だけでは transformer 実行中の stop / restart を検出できない。
- capture ID の不一致、停止中、sender stream の変更を検出した場合はフレームを破棄する。破棄対象 frame では `markVideoFrameSent`（PTS / uptime の記録）を実行せず、throttle 状態を汚染しない。
- `markVideoFrameSent`（PTS / uptime の記録）は generation 照合を通過して送信が確定した後に実行する。現在は transformer より前（`isReadyToSend()` 直後）で実行しているため、照合の後に移動する。これにより、破棄された stale frame、transformer が drop した frame、VideoFrame 変換に失敗した frame は throttle 状態を更新しない（`0104` の「送信済み timestamp を更新しない」方針とも一致する）。
- stop 開始時に `activeCaptureID` を無効化し、`isReadyToSend()` を通過済みの frame も送信直前の照合で stale として破棄する。
- generation 照合を `shouldSendFrameForCaptureID(_:)` のような production の関数へ切り出し、テストからイベント列（start、frame enqueue、stop、restart、実行）を直接入力できるようにする。
- semaphore はすべての早期 return で確実に signal する現在の `defer` 構造を維持する。
- 本 issue は capture generation の不一致による誤送信だけを対象とする。`CMSampleBuffer` と非 Sendable closure の executor 越境は `0104` で扱う。

## テスト方針

モックやスタブは使用しない。

- 設計方針で切り出す generation 判定（`shouldSendFrameForCaptureID(_:)` 等）へ、start、frame enqueue、stop、restart、frame execute のイベント列を入力し、旧 ID が拒否されることを検証する。
- 実 ReplayKit と実 `MediaStream` を使った停止・即時再開始の検証は、Simulator では ReplayKit 画面共有が動作しないため実機での手動確認とする。手動確認の項目を generation 判定へのイベント列入力と組み合わせて回帰を防ぐ。
- capture A の停止後に capture A の frame が送信されないことを、capture ID と送信記録で確認する。
- capture B の開始後は capture B の frame が正常に送信されることを確認する。
- transformer が frame を drop する経路と VideoFrame 変換失敗経路でも semaphore が回復することを確認する。
- stale frame の破棄後に capture B の先頭フレームが targetFPS により間引かれないこと（throttle 状態の未汚染）を確認する。
- テストには、capture state だけでは旧 frame を識別できない理由を日本語コメントで明記する。

## 完了条件

- `CaptureContext` が作成元の capture ID を保持していること。
- frame 送信直前に context の capture ID と `activeCaptureID` を照合していること。
- stop / restart の競合後も、旧 capture の frame が送信されないこと。
- stale frame を破棄した後も semaphore が回復し、現行 capture の送信が継続すること。
- stale frame の破棄で throttle 状態が汚染されず、再開後の先頭フレームが targetFPS により間引かれないこと。
- stop、restart、frame callback が競合しても古い sender stream を利用しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
