# VideoHardMuteActor の storedCapturer をミュート解除成功時にクリアする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-videohardmuteactor-stored-capturer-clear
- Polished: 2026-06-06

## 目的

`VideoHardMuteActor` の `storedCapturer` が、ミュート解除成功後も `nil` に戻されず保持され続ける。状態遷移の意図が不明瞭になり、不要な参照保持と将来の改修時の不整合リスクを招くため、解除成功時にクリアする。

## 優先度根拠

- 状態管理の不具合であり、古い参照を前提とした不整合や保守性低下を将来招き得る。バグとして扱うため Medium とする。
- 即時のクラッシュやデータ破壊ではないため High ではない。

## 現状

`VideoHardMuteActor` は、ミュート有効化時に停止した capturer を解除時の再開用に `storedCapturer` として保持する（`Sora/VideoMute.swift:36`）。

ミュート解除時（`mute = false`）の処理フローは以下の 3 経路があるが、いずれの成功経路でも `storedCapturer` をクリアしていない。

**経路 A（既に再開済み）**: 行 72-73

```swift
let currentCapturer = await currentCameraVideoCapturer()
if currentCapturer != nil { return }  // ← storedCapturer が残り続ける
```

外部要因でキャプチャが既に再開されている場合に到達する。`storedCapturer` が残ったままになる。

**経路 B（restart）**: 行 75-77

```swift
if let capturerForRestart = storedCapturer {
  try await restartCameraVideoCapture(capturerForRestart, senderStream: senderStream)
  return  // ← storedCapturer が残り続ける
}
```

**経路 C（start）**: 行 78-79

```swift
try await startCameraVideoCapture(cameraSettings: cameraSettings, senderStream: senderStream)
// ← storedCapturer が残り続ける
```

## 設計方針

**`storedCapturer` のクリア対象経路**:

以下のすべての成功経路で `storedCapturer = nil` を設定する。

| 経路 | クリア位置 |
|------|-----------|
| A（既に再開済み）| 行 73 の `return` 前 |
| B（restart 成功）| 行 76 の `return` 前 |
| C（start 成功）| 行 79 の後（防御的クリア。この時点で `storedCapturer` は元から `nil`） |

変更前の `Sora/VideoMute.swift:72-79` を以下のコードに置き換える（変更後は行数が増える）。

```swift
// ミュートを無効化します
let currentCapturer = await currentCameraVideoCapturer()
if currentCapturer != nil {
  // 既にキャプチャが起動済みのため解除成功とみなし、不要な参照をクリアします
  storedCapturer = nil
  return
}
if let capturerForRestart = storedCapturer {
  try await restartCameraVideoCapture(capturerForRestart, senderStream: senderStream)
  // restart 成功後にクリアします（throw されなかった場合のみここに到達）
  storedCapturer = nil
  return
}
try await startCameraVideoCapture(cameraSettings: cameraSettings, senderStream: senderStream)
// start 成功後のクリア（この時点で storedCapturer は元から nil だが防御的に設定）
storedCapturer = nil
```

**解除失敗時の挙動**:

`restartCameraVideoCapture` が throw した場合、`storedCapturer` はクリアしない。次回の `mute = false` 呼び出しで同じ capturer を使って再試行できる。ただし capturer 自体が壊れている（ハードウェア異常等）場合は再試行しても失敗し続けるため、`mute = true` が呼ばれて `storedCapturer` が上書きされるまで参照が残る。この挙動は意図的であり、コメントで明記する。

**後方互換性**: 公開 API の `setVideoHardMute` の外形的な挙動は変えない。内部状態のクリアのみ。

## テスト方針

モック・スタブは使用しない。実機または Simulator で以下を手動確認すること。

- `mute = true` → `mute = false`（restart 経路）の順で呼び出し後、映像が再開されること。
- `mute = true` → `mute = false`（start 経路: `storedCapturer == nil` の状態）の順で映像が起動されること。
- 連続した `mute true/false` の繰り返し（3 回以上）で毎回期待どおり再開できること。
- 解除後に再度 `mute = true` を呼び出しても正常にミュートできること（`storedCapturer` の二重設定が起きないこと）。

## 完了条件

- `mute = true` で停止後に `storedCapturer` が設定されること。
- `mute = false` で解除成功後（経路 A・B・C すべて）に `storedCapturer == nil` になること。
- 解除失敗（`restartCameraVideoCapture` が throw）時は `storedCapturer` が保持されること。
- 連続した `mute true/false` の切り替えで、期待どおり再開できること。
- 既存の `setVideoHardMute` の挙動を壊さないこと。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [FIX] VideoHardMuteActor のミュート解除成功後に storedCapturer をクリアする
    - @voluntas
  ```

## 解決方法
