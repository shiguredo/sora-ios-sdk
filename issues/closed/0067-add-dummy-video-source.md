# E2E テスト用ダミー映像を流す仕組みを追加する

- Priority: Medium
- Created: 2026-06-08
- Completed: 2026-06-24
- Model: deepseek-v4-pro
- Branch: feature/add-dummy-video-source
- Polished: 2026-06-09

## 目的

E2E テストにおいて、物理カメラを使わずにダミーの映像データを生成して送信できるようにする。`MediaStream.send(videoFrame:)` は `internal` であり `@testable import Sora` 経由でテストターゲットからアクセス可能なため、SDK 本体の変更なしで実現できる。本 issue の成果物は `SoraTests/` 配下に閉じ、SDK の公開 API は一切変更しない。

## 実装内容

### SoraTests/DummyVideoCapturer.swift

- `@unchecked Sendable` クラス、8 色カラーバー（SMPTE 簡略版）を生成
- ARGB `CVPixelBuffer` → `CGContext` 描画 → `vImageConvert_ARGB8888To420Yp8_CbCr8` (BT.601, Full Range) → `RTCCVPixelBuffer` で YpCbCr 4:2:0 BiPlanar に変換
- `Timer` (`RunLoop.Mode.common`) で定期フレーム生成、`systemUptime` 基準タイムスタンプ
- 値域クランプ: 幅・高さ `max(1)` → 偶数丸め `(v+1)/2*2`、フレームレート `min(max(1, v), 120)`
- `warnedStreamNil` フラグで stream 未設定警告を初回のみに抑制
- 連続 10 回のバッファ確保失敗で自動停止
- ログは `.user("DummyVideoCapturer")` を使用（SDK 変更不要）

### SoraTests/DummyVideoCapturerTests.swift

- `start()` / `stop()` の `isRunning` 切り替え、重複呼び出し無視
- 次元クランプ・偶数丸め・フレームレート上限
- `autoreleasepool` + `weak var` による `deinit` → `timer?.invalidate()` の検証

### SoraTests/SignalingE2ETests.swift

- `buildConfiguration(role:)` 追加
- `testSendonlyDummyVideo`: `sendonly` 接続 → `senderStream` に `DummyVideoCapturer` を設定 → `getStats()` で `bytesSent` / `packetsSent` 増加を検証

### CHANGES.md

- `[ADD]` Test にダミー映像キャプチャ DummyVideoCapturer を追加する（`### misc`）

## 変更ファイル一覧

- `SoraTests/DummyVideoCapturer.swift` — 新規
- `SoraTests/DummyVideoCapturerTests.swift` — 新規
- `SoraTests/SignalingE2ETests.swift` — `testSendonlyDummyVideo` / `buildConfiguration(role:)` 追加
- `CHANGES.md` — misc に ADD エントリ追加

SDK 本体（`Sora/`）への変更はなし。
