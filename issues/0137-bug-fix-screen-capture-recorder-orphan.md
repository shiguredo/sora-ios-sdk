# 画面キャプチャ start 失敗時に ReplayKit の録画が停止されないまま残る問題を修正する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-capture-recorder-orphan
- Polished: 2026-10-30
- Updated: 2026-10-30

## 目的

画面キャプチャの開始に失敗した際に、ReplayKit の録画が停止されないまま残り、以後の画面共有が開始できなくなる問題を修正する。

## 現状

- `ScreenCaptureController.startCapture` は `startRecorderCaptureIfIdle` の結果が `.completed(RecorderOperationResult(error: ..., isRecording: true))` の場合、`recordRecorderStart` を呼ばずに `recorderCoordinator.release(ownerID:)` だけを行う。
- `recordRecorderStart` は成功時のみ呼ばれるため `recorderCaptureID` が設定されず、以降の `stopCapture` では `stopRecorderCaptureAfterBegin` の停止対象にならない。加えて `completeStartCapture(captureID:error:)` が `captureState = .stopped` にするため `scheduleStopCapture` も停止を起動しない。
- owner が解放されるため、別接続が `acquire` しても `startRecorderCaptureIfIdle` の `alreadyRecording` で失敗し続ける。
- 結果として、録画が停止されないまま残り、プロセス全体で画面共有を開始できない状態になり得る。
- 現行コードのコメントは「isRecording だけでは SDK の所有権を証明できない」として停止しない判断をしている。ReplayKit は録画の所有者を問い合わせる API を提供しない。

## 設計方針

- 所有権の判定は `RecorderStartResult` の case で行う。`.alreadyRecording`（SDK が `startCapture` を発行する前から録画中）はホスト所有として停止しない。`.completed(RecorderOperationResult(error:isRecording: true))` は SDK が `startCapture` を発行した後の録画として SDK 所有として扱う。
- start 失敗時に SDK 所有の録画が残る場合（`.completed(RecorderOperationResult(error:isRecording: true))`）は、`recordRecorderStart(captureID:)` を呼び、`recorderCoordinator.release(ownerID:)` を呼ばずに owner を保持する。`completeStartCapture(captureID:error:)` が `.failed` を返した場合は `captureState` を `.cleanupFailed` にし、`.cancelled` の場合は停止が既に予約されているためその処理に任せる。これにより既存の `stopRecorderCaptureAfterBegin` の停止経路が使える。録画が残らない失敗（`error` かつ `isRecording == false`、`error == nil` かつ `isRecording == false`）と `.alreadyRecording` は従来どおり `release` する。停止が予約されていない場合（`completeStartCapture` が `.failed` を返す場合）は `captureState` は `.stopped` のままとし、`.cancelled` の場合は `.stopping` のまま停止処理に任せる。
- 停止のトリガーは、失敗した `startScreenCapture` の `catch` 経由の `stopCapture`、`stopScreenCapture`、`stopCaptureForDisconnect` とする。
- 停止成功後に `recorderCoordinator.finishStop(ownerID: recorderOwnerID, recorderStopped: true)` で隔離を解除する。停止に失敗した場合は隔離状態を維持し、以後の画面共有開始を決定的に失敗させる。
- ReplayKit が所有権を照会できないため、ホストアプリが同時に `RPScreenRecorder` を使用する場合は SDK がホストの録画を停止し得る。この制約を `MediaChannel.startScreenCapture` の doc コメントに明記する。

## 再現手順

- 画面キャプチャを開始し、`startRecorderCaptureIfIdle` が error かつ `isRecording == true` を返す状況を作る。
- このとき録画が停止されず、別接続からの画面共有開始が `alreadyRecording` で失敗し続けることを確認する。
- 実 ReplayKit の失敗は自動テストで再現できないため、実機の手動確認とする。

## 変更対象

- `Sora/ScreenCapture.swift`: SDK 所有の録画が残る start 失敗分岐での `recordRecorderStart(captureID:)` 呼び出し、`recorderCoordinator.release(ownerID:)` の削除（`.alreadyRecording` 分岐は除く）、`captureState` の `.cleanupFailed` 設定（`.failed` の場合）、`recordRecorderStart` の doc と失敗分岐コメントの更新
- `Sora/MediaChannel.swift`: `startScreenCapture` の doc コメントに制約を追記
- `SoraTests/`: start 失敗時の所有権・隔離判断を検証するテスト
- `CHANGES.md`: `## develop` の `[FIX]` に、start 失敗時に ReplayKit の録画が残る問題の修正を追記
- `skills/sora-ios-sdk/SKILL.md`: 画面キャプチャ節に、start 失敗時に SDK がホストの録画を停止し得る制約と停止失敗時の隔離を追記

## 完了条件

- start 失敗後に ReplayKit の録画が SDK の管理下で停止できる。
- SDK 所有の録画が残る start 失敗では、失敗直後から停止完了まで `recorderCoordinator.isOwner(recorderOwnerID)` が true のままで、別接続の `acquire` が失敗する。
- 停止の再試行に成功した後は、別接続からも画面共有を開始できる。
- 停止に失敗した場合は隔離状態を維持し、以後の開始を決定的に失敗させる。
- SDK 所有の録画が残らない失敗（`error` かつ `isRecording == false`、`error == nil` かつ `isRecording == false`）と `.alreadyRecording` では所有者を解放する。停止が予約されていない場合（`completeStartCapture` が `.failed` を返す場合）は `captureState` は `.stopped` のままで `isCaptureActive()` が false を返し、`.cancelled` の場合は `.stopping` のまま停止処理に委ねる。
- `.alreadyRecording`（ホスト所有）の録画を停止しない。
- `MediaChannel.startScreenCapture` の doc コメントに、ホストの録画を停止し得る制約が書かれている。
- `CHANGES.md` の `## develop` に `[FIX]` が追記されている。
- `skills/sora-ios-sdk/SKILL.md` の画面キャプチャ節に、ホストの録画を停止し得る制約と停止失敗時の隔離が書かれている。
- start 失敗時の所有権・隔離判断を internal な純粋関数またはメソッドへ切り出し、イベント列で検証するテストを追加すること。SDK 所有の録画が残る `.failed` では `.cleanupFailed` になり、`.cancelled` では `.stopping` のまま停止処理に委ね、SDK 所有の録画が残らない失敗では `.stopped` のままであること、停止成功後に `finishStop` で所有者が解放されること、停止失敗時に隔離が維持されることを検証する。モックやスタブは使用しない。実 ReplayKit の orphan 再現は実機の手動確認とし、未検証項目を区別する。

## 関連 issue

- `0097`: 送信直前の capture ID 照合 (停止・再開始の世代管理) を導入した。
- `0010`: ステレオ音声出力対応の変更 (PR #381) で `ScreenCaptureRecorderCoordinator`、`.cleanupFailed`、`stopRecorderCaptureAfterBegin`、および「start 失敗時は release のみ」という現行判断を導入した。
- `0104`: ScreenCapture の sample buffer 所有境界を扱う別スコープ。
- `0192`: iOS 27 以降の ScreenCaptureKit 対応。SCK 経路でも開始失敗時に作成済みのストリームを残さない方針を示しており、本 issue の修正と同じ不変条件を目指している。
- `0193`: `MediaChannel.startScreenCapture(settings:)` の doc コメントと `skills/sora-ios-sdk/SKILL.md` の画面キャプチャ節に、アプリ内画面のみを対象とする旨を追記する。本 issue が追記する「ホストの録画を停止し得る」制約と同じ箇所を変更対象にしている。

## 解決方法
