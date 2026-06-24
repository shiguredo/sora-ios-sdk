# E2E テスト用ダミー映像を流す仕組みを追加する

- Priority: Medium
- Created: 2026-06-08
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-dummy-video-source
- Polished: 2026-06-09

## 目的

E2E テストにおいて、物理カメラを使わずにダミーの映像データを生成して送信できるようにする。`MediaStream.send(videoFrame:)` は `internal` であり `@testable import Sora` 経由でテストターゲットからアクセス可能なため、SDK 本体の変更なしで実現できる。本 issue の成果物は `SoraTests/` 配下に閉じ、SDK の公開 API は一切変更しない。

## 現状

`MediaStream.send(videoFrame:)` (`Sora/MediaStream.swift:269-283`) は `internal` であり、`@testable import Sora` によってテストターゲットからアクセス可能。`VideoFrame.native` を受け付け、任意の `RTCVideoFrame` を `RTCVideoSource` に流せる。この経路を使ってテストコードからダミー映像を送信できる。

## 設計方針

- `SoraTests/DummyVideoCapturer.swift` にテスト専用クラスとして実装する
- `MediaStream.send(videoFrame:)` を利用して一定間隔でカラーバー映像を送信する
- フレーム生成は `Timer`（`RunLoop.Mode.common`）で行う
- アクセスレベルは `internal`（デフォルト、テストターゲット内）

## ダミー映像コンテンツ

カラーバー（SMPTE 簡略版、8 色の縦縞）を実装する。

| 色 | R | G | B | A |
|---|---|---|---|---|
| 白 | 255 | 255 | 255 | 255 |
| 黄 | 255 | 255 | 0 | 255 |
| シアン | 0 | 255 | 255 | 255 |
| 緑 | 0 | 255 | 0 | 255 |
| マゼンタ | 255 | 0 | 255 | 255 |
| 赤 | 255 | 0 | 0 | 255 |
| 青 | 0 | 0 | 255 | 255 |
| 黒 | 0 | 0 | 0 | 255 |

描画は `kCVPixelFormatType_32ARGB` の `CVPixelBuffer` に `CGContext` で描画後、`vImageConvert_ARGB8888To420Yp8_CbCr8` で YpCbCr に変換する。出力先は `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`。タイムスタンプは `ProcessInfo.processInfo.systemUptime` 基準。

## `DummyVideoCapturer` の設計

```swift
// SoraTests/DummyVideoCapturer.swift (新規追加)
import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import WebRTC

@testable import Sora

final class DummyVideoCapturer: @unchecked Sendable {
    weak var stream: MediaStream?
    private(set) var isRunning: Bool = false
    private(set) var frameCount: Int = 0
    let width: Int32
    let height: Int32
    let frameRate: Int
    private var timer: Timer?
    private var consecutiveFailureCount: Int = 0
    private var startTime: TimeInterval = 0

    init(width: Int32, height: Int32, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    deinit {
        timer?.invalidate()
    }

    func start() { ... }
    func stop() { ... }
}
```

`start()` / `stop()` はべき等。`deinit` で `timer?.invalidate()` を呼び、異常系でも解放を保証する。

**値域検証**:
- 幅・高さが 0 以下: `max(1, value)` でクランプ
- 幅・高さが奇数: `(value + 1) / 2 * 2` で次の偶数に切り上げ（YUV 4:2:0 は偶数必須）
- フレームレート: `min(max(1, frameRate), 120)` でクランプ

**連続失敗カウンタ**: `CVPixelBuffer` 確保失敗時にインクリメント、成功時にリセット。連続 10 回到達で `stop()`。`vImageConvert` エラー時はフレームスキップのみ（カウンタ変動なし）。フレーム送信成功時は `frameCount` をインクリメントする。

## E2E テストへの組み込み

`SignalingE2ETests.swift` に `sendonly` のテストケースを追加する。`onConnect` コールバックで取得した `MediaChannel` の `senderStream` に `DummyVideoCapturer.stream` を設定し、ダミー映像の送信を開始する。

