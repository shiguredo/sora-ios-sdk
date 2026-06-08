# ダミー映像を流す仕組みを追加する

- Priority: Medium
- Created: 2026-06-08
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-dummy-video-source
- Polished: 2026-06-09

## 目的

Sora iOS SDK を利用したアプリケーションのテストやデモにおいて、物理的なカメラを使用せずにダミーの映像データを生成して送信できる仕組みを提供する。これにより、以下の利点が得られる：

- シミュレーター上での動作確認が容易になる（シミュレーターには物理カメラがないため）
- CI/CD 環境での自動テストが可能になる
- デモアプリでの安定した映像出力が可能になる
- ネットワークのみのテスト（純粋な WebRTC 接続テスト）が可能になる

ダミー音声については本 issue のスコープ外とし、別 issue で対応する。

## 現状

現在の Sora iOS SDK にはダミー映像ソースを流す仕組みが存在しない。

### 映像入力の現状

映像フレームは以下のいずれかの方法で送信される：

1. **`CameraVideoCapturer`** (`Sora/CameraVideoCapturer.swift`) — `AVCaptureDevice` から物理カメラのフレームを取得し、`RTCVideoCapturerDelegate.capturer(_:didCapture:)` を通じて `MediaStream.send(videoFrame:)` に流す
2. **`ScreenCaptureController`** (`Sora/ScreenCapture.swift`) — `ReplayKit.RPScreenRecorder` から画面キャプチャフレームを取得し、同様に `MediaStream.send(videoFrame:)` に流す
3. **手動フレーム投入** — ユーザーが自前で `RTCVideoFrame` を構築し、`MediaStream.send(videoFrame:)` を直接呼び出す

`MediaStream.send(videoFrame:)` (`Sora/MediaStream.swift:269-283`) は以下のように動作する：

```swift
func send(videoFrame: VideoFrame?) {
    if let frame = videoFrame {
        let frame = videoFilter?.filter(videoFrame: frame) ?? frame
        switch frame {
        case .native(let capturer, let nativeFrame):
            nativeVideoSource?.capturer(
                capturer ?? BasicMediaStream.dummyCapturer,
                didCapture: nativeFrame)
        }
    }
}
```

この `dummyCapturer` パターンはすでに存在しており、実際の `RTCVideoCapturer` を必要とせずに `RTCVideoSource` にフレームを流せることを示している。

## 設計方針

### 全体方針

- `Configuration` にダミー映像に関する設定を追加する
- ダミー映像は `MediaStream.send(videoFrame:)` を利用して、一定間隔で生成した `RTCVideoFrame` を送信する
- ダミー映像の生成は `Timer`（`RunLoop.Mode.common`）を用いて一定フレームレートで行う
- ダミー映像の内容はカラーバーとする（視覚的に認識しやすい）
- ダミー映像はパブリッシャー（`role` が `sendonly` または `sendrecv`）の場合にのみ有効
- `DummyVideoCapturer` クラスは `CameraVideoCapturer` と同様に `@unchecked Sendable` とする（`Timer` を保持するため）

### issue 0053 との関係

`0053-add-camera-alternative-input-sources` では映像入力ソースを抽象化するプロトコル（`VideoSource` など）を定義する方針が示されている。`DummyVideoCapturer` はその抽象化とは独立した単独クラスとして導入する。`0053` 実装後は `DummyVideoCapturer` を抽象化に適合させるリファクタリングが必要になる可能性がある。

### `dummyVideoEnabled` と既存設定の関係

`Configuration.dummyVideoEnabled` は、`videoEnabled` や `cameraSettings` と以下の関係を持つ：

| `role` | `dummyVideoEnabled` | `videoEnabled` | 動作 |
|---|---|---|---|
| `sendonly`/`sendrecv` | `false` | 任意 | 既存動作（カメラ起動/非起動） |
| `sendonly`/`sendrecv` | `true` | `true` | `CameraVideoCapturer` を起動せず、`DummyVideoCapturer` を起動する。`cameraSettings.isEnabled` と `initialCameraEnabled` の値に関わらずカメラは起動しない |
| `sendonly`/`sendrecv` | `true` | `false` | 映像トラックは生成されないためダミー映像も無効（警告ログ出力） |
| `recvonly` | 任意 | 任意 | `initializeSenderStream()` は呼ばれないためダミー映像は無効（設定の効果なし） |

