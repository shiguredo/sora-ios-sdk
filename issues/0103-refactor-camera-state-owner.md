# カメラ状態を接続 lease 付き owner へ集約する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-camera-state-owner
- Polished:

## 目的

`CameraVideoCapturer` の static state、capturer state、stream、handler をカメラ専用の 1 つの owner へ集約する。

カメラ操作を接続 lease と operation generation に紐付け、`CameraVideoCapturer: @unchecked Sendable` と `nonisolated(unsafe)` な共有状態に依存しない Swift 6 対応の内部構造へ移行する。

## 現状

`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturer` は class 全体が `@unchecked Sendable` で、次の状態を保持する。

- 再利用される `front` / `back` capturer
- writable な static `current`
- writable な static `handlers`
- `stream`
- `isRunning`
- `format` と `frameRate`
- `RTCCameraVideoCapturer` と delegate
- `AVCaptureDevice`

start、stop、restart、change、flip の completion と `CameraVideoCapturerDelegate.capturer(_:didCapture:)` は libwebrtc / AVFoundation 側の callback thread から到達する。一方、公開 API は利用者の任意の executor から呼び出せる。

`current` と handlers は `nonisolated(unsafe)` であり、カメラ queue 上だけでアクセスするという前提をコンパイラも実装も強制していない。

`Sora/VideoMute.swift` は `SoraDispatcher.async(on: .camera)` を使って一部のカメラ操作を queue へ送るが、非 Sendable な `MediaStream` を `SenderStreamBox` で actor 境界へ渡している。直接呼べる `CameraVideoCapturer` の公開 API はこの経路を迂回できる。

## 前提となる issue

- `0098`: 複数接続間で hard mute の capturer が混線するバグを lease で修正する。
- `0099`: flip の stream 設定順と rollback を修正する。

本 issue は上記で確定した挙動を維持したまま、状態所有を整理する refactor とする。

## 設計方針

### CameraCaptureOwner

- カメラ操作を所有する internal の actor または serial executor 型を導入する。
- active capturer、device、format、frame rate、stream handle、phase、operation generation、connection lease を owner が保持する。
- start、stop、restart、change、flip、hard mute、disconnect を owner の command として実行する。
- 各非同期 callback の復帰時に operation generation と lease を再確認し、古い callback が新しい状態を上書きしないようにする。

### WebRTC / AVFoundation 境界

- `RTCCameraVideoCapturer` と delegate は owner が指定した camera executor 上でのみ操作する。
- delegate callback では frame と capturer identity を取得し、stream ごとの ordered frame ingress へ渡す。
- raw capturer を actor 間で `@unchecked Sendable` box に入れて受け渡さない。
- libwebrtc queue の thread affinity を一次資料または binary framework の実装で確認し、owner の不変条件として日本語コメントに残す。

### static state と公開 API

- `current` は owner が公開する immutable snapshot または同期 accessor から取得する。
- `front` / `back` は共有 mutable capturer ではなく、device descriptor または owner 内の resource として扱う。
- handlers は owner 上で snapshot 化し、設定変更と callback 実行が競合しないようにする。
- 既存の同期 / callback ベース公開 API は compatibility wrapper として維持する。
- 新しい async API や `@Sendable` handler の公開は別 issue とし、本 issue で既存利用者へ新しい isolation 制約を強制しない。

### callback

- completion と利用者 handler は camera state を確定してから owner の critical section 外で呼ぶ。
- start / stop completion の呼び出し回数を operation generation ごとに 1 回へ限定する。
- callback から別のカメラ操作が再入しても deadlock しないようにする。

## スコープ外

- MainActor renderer API は `0027` で扱う。
- Media Processors の公開 API は `0057` で扱う。
- raw WebRTC 型を公開 API から除去する作業は `0070` と整合させる。
- `SoraDispatcher` の公開 API 廃止は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- front / back の実カメラを使い、start、stop、restart、change、flip を連続・並行実行する。
- 2 つの実 `MediaChannel` で connection lease を交差させ、別接続の操作が拒否されることを確認する。
- callback 内から次のカメラ操作を開始し、deadlock と二重 completion がないことを確認する。
- stop または flip 中に disconnect し、古い callback が `current`、stream、`isRunning` を復元しないことを確認する。
- Thread Sanitizer を補助的に有効化する。
- 最低 iOS 14 世代と現行 iOS の実機で検証する。
- テストには、`await` または callback 復帰後に generation を再確認する理由を日本語コメントで明記する。

## 完了条件

- カメラの mutable state の所有者が 1 つであること。
- active capturer、stream、phase、operation generation、connection lease が owner 内で一貫して管理されること。
- `CameraVideoCapturer.current` と handlers から `nonisolated(unsafe)` が除去されていること。
- `CameraVideoCapturer` 全体の `@unchecked Sendable` が不要になるか、安全性を説明できる小さい adapter だけに限定されていること。
- raw `MediaStream` / capturer を unchecked box で owner 間へ移送していないこと。
- 古い callback が新しいカメラ状態を上書きしないこと。
- 既存公開 API の source compatibility が維持されること。
- `0098`、`0099` の回帰テストを含む全テストが成功すること。

## 解決方法
