# ScreenCapture の sample buffer 所有境界を明確にする

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-screen-capture-buffer-ownership
- Polished:

## 目的

ReplayKit callback が渡す non-Sendable な `CMSampleBuffer` を `DispatchQueue` の closure へそのままキャプチャする構造をなくす。

sample buffer と backing pixel buffer の lifetime / alias を明確にし、別 executor へ渡す値を owned かつ Sendable な表現へ限定する。

## 現状

`Sora/ScreenCapture.swift` の `ScreenCaptureController.handleSampleBuffer(sampleBuffer:sampleBufferType:error:)` は、ReplayKit から受け取った `CMSampleBuffer` を `sendVideoFrameQueue.async` の closure にキャプチャする。

同じ closure は次の non-Sendable な値も扱う。

- `CaptureContext.senderStream: MediaStream`
- `CaptureContext.videoSampleBufferTransformer`
- `VideoFrame` が保持する WebRTC frame または pixel buffer

Swift 6.3 の SDK interface では `CMSampleBuffer` が non-Sendable と診断される。`ScreenCaptureController: @unchecked Sendable` と state lock は controller の一部 state を保護するだけで、sample buffer 自体の executor 越境と backing storage の不変性を保証しない。

closure capture によって Core Foundation object の参照寿命は延長できるが、ReplayKit callback 後の buffer 再利用、pixel buffer の alias、別 queue からの安全な読み取りはコード上の型契約になっていない。

## 前提となる issue

- `0097`: capture ID を frame context へ含め、停止前の queued frame を拒否する。

本 issue は capture generation の修正後に、buffer と executor の所有境界だけを変更する refactor とする。

## 設計方針

### ReplayKit callback 内で完了させる処理

- `videoSampleBufferTransformer` は ReplayKit callback を受けた executor 上で同期的に実行する。
- `CMSampleBuffer` から送信用の owned frame または immutable snapshot への変換を callback 内で完了する。
- transformer が frame を drop した場合、別 queue へ何も enqueue しない。
- buffer 変換に失敗した場合は送信済み timestamp を更新しない。

### executor 越境

- `sendVideoFrameQueue` へ渡す値は、capture ID、timestamp、sequence、owned frame / adapter handle などの Sendable な値だけにする。
- `CMSampleBuffer`、`CVPixelBuffer`、raw `MediaStream` を unchecked box に入れて queue 境界へ渡さない。
- WebRTC object の thread affinity により raw frame を送れない場合は、`0105` の stream frame executor が受け取れる内部 handle または deep-owned pixel data へ変換する。
- deep copy の性能コストを測定し、必要性を確認せず buffer pool や複雑な cache を導入しない。

### 外部契約の確認

- ReplayKit、CoreMedia、CoreVideo の buffer lifetime と thread safety を Apple の一次資料で確認する。
- raw buffer の移送を残す場合は、保持方法、送信元による再利用禁止、読み書きの排他を一次資料で証明し、小さい internal adapter に限定する。
- 根拠を確認できないまま `@unchecked Sendable` を付与しない。

### callback

- `ScreenCaptureSettings.videoSampleBufferTransformer` が呼ばれる executor を API コメントに明記する。
- `onRuntimeError` の配送契約変更は別 issue とし、本 issue では既存の通知タイミングを維持する。

## スコープ外

- capture ID の不一致による旧 frame 送信は `0097` で扱う。
- `MediaStream` / `VideoFilter` の ordered frame processing は `0105` で扱う。
- 公開 event handler 全体の `@Sendable` 化は別 issue とする。
- raw WebRTC frame の公開 API からの撤去は `0070` と整合させる。

## テスト方針

モックやスタブは使用しない。

- 実 ReplayKit から受け取った sample buffer を transformer、変換、送信まで処理する。
- transformer が元 buffer を返す、別 buffer を返す、nil を返す各経路を実データで検証する。
- stop / restart と frame 変換を競合させ、古い buffer と frame が送られないことを確認する。
- target FPS による drop、transformer drop、変換失敗では送信 timestamp が進まないことを確認する。
- 連続キャプチャ時のメモリ使用量と frame latency を計測し、deep copy の影響を記録する。
- Thread Sanitizer を補助的に有効化し、実機でも長時間の画面共有を確認する。
- テストには、どの時点で buffer の所有表現へ変換するかを日本語コメントで明記する。

## 完了条件

- `CMSampleBuffer` が `DispatchQueue` の escaping closure に直接キャプチャされていないこと。
- transformer と sample buffer の読み取りが ReplayKit callback の executor 上で完了すること。
- queue 境界を越える値が owned かつ Sendable な表現に限定されていること。
- raw `MediaStream` または buffer を `@unchecked Sendable` box で移送していないこと。
- transformer drop と変換失敗時に送信 timestamp が更新されないこと。
- buffer lifetime と executor 契約の根拠が日本語コメントまたは API documentation に記載されていること。
- 長時間キャプチャでメモリ使用量が継続的に増加しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