警告ログの出力場所:

- 「`dummyVideoEnabled == true` && `videoEnabled == false`」の場合: `initializeSenderStream()` 内で `videoTrackId == nil` と `dummyVideoEnabled == true` を判定して警告ログを出力する
- 「`dummyVideoEnabled == true` && `role == .recvonly`」の場合: `initializeSenderStream()` が呼ばれないためログは出力しない

### Configuration 追加

```swift
// Configuration.swift に追加
public struct Configuration {
    /// ダミー映像を有効にするかどうか。
    /// true の場合、物理カメラの代わりにダミー映像を生成して送信します。
    /// シミュレーターや CI 環境でのテスト用です。
    /// この設定は接続確立時にのみ有効で、接続中の変更は反映されません。
    public var dummyVideoEnabled: Bool = false

    /// ダミー映像の解像度（幅）
    public var dummyVideoWidth: Int32 = 640

    /// ダミー映像の解像度（高さ）
    public var dummyVideoHeight: Int32 = 480

    /// ダミー映像のフレームレート
    public var dummyVideoFrameRate: Int = 30
}
```

`dummyVideoEnabled` は接続確立時に参照される値であり、接続中に変更しても効果はない。

### ダミー映像コンテンツ

本 issue ではカラーバーのみを実装する。カラーバーは左から右へ以下の 8 色の縦縞とする（SMPTE カラーバーを簡略化したもの）：

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

カラーバー描画の実装方法：

1. `kCVPixelFormatType_32ARGB` の `CVPixelBuffer` を毎フレーム確保
2. `CVPixelBufferLockBaseAddress` でロック
3. `CGContext` を作成し `CoreGraphics` でカラーバーを描画:

```swift
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
guard let context = CGContext(
    data: baseAddress,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo.rawValue
) else {
    CVPixelBufferUnlockBaseAddress(argbBuffer, .readOnly)
    return nil
}
// 8 色の縦縞を描画。width が 8 で割り切れない場合、余りピクセルは最後（黒）のストライプに追加する
let stripeWidth = Int(width) / 8
let remainder = Int(width) % 8
for i in 0..<8 {
    let color = colorBarColors[i]
    context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
    let x = i * stripeWidth
    let w = stripeWidth + (i == 7 ? remainder : 0)
    context.fill(CGRect(x: x, y: 0, width: w, height: Int(height)))
}
context.flush()
CVPixelBufferUnlockBaseAddress(argbBuffer, [])
```

4. `vImageConvert_ARGB8888To420Yp8_CbCr8` で YpCbCr に変換する。出力先は `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` を使用する（`vImageConvert_ARGB8888To420Yp8_CbCr8` のデフォルト出力は Full Range であるため）。`CGBitmapContextCreate` は `420YpCbCr8BiPlanar` を直接サポートしないため、ARGB → YpCbCr の 2 段階変換が必要:

```swift
let yPlane = CVPixelBufferGetBaseAddressOfPlane(yuvBuffer, 0)!
let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(yuvBuffer, 1)!
var srcBuffer = vImage_Buffer(
    data: srcBaseAddress,
    height: vImagePixelCount(height),
    width: vImagePixelCount(width),
    rowBytes: srcBytesPerRow)
var dstYPlane = vImage_Buffer(
    data: yPlane,
    height: vImagePixelCount(height),
    width: vImagePixelCount(width),
    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(yuvBuffer, 0))
var dstCbCrPlane = vImage_Buffer(
    data: cbcrPlane,
    height: vImagePixelCount(height / 2),
    width: vImagePixelCount(width / 2),
    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(yuvBuffer, 1))
let error = vImageConvert_ARGB8888To420Yp8_CbCr8(
    &srcBuffer, &dstYPlane, &dstCbCrPlane,
    nil, vImage_Flags(kvImageNoFlags))
guard error == kvImageNoError else {
    Logger.error(type: .dummyVideoCapturer, message: "vImageConvert failed, frame skipped")
    return nil
}
```

`timeStampNs` には `ProcessInfo.processInfo.systemUptime` を基準とした経過ナノ秒を使用する。`ScreenCaptureController` （`ScreenCapture.swift:346`）と同様の方式であり、`mach_absolute_time` と異なりスリープ中も不連続にならない。`start()` 呼び出し時点の `systemUptime` を `startTime` として保持し、各フレームで差分をナノ秒に変換する。

