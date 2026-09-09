# 画面キャプチャ start 失敗時に ReplayKit の録画が停止されないまま残る問題を修正する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-capture-recorder-orphan
- Polished: {YYYY-MM-DD}

## 目的

画面キャプチャの開始に失敗した際に、ReplayKit の録画が停止されないまま残り、以後の画面共有が開始できなくなる問題を防ぐ。

## 現状

- `ScreenCaptureController.startCapture` は `startRecorderCaptureIfIdle` の結果が error かつ `recorder.isRecording == true` の場合、`recordRecorderStart` を呼ばずに `recorderCoordinator.release(ownerID:)` だけを行う。
- `recordRecorderStart` は成功時のみ呼ばれるため `recorderCaptureID` が設定されず、以降の `stopCapture` では `stopRecorderCaptureAfterBegin` の停止対象にならない。
- owner が解放されるため、別接続が `acquire` しても `startRecorderCaptureIfIdle` の `alreadyRecording` で失敗し続ける。
- 結果として、SDK が開始した録画が動き続け、プロセス全体で画面共有を開始できない状態になり得る。

## 設計方針

- start 失敗時に `recorder.isRecording` なら SDK 所有として停止を再試行できる状態を残す。`recorderCoordinator.finishStop(recorderStopped: false)` 相当の隔離状態を用いるなど、停止要求を後から実行できる経路を確保する。
- ホストアプリが所有する録画と区別するため、`acquire` 前の `isRecording` 判定は維持する。SDK の `acquire` 後に開始された録画は SDK 所有として扱う。
- 停止できない状態が残る場合は、その状態をログに残し、以後の画面共有開始を決定的に失敗させる。

## 完了条件

- start 失敗後に ReplayKit の録画が SDK の管理下で停止できる。
- 以後の画面共有が別接続からも開始できる。
- ホストアプリが所有する録画を停止しない。
- 失敗経路を検証するテストを追加すること。モックやスタブは使用しない。ReplayKit が必要な検証は実機または実環境で行い、実行できない項目を未検証として区別する。

## 解決方法
