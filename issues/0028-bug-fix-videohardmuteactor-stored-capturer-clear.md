# VideoHardMuteActor の storedCapturer をミュート解除成功時にクリアする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-videohardmuteactor-stored-capturer-clear

## 目的

`VideoHardMuteActor` の `storedCapturer` が、ミュート解除成功後も `nil` に戻されず保持され続ける。状態遷移の意図が不明瞭になり、不要な参照保持と将来の改修時の不整合リスクを招くため、解除成功時にクリアする。

## 優先度根拠

- 状態管理の不具合であり、古い参照を前提とした不整合や保守性低下を将来招き得る。バグとして扱うため Medium とする。
- 即時のクラッシュやデータ破壊ではないため High ではない。

## 現状

`VideoHardMuteActor` は、ミュート有効化時に停止した capturer を解除時の再開用に `storedCapturer` として保持する。

```swift
// Sora/VideoMute.swift:36
// ハードミュートで stop したキャプチャを解除時に restart するための保持キャプチャラー
private var storedCapturer: CameraVideoCapturer?
```

ミュート有効化時、停止した capturer を `storedCapturer` に設定する。

```swift
// Sora/VideoMute.swift:64
try await stopCameraVideoCapture(currentCapturer)
// ミュート無効化する際にキャプチャラーを使用するため保持しておきます
storedCapturer = currentCapturer
return
```

ミュート解除時、`storedCapturer` があれば restart し、無ければ start するが、いずれの解除成功経路でも `storedCapturer` をクリアしていない。

```swift
// Sora/VideoMute.swift:74
// 前回停止時のキャプチャラーが保持できていれば restart、なければ start します
if let capturerForRestart = storedCapturer {
  try await restartCameraVideoCapture(capturerForRestart, senderStream: senderStream)
  return
}
try await startCameraVideoCapture(cameraSettings: cameraSettings, senderStream: senderStream)
```

このため、解除成功後も不要な参照が残り続ける。

## 設計方針

- ミュート解除が成功したら `storedCapturer` を `nil` に戻す。ミュート有効化時に停止した capturer のみ、次回解除まで保持する状態にする。
- restart 成功後と start 成功後の双方で `storedCapturer = nil` を設定し、防御的に整合を保つ。
- `restartCameraVideoCapture` / `startCameraVideoCapture` は失敗時に throw するため、`storedCapturer = nil` は throw されなかった成功後にのみ実行されるよう配置する。解除失敗時は保持を継続し、次回解除で再試行できるようにする。この仕様をコメントで明記する。
- 後方互換性: 公開 API の `setVideoHardMute` の挙動は変えない。内部状態のクリアのみで、ミュート／解除の外形的な動作は維持する。

## 完了条件

- `mute = true` で停止後に `storedCapturer` が設定されること。
- `mute = false` で解除成功後に `storedCapturer == nil` になること。
- 連続した `mute true/false` の切り替えで、期待どおり再開できること。
- 既存の `setVideoHardMute` の挙動を壊さないこと。
- `CHANGES.md` の `## develop` セクションに `[FIX]` エントリと担当者行を追記すること。

## 解決方法