### `DummyVideoCapturer` の設計

アクセスレベルは `internal`（デフォルト）。`CameraVideoCapturer` および `ScreenCaptureController` と同様に `@unchecked Sendable` とする。

必要な import: `Foundation`, `WebRTC`, `Accelerate`, `CoreGraphics`, `CoreVideo`

```swift
// Sora/DummyVideoCapturer.swift (新規追加)
final class DummyVideoCapturer: @unchecked Sendable {
    /// 出力先のストリーム。
    /// weak とする: PeerChannel → DummyVideoCapturer → stream(weak) → MediaStream であり、
    /// CameraVideoCapturer と異なり静的プロパティでの保持はないため循環参照を防ぐ。
    weak var stream: MediaStream?

    /// 起動中かどうか
    private(set) var isRunning: Bool = false

    /// フレーム生成用の設定
    let width: Int32
    let height: Int32
    let frameRate: Int

    /// フレーム生成用の Timer
    private var timer: Timer?

    /// 連続失敗カウンタ（Timer コールバックはメインスレッドのみで動作するためスレッド安全性の問題はない）
    private var consecutiveFailureCount: Int = 0

    /// タイムスタンプの基準時刻（start() 呼び出し時点のシステム起動時刻）
    private var startTime: TimeInterval = 0

    deinit {
        timer?.invalidate()
    }

    init(width: Int32, height: Int32, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// フレーム生成を開始します。
    /// 重複呼び出しは無視します（警告ログ）。
    func start()

    /// フレーム生成を停止します。
    /// 重複呼び出しは無視します（警告ログ）。
    func stop()
}
```

`start()` と `stop()` はべき等とし、重複呼び出し時は警告ログを出力する。`deinit` で `timer?.invalidate()` を呼ぶことで、`stop()` が呼ばれない異常系でも RunLoop からの解放を保証する。

`start()` の疑似コード:

```swift
func start() {
    guard !isRunning else {
        Logger.warn(type: .dummyVideoCapturer, message: "already running")
        return
    }
    guard stream != nil else {
        Logger.warn(type: .dummyVideoCapturer, message: "stream not set, start aborted")
        return
    }
    startTime = ProcessInfo.processInfo.systemUptime
    consecutiveFailureCount = 0
    isRunning = true
    let interval = 1.0 / Double(frameRate)
    timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
        self?.onTimer()
    }
    RunLoop.main.add(timer!, forMode: .common)
}
```

`stop()` の疑似コード:

```swift
func stop() {
    guard isRunning else {
        Logger.warn(type: .dummyVideoCapturer, message: "already stopped")
        return
    }
    timer?.invalidate()
    timer = nil
    isRunning = false
}
```

Timer コールバックの処理フロー（疑似コード）:

```swift
/// 連続失敗カウンタ（Timer コールバックはメインスレッドのみで動作するためスレッド安全性の問題はない）
private var consecutiveFailureCount: Int = 0

private func onTimer() {
    // 1. CVPixelBuffer を確保（失敗時: 連続失敗カウンタをインクリメント、連続 10 回で stop()）
    guard let argbBuffer = createARGBBuffer() else {
        consecutiveFailureCount += 1
        if consecutiveFailureCount >= 10 {
            Logger.error(type: .dummyVideoCapturer, message: "stopped due to consecutive failures")
            stop()
        }
        return
    }
    consecutiveFailureCount = 0

    // 2. CoreGraphics でカラーバーを描画
    drawColorBar(to: argbBuffer)

    // 3. ARGB → YpCbCr 変換。変換失敗時はフレームスキップする
    guard let yuvBuffer = convertToYpCbCr(from: argbBuffer) else {
        Logger.error(type: .dummyVideoCapturer, message: "vImageConvert failed, frame skipped")
        return
    }

    // 4. RTCVideoFrame を構築
    let pixelBuffer = RTCCVPixelBuffer(pixelBuffer: yuvBuffer)
    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
    let elapsedNs = Int64(elapsed * 1_000_000_000)
    let frame = RTCVideoFrame(buffer: pixelBuffer, rotation: RTCVideoRotation._0, timeStampNs: elapsedNs)
    let videoFrame = VideoFrame.native(capturer: nil, frame: frame)

    // 5. 送信（stream が nil の場合は警告ログ。start() でガードしているため通常 nil にならない）
    if let stream {
        stream.send(videoFrame: videoFrame)
    } else {
        Logger.warn(type: .dummyVideoCapturer, message: "stream is nil, frame discarded")
    }
}
```

