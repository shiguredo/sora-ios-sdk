# 画面キャプチャの後始末失敗時にカメラ競合のエラーが返る問題を修正する

- Created: 2026-10-30
- Completed: 2026-11-02
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

- `VideoSourceCoordinator.beginScreen` の戻り値を `Result<Reservation, ScreenStartFailure>` に変更し、失敗理由を `.cameraInUse` / `.screenCleanupPending` / `.screenOperationInProgress` / `.cancelled` に区別した
  - `Registry.beginScreen` の状態判定を網羅的な `switch` に変更し、`State` に case が追加されたときに失敗理由の検討を強制する
  - カメラ側の `beginCamera` は失敗理由を区別しない既存の契約を維持した
- `MediaChannel.startScreenCapture` は `.screenCleanupPending` のときだけ `"screen capture cleanup failed, call stopScreenCapture before startScreenCapture"` を返し、それ以外の失敗理由は従来のカメラ競合メッセージを維持した
- 後始末待ちからの復旧は `stopScreenCapture()` の再試行で成立するため、新しい停止 API は追加していない
- `CHANGES.md` の `## develop` に `[FIX]` を追加した

### テスト

- `SoraTests/VideoHardMuteActorLeaseTests.swift` に次を追加した。モック・スタブは使用していない
  - `beginScreen` の各失敗理由を検証するテスト（同じ接続のカメラ・別接続のカメラ予約・画面共有の開始中 / 実行中 / 停止中・後始末待ち・revoke 済み）
  - `MediaChannel.startScreenCapture` が返すエラーメッセージの完全一致テスト
  - 後始末待ちから停止を再試行して回復できることのテスト
  - 公開 API の `MediaChannel.stopScreenCapture()` を呼んで復旧できることのテスト

### 検証結果

- `make build XCODE_SDK=iphoneos27.0`: 成功
- `make fmt-lint`: 成功
- `make lint`: 0 violations
- シミュレータテスト（iPhone 17 Pro / iOS 26.5）: 563 件実行、40 件スキップ、失敗 0
- 実機（iPad Air 第 5 世代 / iPadOS 26.7.2、実 Sora サーバ、サンプルアプリの一時的な確認コードで実施）:
  - 画面キャプチャ実行中の再開始が、従来のカメラ競合メッセージになることを確認
  - 停止失敗を Debug 限定の一時注入で再現した後、`startScreenCapture()` が `"screen capture cleanup failed, call stopScreenCapture before startScreenCapture"` を返すことを確認
  - 案内どおり `stopScreenCapture()` を再試行すると後始末待ちが解消し、`startScreenCapture()` が成功することを確認
  - 実カメラ動作中（`CameraVideoCapturer.current` が同じ sender stream）の `startScreenCapture()` が、従来のカメラ競合メッセージになることを確認
- 実 ReplayKit の停止失敗は公開 API から意図的に再現できないため、状態遷移は Debug 限定の一時注入とユニットテストで確認した。注入は確認後に削除している。サンプルアプリの確認コードは一時的なもので、リポジトリには含めていない

### 残った懸念

- `.screenOperationInProgress` / `.cancelled` のときに従来のカメラ競合メッセージを返す点は、本 issue の範囲外として維持している。案内文の見直しは別 issue で扱う
- 実 ReplayKit の停止失敗そのものは再現できないため、実機確認は一時注入による状態再現に留まる
