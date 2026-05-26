# PeerChannel.initializeCameraVideoCapture の CameraVideoCapturer.current! を if let に変更する

- Priority: Low
- Created: 2026-05-25
- Completed: 2026-05-26
- Model: Opus 4.7
- Branch: feature/fix-camera-current-toctou-force-unwrap

## 目的

`PeerChannel.initializeCameraVideoCapture` 内の `CameraVideoCapturer.current != nil, CameraVideoCapturer.current!.isRunning` パターンを `if let` に変更し、force unwrap によるクラッシュリスクを排除する。ローカル変数への束縛により TOCTOU パターンも改善するが、`isRunning` の論理的な TOCTOU を完全に解決するには同期機構が必要であり、それは本 issue のスコープ外とする。

## 優先度根拠

- `CameraVideoCapturer.current` は `nonisolated(unsafe) static var` であり、別スレッドから変更される可能性がある
- nil チェック (`!= nil`) と force unwrap (`!`) の間に別スレッドで `stop()` が実行されると nil になりクラッシュする
- 同ファイルの `terminateSenderStream` (L652-664) では `if let current = CameraVideoCapturer.current` パターンが使われており、同ファイル内で一貫性がない
- 防御的プログラミングとして force unwrap を排除し、同ファイル内のスタイルと統一する

## 現状

```swift
// PeerChannel.swift:612-648
if CameraVideoCapturer.current != nil, CameraVideoCapturer.current!.isRunning {
    // CameraVideoCapturer.current を停止してから capturer を start する
    CameraVideoCapturer.current!.stop { (error: Error?) in
        guard error == nil else {
            Logger.debug(
                type: .peerChannel,
                message: "CameraVideoCapturer.stop failed =>  \(error!)")
            return
        }

        capturer.start(format: format, frameRate: frameRate) { error in
            guard error == nil else {
                Logger.debug(
                    type: .peerChannel,
                    message: "CameraVideoCapturer.start failed =>  \(error!)")
                return
            }
            Logger.debug(
                type: .peerChannel,
                message: "set CameraVideoCapturer to sender stream")
            capturer.stream = stream
        }
    }
} else {
    capturer.start(format: format, frameRate: frameRate) { error in
        guard error == nil else {
            Logger.debug(
                type: .peerChannel,
                message: "CameraVideoCapturer.start failed =>  \(error!)")
            return
        }
        Logger.debug(
            type: .peerChannel,
            message: "set CameraVideoCapturer to sender stream")
        capturer.stream = stream
    }
}
```

`CameraVideoCapturer.current` に 3 回アクセスしており、各アクセスの間に値が変わる可能性がある。

対比として、同ファイルの安全なパターン（`terminateSenderStream` は `isRunning` チェックなしで `if let` を使用）:

```swift
// PeerChannel.swift:655
if let current = CameraVideoCapturer.current {
    current.stop { error in
```

## 設計方針

`if let current = CameraVideoCapturer.current, current.isRunning` パターンに変更する。`guard let` ではなく `if let` を使用する理由は、else 節で `capturer.start(...)` を実行する必要があるため（`guard let` の else は `return` 等でスコープを脱出する必要がある）。

## 完了条件

- `CameraVideoCapturer.current` への force unwrap が除去されている
- `if let` で安全にアクセスされ、ローカル変数に束縛されている
- else 節の既存動作（直接 `capturer.start`）が維持されている

## 後方互換

- `initializeCameraVideoCapture` は `private` メソッドであり、公開 API に変更はない
- CHANGES.md には `[FIX]` として記録する

## 解決方法

`PeerChannel.swift` の `initializeCameraVideoCapture` メソッド内で以下の修正を行った:

1. `if CameraVideoCapturer.current != nil, CameraVideoCapturer.current!.isRunning` を `if let current = CameraVideoCapturer.current, current.isRunning` に変更し、force unwrap を 2 箇所除去した
2. `CameraVideoCapturer.current!.stop` を `current.stop` に変更し、ローカル変数経由で安全にアクセスするようにした
3. 元のコメント「CameraVideoCapturer.current を停止してから capturer を start する」を維持した
4. これにより、同ファイル `terminateSenderStream` (L687) の `if let` パターンとスタイルが統一された