### PeerChannel の修正方針

#### `initializeSenderStream()` (`PeerChannel.swift:422-541`)

現在の `videoTrackId` 決定とカメラ起動条件：

```swift
// 現在の videoTrackId 決定（疑似）
let videoTrackId: String? = configuration.videoEnabled
    ? configuration.publisherVideoTrackId : nil

// 現在のカメラ起動条件
if configuration.videoEnabled, configuration.cameraSettings.isEnabled,
   configuration.initialCameraEnabled
{
    initializeCameraVideoCapture(stream: stream)
}
```

これを以下のように変更する：

```swift
// videoTrackId 決定（変更なし）
let videoTrackId: String? = configuration.videoEnabled
    ? configuration.publisherVideoTrackId : nil

// 警告ログ: dummyVideoEnabled == true かつ videoEnabled == false
if configuration.dummyVideoEnabled, !configuration.videoEnabled {
    Logger.warn(type: .peerChannel, message: "dummyVideoEnabled is true but videoEnabled is false, dummy video is disabled")
}

// カメラ/ダミーキャプチャ起動
if configuration.videoEnabled {
    if configuration.dummyVideoEnabled {
        initializeDummyVideoCapture(stream: stream)
    } else if configuration.cameraSettings.isEnabled, configuration.initialCameraEnabled {
        initializeCameraVideoCapture(stream: stream)
    }
}
```

#### 新規メソッド `initializeDummyVideoCapture(stream:)`

```swift
private func initializeDummyVideoCapture(stream: MediaStream) {
    let dummyCapturer = DummyVideoCapturer(
        width: configuration.dummyVideoWidth,
        height: configuration.dummyVideoHeight,
        frameRate: configuration.dummyVideoFrameRate)
    dummyCapturer.stream = stream
    self.dummyVideoCapturer = dummyCapturer
    dummyCapturer.start()
}
```

`PeerChannel` に以下のプロパティを追加する：

```swift
private var dummyVideoCapturer: DummyVideoCapturer?
```

#### `terminateSenderStream()` (`PeerChannel.swift:687-700`)

現在の停止処理：

```swift
if configuration.videoEnabled || configuration.cameraSettings.isEnabled {
    if let current = CameraVideoCapturer.current {
        current.stop { error in ... }
    }
}
```

ダミー映像キャプチャの停止処理を追加し、`dummyVideoEnabled` 時はカメラ停止分岐をスキップする：

```swift
// ダミー映像キャプチャの停止（stop() は同期処理）
if let dummyCapturer = dummyVideoCapturer {
    if dummyCapturer.isRunning {
        dummyCapturer.stop()
    }
    dummyVideoCapturer = nil
}

// カメラキャプチャの停止（ダミー映像有効時はカメラは起動していないためスキップ）
if !configuration.dummyVideoEnabled,
   configuration.videoEnabled || configuration.cameraSettings.isEnabled
{
    if let current = CameraVideoCapturer.current {
        current.stop { error in
            if error != nil {
                Logger.debug(
                    type: .peerChannel,
                    message: "failed to stop CameraVideoCapturer =>  \(error!)")
            }
        }
    }
}
```

#### `Configuration` へのプロパティ追加

`Configuration.swift` の `videoEnabled` プロパティ（L130-132）の直後に `dummyVideoEnabled`, `dummyVideoWidth`, `dummyVideoHeight`, `dummyVideoFrameRate` の 4 プロパティを追加する。

### Logger type の追加

`Logger` に新規 type `.dummyVideoCapturer` を追加する。`Sora/Logger.swift` の変更内容：

- `LogType` enum（L4-20）に `.dummyVideoCapturer` を追加
- `CustomStringConvertible` extension（L23-58）に `case .dummyVideoCapturer: return "DummyVideoCapturer"` を追加
- `Group.channels` の switch-case（L256-269）に `.dummyVideoCapturer` を追加（デフォルトでログ出力有効）
- `Group.videoCapturer` の switch-case（L278-283）に `.dummyVideoCapturer` を追加（ユーザー指定時のみログ出力有効）

### スレッド安全性とメインスレッド負荷

