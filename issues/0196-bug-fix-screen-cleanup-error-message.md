# 画面キャプチャの後始末失敗時にカメラ競合のエラーが返る問題を修正する

- Created: 2026-10-30
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-cleanup-error-message
- Polished: 2026-11-02

## 目的

画面キャプチャの停止に失敗して後始末待ちの状態 (`VideoSourceCoordinator` の `.screenCleanupFailed`) のときに `MediaChannel.startScreenCapture` を呼ぶと、カメラキャプチャとの競合を示すエラーが返る。実際の復旧手順は `stopScreenCapture()` の再試行であり、利用者に誤った操作 (`setVideoHardMute(true)`) を案内しているため修正する。

## 現状

- `MediaChannel.startScreenCapture` は `videoSourceCoordinator.beginScreen(stream:)` が nil を返すと、一律に `"camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"` を throw する (`Sora/MediaChannel.swift` の `startScreenCapture` の `beginScreen` 呼び出し直後)
- `VideoSourceCoordinator.beginScreen(ownerID:stream:)` は、owner entry が存在しない、revoke 済み、`state != nil`、または同じ stream にカメラ予約がある場合に nil を返す (`Sora/CameraVideoCapturer.swift` の `beginScreen`)。画面キャプチャの停止に失敗した状態 `.screenCleanupFailed` も `state != nil` に該当する
- `.screenCleanupFailed` は `finishScreenStop(_:stopped: false)` で設定され (`Sora/CameraVideoCapturer.swift` の `finishScreenStop`)、`stopScreenCapture()` の `beginScreenStop()` はこの状態からの再試行を受け付ける。つまり復旧経路は `stopScreenCapture()` の再試行であり、`setVideoHardMute(true)` では復旧しない
- 画面キャプチャの start 失敗の後始末に失敗した場合も `.cleanupFailed` / `.screenCleanupFailed` に到達するため、このエラーは実際に利用者が踏み得る

## 再現手順

- 画面キャプチャを開始し、停止後も recorder が録画中のまま (`isRecording` が true) になる状況を作る。`stopCapture` の完了が error を返しても `isRecording` が false なら後始末は成功し `.cleanupFailed` にはならない (`Sora/ScreenCapture.swift` の `stopRecorderCaptureAfterBegin` / `completeStopCapture`)
- `isScreenCaptureActive()` が true のまま `startScreenCapture` を呼ぶ
- カメラ競合を示すエラーが返り、`setVideoHardMute(true)` では復旧しないことを確認する
- 実 ReplayKit の停止失敗は自動テストで再現できないため、状態遷移は `VideoSourceCoordinator` の単体テストで確認する

## 設計方針

- `VideoSourceCoordinator.beginScreen` の失敗理由を、呼び出し元が区別できる形にする (例: `Result<Reservation, ScreenStartFailure>` を返し、`.cameraInUse` / `.screenCleanupPending` / `.screenOperationInProgress` などを区別する)
- `MediaChannel.startScreenCapture` は `.screenCleanupPending` の場合に、`stopScreenCapture()` による停止の再試行を案内するエラーを返す
- それ以外の失敗理由 (`.cameraInUse`、`.screenOperationInProgress`、切断済みなど) は現行のエラーメッセージを維持する。画面キャプチャの開始中・実行中・停止中に返るメッセージの見直しは目的が異なるため本 issue の範囲外とする
- 既存のカメラ競合メッセージと、`isCameraVideoCaptureRunning` のガードは現在の挙動を維持する
- 後始末待ちの状態からの復旧は `stopScreenCapture()` の再試行で成立するため、新しい停止 API は追加しない

## 変更対象

- `Sora/CameraVideoCapturer.swift`: `VideoSourceCoordinator.beginScreen` の戻り値と失敗理由
- `Sora/MediaChannel.swift`: `startScreenCapture` の `beginScreen` 失敗時のエラー分岐
- `SoraTests/`: `VideoSourceCoordinator` の失敗理由と、`startScreenCapture` のエラーメッセージを検証するテスト

## 完了条件

- `.screenCleanupFailed` の状態で `startScreenCapture` を呼ぶと、`stopScreenCapture()` による再試行を案内するエラーが返る
- カメラキャプチャが同じ sender stream を使用している場合は、従来どおりカメラ競合のエラーが返る
- 画面キャプチャの開始中・実行中・停止中 (`beginScreen` が `.screenOperationInProgress` を返す状態) でも、従来どおりのエラーメッセージが返る
- `beginScreen` の各失敗理由を検証するテストが追加されている。モックやスタブは使用しない
- `make build` / `make fmt-lint` / `make lint` / 既存テストが成功する

## 関連 issue

- `0137`: start 失敗時に ReplayKit の録画を停止できず、後始末に失敗すると `.cleanupFailed` / `.screenCleanupFailed` に到達する。本 issue はその後始末失敗時のエラー案内を扱う
- `0192`: ScreenCaptureKit 対応。SCK 経路でも開始失敗時の停止を扱う
- `0193`: `MediaChannel.startScreenCapture` の doc コメントを変更する

## 解決方法