```swift
func testSendonlyDummyVideo() throws {
    let config = try buildConfiguration(role: .sendonly)
    let expectation = self.expectation(description: "sendonly でダミー映像を送信できること")
    var capturer: DummyVideoCapturer?

    _ = sora.connect(configuration: config) { mediaChannel, error in
        if let error {
            XCTFail("接続に失敗した: \(error)")
            expectation.fulfill()
            return
        }
        guard let channel = mediaChannel, let stream = channel.senderStream else {
            XCTFail("senderStream が nil")
            expectation.fulfill()
            return
        }
        capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
        capturer?.stream = stream
        capturer?.start()
        // 2 秒間送信後、getStats() で outbound video の送信実績を確認する
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            channel.getStats { result in
                guard case .success(let stats) = result else {
                    XCTFail("getStats に失敗した")
                    expectation.fulfill()
                    return
                }
                let videoOutbound = stats.entries.first {
                    $0.type == "outbound-rtp" && ($0.id.contains("video") || $0.id.contains("Video"))
                }
                XCTAssertNotNil(videoOutbound, "outbound video stats が存在すること")
                let bytesSent = videoOutbound?.values["bytesSent"] as? NSNumber
                let packetsSent = videoOutbound?.values["packetsSent"] as? NSNumber
                XCTAssertNotNil(bytesSent, "bytesSent が存在すること")
                XCTAssertNotNil(packetsSent, "packetsSent が存在すること")
                XCTAssertGreaterThan(bytesSent?.intValue ?? 0, 0, "bytesSent が増加していること")
                XCTAssertGreaterThan(packetsSent?.intValue ?? 0, 0, "packetsSent が増加していること")
                expectation.fulfill()
            }
        }
    }

    wait(for: [expectation], timeout: 35)
    capturer?.stop()
    // 切断
    if let channel = sora.mediaChannels.first {
        let disconnectExpectation = self.expectation(description: "切断")
        channel.handlers.onDisconnect = { event in
            if case .ok(let code, _) = event {
                XCTAssertEqual(code, 1000)
            }
            disconnectExpectation.fulfill()
        }
        channel.disconnect(error: nil)
        wait(for: [disconnectExpectation], timeout: 10)
    }
}
```

`buildConfiguration(role:)` は既存の `buildConfiguration()` に `role` パラメータを追加したオーバーロードとする。

## テスト

テストファイル: `SoraTests/DummyVideoCapturerTests.swift`

- `start()`/`stop()` で `isRunning` が正しく切り替わること
- `start()` 重複呼び出しが無視されること
- `stop()` 重複呼び出しが無視されること
- `CVPixelBuffer` のサイズが設定値と一致すること
- カラーバーの特定位置のピクセル値が期待する色であること。Y/Cb/Cr 値は BT.601 full range 理論値であり、実機での実測値をもとに許容誤差を設定する
- `stream` が nil で `start()` を呼んだ場合に警告が出て `isRunning` が `false` のままであること
- `stop()` 未呼び出しでも `deinit` で `Timer` が解放されること:
  - `autoreleasepool` 内で `DummyVideoCapturer` を生成・`start()` し、外部に `weak var weakCapturer = capturer` で弱参照を保持する
  - `stop()` を呼ばずに `autoreleasepool` を抜ける
  - `XCTAssertNil(weakCapturer)` で `deinit` が実行されたことを確認する。これにより `deinit` → `timer?.invalidate()` の経路が通ったことを間接的に検証する
  - `RunLoop.current.run(until: Date().addingTimeInterval(0.1))` で RunLoop を回し、無効化された Timer が再発火しない（クラッシュしない）ことを確認する

## 変更ファイル一覧

- `SoraTests/DummyVideoCapturer.swift` — 新規追加
- `SoraTests/DummyVideoCapturerTests.swift` — 新規追加
- `SoraTests/SignalingE2ETests.swift` — `testSendonlyDummyVideo` の追加、`buildConfiguration(role:)` の追加

SDK 本体（`Sora/`）への変更は一切行わない。

## 完了条件

- [ ] `SoraTests/DummyVideoCapturer.swift` が追加され、カラーバー映像フレームを生成できること
- [ ] `DummyVideoCapturerTests` の全テストがパスすること
- [ ] `testSendonlyDummyVideo` が追加され、`sendonly` で Sora に接続してダミー映像が送信できること
- [ ] `stop()` で `Timer` が停止し、`deinit` でも解放が保証されること
- [ ] 既存の単体テストが変更前後で全て成功すること