- `Timer` は `RunLoop.Mode.common` でメインスレッドの RunLoop に登録する。`Mode.common` を使用することで、UI スクロール中でもフレーム生成が継続される
- `CVPixelBuffer` の生成・描画は Timer のコールバックが動作するメインスレッドで行う
- `stream?.send(videoFrame:)` はメインスレッドから呼ばれ、内部で `RTCVideoSource.capturer(_:didCapture:)` が実行される。これは `CameraVideoCapturer` のバックグラウンドスレッド呼び出しとは異なるが、640x480, 30fps の条件下ではメインスレッドのブロッキングは実用的に問題にならないと判断する。パフォーマンス要件は本 issue のスコープ外（後述の「パフォーマンス」節参照）
- 連続失敗カウンタや `isRunning` などの状態は Timer コールバック（メインスレッド）でのみアクセスされるため、追加の排他制御は不要
- `BasicMediaStream.send(videoFrame:)` 内の `dummyCapturer`（`MediaStream.swift:268`）は読み取り専用であり、`nonisolated(unsafe) static` だがメインスレッドからのアクセスで問題ない

### エッジケース

- `dummyVideoEnabled == true` かつ切断（`basicDisconnect`）発生時: `terminateSenderStream()` で `Timer` を停止し、`DummyVideoCapturer` を `nil` に設定する
- `CVPixelBuffer` 確保失敗時: 連続失敗カウンタをインクリメントし、成功時にリセットする。連続 10 回以上の失敗（カウンタリセットなしで 10 回到達）で `stop()` を呼ぶ。640x480, 30fps で 10 回は約 0.33 秒間の連続失敗であり、それ以上続く場合はメモリ不足の可能性が高いため停止する
- `vImageConvert_*` エラー時: フレームをスキップし、エラーログを出力する（連続失敗カウンタはリセットしない）
- `Timer` の循環参照防止: `[weak self]` キャプチャと `Timer.invalidate()` による。`stop()` および `deinit` の両方で `invalidate()` が呼ばれる
- バックグラウンド遷移時: `Timer` はバックグラウンドでは停止し、フォアグラウンド復帰時に再開される。許容する。タイムスタンプには `systemUptime` を使用するため、バックグラウンド中にタイムスタンプが不連続になる問題は発生しない
- `stream` が nil の場合: `start()` でガードするため通常は nil にならないが、何らかの理由で nil になった場合はフレームを破棄し警告ログを出力する
- 再接続時: `terminateSenderStream()` で `dummyVideoCapturer` は nil に設定され、`initializeSenderStream()` で新規生成される
- `dummyVideoWidth` / `dummyVideoHeight` が 0 または負の値の場合: `init()` で `guard` により `fatalError` とする。実用上の最大値の制限は設けない（`CVPixelBuffer` の制限に従う）
- `dummyVideoFrameRate` が 1 未満または 120 超の場合: `init()` で `guard` により `fatalError` とする。1 未満はフレーム生成不可、120 超はメインスレッド Timer での実用上限を超えるため
- 既存の mute API（`MediaChannel.setVideoHardMute(_:)` / `MediaChannel.setVideoSoftMute(_:)`）との相互作用: 本 issue のスコープ外とする。ダミー映像使用時にこれらの API を呼び出した場合の動作は保証しない

### SDP ネゴシエーションへの影響

ダミー映像使用時も `videoEnabled == true` であれば映像トラックは `initializeSenderStream()` で通常通り生成され、SDP でオファーされる。`DummyVideoCapturer.start()` は `initializeSenderStream()` 内で `initializeDummyVideoCapture(stream:)` 経由で呼ばれる。`start()` の内部では Timer がスケジュールされるのみであり、実際の最初のフレーム送信は次の RunLoop iteration で行われるため、Answer 生成時のカメラ起動と同様に Answer 送信とフレーム送信の間で順序問題は発生しない。

### パフォーマンス

本 issue ではパフォーマンス要件を設定しない。640x480, 30fps のダミー映像生成が実機で極端な CPU 負荷を引き起こさないことを手動確認で十分とする。

## テスト戦略

### 手動テスト

- シミュレーター上で `dummyVideoEnabled = true` を設定し、Sora への接続が成功すること
  - ICE 接続が確立し `onConnect` が呼ばれること
  - カラーバー映像が送信されていることを受信側で目視確認すること
