# 画面キャプチャ start 失敗時に ReplayKit の録画が停止されないまま残る問題を修正する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-capture-recorder-orphan
- Polished: 2026-09-10

## 目的

画面キャプチャの開始に失敗した際に、ReplayKit の録画が停止されないまま残り、以後の画面共有が開始できなくなる問題を修正する。

## 現状

- `ScreenCaptureController.startCapture` は `startRecorderCaptureIfIdle` の結果が `.completed(RecorderOperationResult(error: ..., isRecording: true))` の場合、`recordRecorderStart` を呼ばずに `recorderCoordinator.release(ownerID:)` だけを行う。
- `recordRecorderStart` は成功時のみ呼ばれるため `recorderCaptureID` が設定されず、以降の `stopCapture` では `stopRecorderCaptureAfterBegin` の停止対象にならない。加えて `completeStartCapture(error:)` が `captureState = .stopped` にするため `scheduleStopCapture` も停止を起動しない。
- owner が解放されるため、別接続が `acquire` しても `startRecorderCaptureIfIdle` の `alreadyRecording` で失敗し続ける。
- 結果として、録画が停止されないまま残り、プロセス全体で画面共有を開始できない状態になり得る。
- 現行コードのコメントは「isRecording だけでは SDK の所有権を証明できない」として停止しない判断をしている。ReplayKit は録画の所有者を問い合わせる API を提供しない。

## 設計方針

- 所有権の判定は `RecorderStartResult` の case で行う。`.alreadyRecording`（SDK が `startCapture` を発行する前から録画中）はホスト所有として停止しない。`.completed(RecorderOperationResult(error:isRecording: true))` は SDK が `startCapture` を発行した後の録画として SDK 所有として扱う。
- start 失敗時に `recordRecorderStart(captureID:)` を呼び、`captureState` を `.cleanupFailed` に保つ。これにより既存の `stopRecorderCaptureAfterBegin` の停止経路が使える。
- 停止のトリガーは、失敗した `startScreenCapture` の `catch` 経由の `stopCapture`、`stopScreenCapture`、`stopCaptureForDisconnect` とする。
- 停止成功後に `recorderCoordinator.finishStop(ownerID: recorderOwnerID, recorderStopped: true)` で隔離を解除する。停止に失敗した場合は隔離状態を維持し、以後の画面共有開始を決定的に失敗させる。
- ReplayKit が所有権を照会できないため、ホストアプリが同時に `RPScreenRecorder` を使用する場合は SDK がホストの録画を停止し得る。この制約を `MediaChannel.startScreenCapture` の doc コメントに明記する。

## 再現手順

- 画面キャプチャを開始し、`startRecorderCaptureIfIdle` が error かつ `isRecording == true` を返す状況を作る。
- このとき録画が停止されず、別接続からの画面共有開始が `alreadyRecording` で失敗し続けることを確認する。
- 実 ReplayKit の失敗は自動テストで再現できないため、実機の手動確認とする。

## 変更対象

- `Sora/ScreenCapture.swift`: start 失敗時の `recordRecorderStart` 呼び出し、`captureState` の保持、`finishStop` の呼び出し
- `Sora/MediaChannel.swift`: `startScreenCapture` の doc コメントに制約を追記
- `SoraTests/`: start 失敗時の所有権・隔離判断を検証するテスト

## 完了条件

- start 失敗後に ReplayKit の録画が SDK の管理下で停止できる。
- 停止の再試行に成功した後は、別接続からも画面共有を開始できる。
- 停止に失敗した場合は隔離状態を維持し、以後の開始を決定的に失敗させる。
- `.alreadyRecording`（ホスト所有）の録画を停止しない。
- `MediaChannel.startScreenCapture` の doc コメントに、ホストの録画を停止し得る制約が書かれている。
- start 失敗時の所有権・隔離判断を internal な純粋関数またはメソッドへ切り出し、イベント列で検証するテストを追加すること。モックやスタブは使用しない。実 ReplayKit の orphan 再現は実機の手動確認とし、未検証項目を区別する。

## 関連 issue

- `0097`: `ScreenCaptureRecorderCoordinator` と「start 失敗時は release のみ」という現行判断を導入した。
- `0104`: ScreenCapture の sample buffer 所有境界を扱う別スコープ。

## 解決方法
