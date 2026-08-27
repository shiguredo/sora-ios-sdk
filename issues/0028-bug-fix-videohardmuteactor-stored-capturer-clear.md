# VideoHardMuteActor の storedCapturer をミュート解除成功時にクリアする

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-videohardmuteactor-stored-capturer-clear
- Polished: 2026-07-27
- Updated: 2026-08-27

## 目的

`VideoHardMuteActor` の `storedCapturer` が、ミュート解除成功後も `nil` に戻されず保持され続ける。状態遷移の意図が不明瞭になり、不要な参照保持と将来の改修時の不整合リスクを招くため、解除成功時にクリアする。

## 優先度根拠

- 状態管理の不具合であり、古い参照を前提とした不整合や保守性低下を将来招き得る。バグとして扱うため Medium とする。
- 即時のクラッシュやデータ破壊ではないため High ではない。

## 現状

`Sora/VideoMute.swift` の `VideoHardMuteActor` は、ミュート有効化時に停止した capturer を解除時の再開用に `storedCapturer` として保持する。

ミュート解除時（`mute = false`）の処理フローは以下の 3 経路があるが、いずれの成功経路でも `storedCapturer` をクリアしていない。

- 経路 A: `currentCameraVideoCapturer()` が non-nil のため、既に再開済みとして return する。
- 経路 B: `storedCapturer` を `restartCameraVideoCapture` で再開して return する。
- 経路 C: 保存状態がないため `startCameraVideoCapture` で新規に開始する。

ただし `MediaChannel.videoHardMuteActor` は全接続共有の `static let` であり、`currentCameraVideoCapturer()` は global な `CameraVideoCapturer.current` を返す。経路 A の non-nil は、同じ接続の capturer が再開済みであることを意味しない。

## 前提となる issue

- `0098`: 保存する capturer を connection lease と operation generation に紐付け、別接続の active capturer と保存状態を区別できるようにする。

`0098` より先に共有 `storedCapturer` を無条件で nil にすると、別接続がカメラを起動しただけで元接続の保存状態を破棄する可能性があるため、本 issue は `0098` の後に実施する。

## 設計方針

`0098` で導入する connection lease ごとの保存状態について、同一 lease の unmute が成功した場合だけ保存状態をクリアする。

- 経路 A は、active capturer が同じ lease、operation generation、sender stream に属すると確認できた場合だけ成功とする。
- 経路 B は、同じ lease が所有する capturer の restart 成功後にクリアする。
- 経路 C は、新規 start 成功後に同じ lease の保存状態が残っていないことを保証する。
- 別接続の active capturer を観測した場合は元接続の保存状態をクリアせず、`0098` で定める競合エラーとして扱う。
- disconnect または logical connection ID の変更後は、古い lease の保存状態を再利用しない。

**解除失敗時の挙動**:

`restartCameraVideoCapture` が throw した場合は、同じ connection lease が有効な間だけ保存状態を保持し、同じ lease の再試行に利用する。disconnect、generation 変更、別 lease からの操作では利用しない。再試行不能なエラーで保存状態を破棄するかは実装時にエラー分類を確認し、判断根拠を `## 解決方法` に記載する。

**後方互換性**: 公開 API の `setVideoHardMute` の外形的な挙動は変えない。内部状態のクリアのみ。

## テスト方針

モック・スタブは使用しない。接続済みの sender role、映像有効、`cameraSettings.isEnabled == true`、sender stream と video track が存在する条件で、実カメラを使って確認する。

- `mute = true` → `mute = false`（restart 経路）の順で呼び出し後、映像が再開されること。
- `initialCameraEnabled = false` で接続し、最初に `mute = false` を呼ぶ start 経路で映像が起動すること。
- 同一 lease の capturer を再開済みにしてから `mute = false` を呼び、経路 A で保存状態がクリアされること。
- 別 `MediaChannel` が camera を起動した状態では、元接続の保存状態がクリアされないこと。
- 連続した `mute true/false` の繰り返し（3 回以上）で毎回期待どおり再開できること。
- 解除後に再度 `mute = true` を呼び出しても正常にミュートできること（`storedCapturer` の二重設定が起きないこと）。
- restart 失敗後の再試行は同じ connection lease だけが実行できること。

## 完了条件

- `mute = true` で停止後に `storedCapturer` が設定されること。
- `mute = false` で同一 connection lease の解除成功後（経路 A・B・C すべて）に、その lease の保存状態がクリアされること。
- 別接続の active capturer を観測しても、元接続の保存状態をクリアしないこと。
- 解除失敗時の保存状態が同じ connection lease 以外から利用されないこと。
- disconnect と connection generation 変更時に古い保存状態が残らないこと。
- 連続した `mute true/false` の切り替えで、期待どおり再開できること。
- 既存の `setVideoHardMute` の挙動を壊さないこと。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [FIX] VideoHardMuteActor のミュート解除成功後に storedCapturer をクリアする
    - @voluntas
  ```

## 解決方法