- 実機で `dummyVideoEnabled = true` を設定した場合、物理カメラが起動しないことを確認すること
- `dummyVideoEnabled = false`（デフォルト）の場合、カメラ起動・映像送受信・切断処理に影響がないことを確認すること
- 切断時に `Timer` が停止し、メモリリークが発生しないことを確認すること
- `role = .recvonly` で `dummyVideoEnabled = true` を設定した場合、設定が無視されることを確認すること

### 単体テスト

テストファイル: `SoraTests/DummyVideoCapturerTests.swift`（新規追加。既存の `SoraTests/` ディレクトリに配置する）

テストファイルには `import WebRTC`、`import XCTest`、`@testable import Sora` が必要。

テスト項目:

- `DummyVideoCapturer` の `start()`/`stop()` が `isRunning` を正しく切り替えること
- `start()` の重複呼び出しが無視されること
- `stop()` の重複呼び出しが無視されること
- 生成された `CVPixelBuffer` のサイズが設定値と一致すること
- 生成されたカラーバーの特定位置のピクセル値が期待する色であること。以下の Y/Cb/Cr 期待値（Full Range）で検証する（`CVPixelBuffer` から `CVPixelBufferLockBaseAddress` / `CVPixelBufferGetBaseAddressOfPlane` で Y/CbCr プレーンのデータを直接読み取って検証する。モック不要）:

| 色 | Y | Cb | Cr |
|---|---|---|---|
| 白 | 255 | 128 | 128 |
| 黄 | 226 | 16 | 149 |
| シアン | 178 | 166 | 16 |
| 緑 | 149 | 54 | 34 |
| マゼンタ | 78 | 178 | 222 |
| 赤 | 76 | 90 | 240 |
| 青 | 29 | 240 | 111 |
| 黒 | 0 | 128 | 128 |

- `stream` が nil の状態で `start()` を呼んだ場合に警告ログが出力され、`isRunning` が `false` のままであること
- `deinit` により `Timer` が解放されること（`autoreleasepool` でインスタンスのライフサイクルを制御し、`stop()` が呼ばれない場合でも `deinit` → `timer?.invalidate()` が実行されることを `isRunning` 経由で検証）

## 変更ファイル一覧

- `Sora/DummyVideoCapturer.swift` — 新規追加
- `Sora/Configuration.swift` — `dummyVideoEnabled`, `dummyVideoWidth`, `dummyVideoHeight`, `dummyVideoFrameRate` の 4 プロパティを追加
- `Sora/PeerChannel.swift` — `initializeDummyVideoCapture(stream:)` の追加、`initializeSenderStream()` の条件分岐修正（警告ログ含む）、`terminateSenderStream()` の停止処理追加（`dummyVideoEnabled` 時のカメラ停止スキップを含む）、`dummyVideoCapturer` プロパティの追加
- `Sora/Logger.swift` — `LogType` enum に `.dummyVideoCapturer` を追加、`Group.channels` と `Group.videoCapturer` の switch-case に `.dummyVideoCapturer` を追加
- `SoraTests/DummyVideoCapturerTests.swift` — 新規追加（単体テスト）
- `CHANGES.md` — 変更履歴に以下を追記:
  - [ADD] Configuration にダミー映像の設定を追加する
    - `dummyVideoEnabled` が `true` の場合、物理カメラの代わりにダミー映像（カラーバー）を生成して送信する
    - `dummyVideoWidth`, `dummyVideoHeight`, `dummyVideoFrameRate` で解像度とフレームレートを指定可能
    - @voluntas

## 完了条件

- [ ] `Sora/DummyVideoCapturer.swift` が追加され、ダミー映像フレームを生成できること
- [ ] `Configuration.dummyVideoEnabled` が追加され、`true` に設定すると物理カメラを使わずにダミー映像（カラーバー）が送信されること
- [ ] `dummyVideoWidth`, `dummyVideoHeight`, `dummyVideoFrameRate` で解像度とフレームレートが設定可能であること
- [ ] シミュレーター上でダミー映像を使った Sora 接続が成功すること（ICE 接続確立）
- [ ] 切断時に `DummyVideoCapturer` が適切に停止され、`Timer` が解放されること（`deinit` による防御を含む）
- [ ] `dummyVideoEnabled == false`（デフォルト）の場合、既存のカメラ起動・映像送受信・切断処理に影響がないこと
- [ ] 既存の単体テスト（`SoraTests`）が変更前後で全て成功すること
- [ ] `CHANGES.md` に変更履歴が追記されていること
