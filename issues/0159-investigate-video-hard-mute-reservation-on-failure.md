# setVideoHardMute(true) 失敗後に videoSourceCoordinator のカメラ予約が残る条件を明確にする

- Created: 2026-09-16
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/investigate-video-hard-mute-reservation-on-failure
- Polished: {YYYY-MM-DD}

## 目的

`MediaChannel.setVideoHardMute(true)` が失敗した場合に `videoSourceCoordinator.releaseCamera()` が呼ばれないため、カメラ予約が残る条件と、それが以後の操作へ与える影響を明確にする。

## 現状

- `Sora/MediaChannel.swift` の `setVideoHardMute(true)` は `VideoHardMuteActor.setMute` が成功した後にだけ `videoSourceCoordinator.releaseCamera()` を呼ぶ。失敗時は予約が解放されない。
- `Sora/CameraVideoCapturer.swift` の `VideoSourceCoordinator.beginCamera` は `state == nil` または `.camera` を許可する。一方 `beginScreen` は `state == nil` を要求する。
- このため、失敗後に `.camera` の予約が残ると `setVideoHardMute(false)` は予約を再取得できるが、`startScreenCapture` は `beginScreen` が nil を返して拒否され得る。
- `mute = true` の失敗経路は、`operationTracker.begin` の拒否、設定後の所有権不一致 (`"camera is owned by another connection"`)、カメラ停止の直前・直後の取消 (`"video hard mute operation was cancelled"`) である。どの経路で予約がどの状態に残るかは、失敗の発生位置によって異なる。
- `0136` は `videoEnabled` の復元に限定し、失敗時の `releaseCamera()` の呼び出し可否を変更しない。`0103` は `CameraVideoCaptureCoordinator` / `VideoSourceCoordinator` / `CameraCaptureOwnership` の設計変更をスコープ外にしている。

## 設計方針

- `setVideoHardMute(true)` の各失敗経路について、呼び出し前・失敗後・後続操作時の `VideoSourceCoordinator` の予約状態 (`state` / `generation`) を実装を読んで整理する。
- 予約が残ることが以後の `setVideoHardMute(false)` / `startScreenCapture` / 切断処理 (`PeerChannel.terminateSenderStream`) へ与える影響を列挙する。
- 失敗時に `releaseCamera()` を呼ぶべきか、残すべきかを判断し、予約と実際のカメラ状態が一致しない場合の扱いを含めて判断根拠を `## 解決方法` に記載する。
- 予約状態をテストから観測する方法 (`VideoSourceCoordinator.isValid`) を整理する。

## 完了条件

- `setVideoHardMute(true)` の各失敗経路で `VideoSourceCoordinator` の予約がどうなるかが一覧になっている。
- 失敗後に予約が残ることで利用者が観測できる影響が明確になっている。
- 失敗時に `releaseCamera()` を呼ぶかどうかの判断と根拠が `## 解決方法` に書かれている。
- 修正が必要と判断した場合は、その修正を本 issue に含めるか別 issue として起票するかを明記する。

## 関連 issue

- `0136`: `setVideoHardMute(true)` 失敗時の `videoEnabled` 復元。失敗時の `releaseCamera()` の扱いを本 issue へ切り出した。
- `0103`: camera state owner への集約。`VideoSourceCoordinator` の設計変更をスコープ外としている。

## 解決方法
