# CameraVideoCapturerDelegate の weak var! を weak var? に変更する

- Priority: Medium
- Created: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-camera-capturer-delegate-weak-iuo

## 目的

`CameraVideoCapturerDelegate` の `weak var cameraVideoCapturer: CameraVideoCapturer!` を `weak var cameraVideoCapturer: CameraVideoCapturer?` に変更し、weak 参照が nil になった場合の force unwrap クラッシュを防止する。

## 優先度根拠

- `weak var ... !` は Swift の危険なパターン。weak 参照は対象が解放されると自動的に nil になるが、暗黙アンラップ (`!`) のため nil アクセス時にクラッシュする
- `CameraVideoCapturer.front` / `.back` は `static let` でアプリのライフタイム中保持されるため、通常のフローではクラッシュしない
- ただし、ユーザーが `CameraVideoCapturer(device:)` で直接インスタンスを作成し、その strong 参照を失った場合にクラッシュする可能性がある
- コード品質の観点から `weak var ... !` パターンは排除すべき

## 現状

```swift
// CameraVideoCapturer.swift:453-467
private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
    weak var cameraVideoCapturer: CameraVideoCapturer!  // weak + IUO

    func capturer(_ capturer: RTCVideoCapturer, didCapture nativeFrame: RTCVideoFrame) {
        let frame = VideoFrame.native(capturer: capturer, frame: nativeFrame)
        // cameraVideoCapturer が IUO のため、nil なら暗黙アンラップでクラッシュ
        if let editedFrame = CameraVideoCapturer.handlers.onCapture?(cameraVideoCapturer, frame) {
            cameraVideoCapturer.stream?.send(videoFrame: editedFrame)
        } else {
            cameraVideoCapturer.stream?.send(videoFrame: frame)
        }
    }
}
```

`cameraVideoCapturer` が nil の場合、`CameraVideoCapturer.handlers.onCapture?(cameraVideoCapturer, frame)` の引数アクセスと、`cameraVideoCapturer.stream?.send(...)` の暗黙アンラップでクラッシュする。`.stream?.send` 自体はオプショナルチェイニングだが、`cameraVideoCapturer` 自体が IUO のため、そこで既にクラッシュする。

## 設計方針

`weak var cameraVideoCapturer: CameraVideoCapturer!` を `weak var cameraVideoCapturer: CameraVideoCapturer?` に変更し、`capturer(_:didCapture:)` 内で `guard let cameraVideoCapturer` を使用する。`guard let` でローカル変数に束縛することで、クロージャ実行中にオブジェクトが解放されることも防げる。

## 完了条件

- `CameraVideoCapturerDelegate.cameraVideoCapturer` が `weak var ... ?` で宣言されている
- `capturer(_:didCapture:)` 内で `guard let cameraVideoCapturer` による nil チェックが行われている
- `cameraVideoCapturer` が nil の場合にクラッシュせず安全にリターンする
- `onCapture` ハンドラに nil が渡されない（`guard let` の後で呼び出す）

## 後方互換

- `CameraVideoCapturerDelegate` は `private class` であり、公開 API に変更はない
- CHANGES.md には `[FIX]` として記録する
