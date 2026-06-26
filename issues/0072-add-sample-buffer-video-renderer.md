# 外部メディアパイプライン対応のため SampleBufferVideoRenderer を追加する

- Priority: Medium
- Created: 2026-06-26
- Completed:
- Model: Opus 4.7
- Branch: feature/add-sample-buffer-video-renderer
- Polished: 2026-06-26

## 目的

sora-ios-sdk で WebRTC から受信した映像を、AirPlay 分離表示 / Picture in Picture (PiP) / 有線外部ディスプレイなどの外部メディアパイプラインに流せる公開 `VideoRenderer` 実装を SDK 本体に追加する。

現状の SDK の受信映像出力は `VideoView` (内部に `RTCMTLVideoView` を抱える `UIView`) のみで、これらの外部出力では「受信映像を独立した `CALayer` として保持し、任意の `UIWindow` や `AVPictureInPictureController` に貼り付けたい」という要件を満たせない。`AVSampleBufferDisplayLayer` をバックエンドにした `VideoRenderer` 実装 `SampleBufferVideoRenderer` を追加し、利用側に `displayLayer` だけを公開する。

AirPlay ミラーリングは OS 機能であり、`VideoView` を画面に置いた状態で OS の AirPlay ミラーリングを ON にすれば既に動作する。本 issue の `SampleBufferVideoRenderer` はミラーリング以外 (分離表示 / PiP / 有線外部出力) の用途を主眼に置く。

## 優先度根拠

- Sora を使った映像配信アプリで PiP / 外部ディスプレイの引き合いがある。
- 「画面に `VideoView` を貼ったまま PiP / 外部出力でも本 renderer を使う」運用には `MediaStream` への複数 `VideoRenderer` 登録 API 追加 (別 issue) が前提となる。本 issue 単独でも「`MediaStream.videoRenderer` を本 renderer に差し替えて、`displayLayer` を画面と外部出力の両方に流用する」運用は成立する。
- 緊急性は低いため Medium。

## 現状

### 受信映像のパイプライン

受信映像が画面に出るまでの経路は次のとおり。

```
RTCVideoTrack
  └─ add(RTCVideoRenderer)
       └─ VideoRendererAdapter (RTCVideoRenderer 実装) (Sora/VideoRenderer.swift:64-97)
            │ renderFrame(_ frame: RTCVideoFrame?)
            │   - RTCVideoFrame → VideoFrame.native(...) に変換
            │   - DispatchQueue.main 経由で VideoRenderer.render(videoFrame:) を呼ぶ
            └─ VideoRenderer (public protocol) (Sora/VideoRenderer.swift:40-62)
                 └─ VideoView (デフォルト実装、UIView) (Sora/VideoView.swift)
                      └─ RTCMTLVideoView (libwebrtc 純正の Metal レンダラ)
```

### 制約と前提

- 受信トラックへの `RTCVideoRenderer` 紐付けは `MediaStream.videoRenderer` setter 経由の単数前提実装 (`Sora/MediaStream.swift:132-166`)。`BasicMediaStream.terminate()` も単数の `videoRendererAdapter` にだけ `onDisconnect` を呼ぶ (`Sora/MediaStream.swift:264-266`)。本 renderer は `MediaStream.videoRenderer` (単数) にセットして使う前提とし、複数併用は別 issue。
- `VideoFrame.native(capturer:frame:)` で `RTCVideoFrame` が露出済み (`Sora/VideoFrame.swift:10-32`)、`frame.buffer` から `RTCCVPixelBuffer` または `RTCI420Buffer` を取り出せる。`VideoFrame.timestamp` は `CMTime?` (Optional) を返す (`Sora/VideoFrame.swift:36-41`)。実装上は常に non-nil の `CMTime` が返るが、Optional 型の契約に従って nil 安全策をコードに含める。
- `VideoRendererAdapter.renderFrame(_:)` は `frame.map { VideoFrame.native(capturer: nil, frame: $0) }` (`Sora/VideoRenderer.swift:91`) で `nil` をそのまま通し、`DispatchQueue.main.async` で main thread に直列投入する (`Sora/VideoRenderer.swift:74-82, 90-96`)。同一 main キューに `setSize:` も投入されるため初フレーム到達前に `setSize:` が呼ばれることが保証される。`SampleBufferVideoRenderer.render(videoFrame:)` は **常に main thread で呼ばれ、`nil` を受け取り得る** 前提で設計する。
- `onChange(size:)` で渡される `size` は libwebrtc 側で `rotation % 180 != 0` の場合に width/height を swap した「回転後サイズ」を受け取る前提で扱う。
- `SoraTests/DummyVideoCapturer.swift` は NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) のカラーバーを生成するのみで、I420 や rotation 付きフレームは生成しない。
- `WebRTC.xcframework` には libyuv のシンボル / ヘッダは公開されておらず、`libyuv::I420Rotate` 等は Swift / Objective-C から直接呼べない。回転と I420 → NV12 変換は Apple 公開 API のみで実装する。
- `Makefile` の `xcodebuild` 設定は `-warnings-as-errors` を指定しておらず、SDK は iOS 26.x SDK でビルドされる (`CHANGES.md ## develop` 内の `## misc` に記載)。後述の iOS 18 deprecation 警告許容と E2E 検証構成はこの前提に依存する。
- E2E 検証用に `SoraTests/DummyVideoCapturer.swift` のような送信側映像生成と、`MediaStream.send(videoFrame:)` (`Sora/MediaStream.swift:269-283`、内部で `nativeVideoSource?.capturer(_:didCapture:)` を呼ぶ送信側パス) が使える。受信側 (本 renderer をセットしたクライアント) は `nativeVideoSource` を持たないため、本 renderer の rotation 検証には送信側を別クライアントで構成する必要がある。

## 設計方針

### 1. SampleBufferVideoRenderer の追加

新規ファイル `Sora/SampleBufferVideoRenderer.swift` に次の公開クラスを実装する。import: `AVFoundation` / `CoreMedia` / `CoreVideo` / `CoreImage` / `WebRTC`。設計方針 3 で Accelerate を採用する場合のみ `Accelerate` を追加する。

```swift
public final class SampleBufferVideoRenderer: VideoRenderer, @unchecked Sendable {
    /// 利用側が任意の CALayer / UIView / AVPictureInPictureController に貼る表示レイヤ。
    public let displayLayer: AVSampleBufferDisplayLayer

    /// 描画 ON / OFF。OFF の間は新規フレームを破棄する。スレッドセーフ。
    /// KVO / Combine 観測は不可 (final class かつ @objc dynamic 不在)。
    public var isEnabled: Bool { get set }

    /// displayLayer 経由のデコード失敗が flush で復帰できなかった場合に main thread で呼ばれる単発ハンドラ。
    /// set / get は任意スレッドから安全。呼び出しは常に main thread。
    /// 本 issue では failure 通知をこれ 1 つに限定する (将来別ハンドラが必要になったら
    /// 別 issue で SampleBufferVideoRendererHandlers 構造体への集約を検討する)。
    public var onFailureHandler: ((Error?) -> Void)?

    public init()

    /// failure 状態をリセットし表示中フレームをクリアする。内部で displayLayer.flushAndRemoveImage を呼ぶ。
    /// 内部の displayLayer.flush() (フレーム保持しつつデコード再開) とは別物。
    /// background → foreground 復帰、トラック切替、failure からの復帰時に利用側から呼ぶ。
    public func flush()

    // VideoRenderer プロトコル実装
    public func onChange(size: CGSize)
    public func render(videoFrame: VideoFrame?)
    public func onDisconnect(from: MediaChannel?)
    public func onAdded(from: MediaStream)
    public func onRemoved(from: MediaStream)
    public func onSwitch(video: Bool)
    public func onSwitch(audio: Bool)
}
```

iOS バージョン / Sendable:

- `AVSampleBufferDisplayLayer` は iOS 8 から存在する公開 API。`SampleBufferVideoRenderer` 自体に `@available` 制限は付けない。`Package.swift` の `platforms: [.iOS(.v14)]` は据え置く。
- 利用側で iOS 15+ の `AVPictureInPictureController` や iOS 16+ の `UIWindowScene.SessionRole.windowExternalDisplayNonInteractive` と組み合わせるかは利用側の責務。SDK 側はそれらに依存しない。
- Sendable は既存 SDK (`Sora/Logger.swift:180` 等) と同様に `final class` + `@unchecked Sendable`。スレッド境界の安全性は `os_unfair_lock` と内部 serial queue で担保する。
- `Sora.h` / `Package.swift` への追加 export 設定は不要。

### 2. スレッドモデル

`SampleBufferVideoRenderer` 内部に **serial dispatch queue** を持つ。

- queue label: `com.shiguredo.sora.sample-buffer-renderer`
- QoS: `.userInteractive`
- `CVPixelBufferPool` の生成・所有・寿命、`CIContext` の生成・所有、変換・enqueue はすべてこの queue 上で行う。
- `displayLayer.enqueue(_:)` は任意スレッドから呼べる (Apple ドキュメント)。queue 上で実行する。
- `os_unfair_lock` は Swift で値型を直接保持できないため `UnsafeMutablePointer<os_unfair_lock>` を `init` で `allocate(capacity: 1)` + `initialize(to: os_unfair_lock())` し、`deinit` で `deinitialize(count: 1)` + `deallocate()` する。
- `isEnabled` の get/set、failure フラグ・clear 要求フラグの読み書きは lock で保護する。
- `flush()` は queue に `sync` 投入する (変換中フレームを待ってから `flushAndRemoveImage` を呼ぶ)。main から呼ぶ前提で、変換 1 フレーム分 (33 ms 程度を目安) の待ちを許容する。利用側からの呼び出しは復帰時 / 切替時 / failure 復帰時に限る運用とする。`flush()` 内で failure フラグもクリアし、enqueue を再開する。

バックプレッシャ + nil 受信 + pool 未生成フォールバックの統合擬似コード:

```
render(videoFrame):
  lock {
    if videoFrame == nil {
      // VideoView と同じく nil は「表示クリア要求」として扱う。
      // OFF 中でも clearPending を立てて drainLoop で必ず flushAndRemoveImage を実行する。
      clearPending = true
      latestFrame = nil
    } else {
      if !isEnabled { return }   // OFF 中の新規フレームは捨てる
      if isFailed { return }     // failure 中は新規 enqueue しない
      latestFrame = videoFrame
    }
    if isProcessing { return }
    isProcessing = true
  }
  queue.async { drainLoop() }

drainLoop():
  while true {
    var frame: VideoFrame?
    var doClear = false
    lock {
      frame = latestFrame
      latestFrame = nil
      doClear = clearPending
      clearPending = false
      if frame == nil && !doClear {
        isProcessing = false
        return
      }
    }
    if doClear {
      displayLayer.flushAndRemoveImage()
    }
    if let frame = frame {
      if pool == nil {           // onChange(size:) より先に render が来た場合のフォールバック
        recreatePool(for: frame)
      }
      process(frame)
    }
  }
```

`render` 内のロックは状態更新と判定を 1 critical section にまとめる。`drainLoop` 側も取り出しと `isProcessing` 更新を 1 critical section にする。

`onFailureHandler` の reentrant 安全性: main 上のハンドラ内から `flush()` (queue 同期) や `isEnabled` 操作 (lock の短い critical section) を呼んでもデッドロックしない。

### 3. RTCVideoFrame → CMSampleBuffer 変換

`AVSampleBufferDisplayLayer` が安定して受け付けるのは NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` / `...VideoRange`) と BGRA。本 renderer は **NV12 に統一して enqueue する**。

`drainLoop` 内で `VideoFrame.native(_, frame)` から `frame.buffer` を取り出し、実型で分岐する。

- `RTCCVPixelBuffer` (デコーダ NV12 出力):
  - `pixelBuffer` を取得。`requiresCropping` または `requiresScalingToWidth:height:` が `true` の場合は NV12 用の `CVPixelBufferPool` から取得した新バッファに `cropAndScaleTo:withTempBuffer:` で焼き直す。`tmpBuffer` は queue 専用に `UnsafeMutableRawPointer.allocate` で確保し、必要サイズが変わったら再確保する。
  - クロッピングもスケーリングも不要なら `pixelBuffer` をそのまま回転処理に渡す。
- `RTCI420Buffer` (ソフトデコーダ等):
  - `RTCYUVPlanarBuffer` から `dataY` / `dataU` / `dataV` (`UnsafePointer<UInt8>`) / `strideY` / `strideU` / `strideV` (`Int32`、バイト/行) を取り出す。
  - 出力先 NV12 `CVPixelBuffer` を `CVPixelBufferPool` から取得し、`CVPixelBufferLockBaseAddress(_, .readOnly)` ではなく書込み用に `CVPixelBufferLockBaseAddress(_, [])` でロックする。終了時 `CVPixelBufferUnlockBaseAddress(_, [])` で確実に解放する (`defer` で書く)。
  - Y plane は row 単位で `memcpy` する。
  - UV plane は U と V を 1 バイトずつ interleave する手書きループで生成する (第一案)。`vImageConvert_PlanarToChunky8` (`channelCount = 2`) も候補だが、Apple Accelerate ヘッダで "too flexible to vectorize every case" と性能制限が示されており、bridging コストも高いため、まずは手書きループで進める。プロファイルで bottleneck が出たら Accelerate / SIMD 採用を検討し、判断と根拠を「解決方法」に記録する。

回転処理は変換結果の NV12 `CVPixelBuffer` に対して行う:

- 回転後の幅高さで NV12 用 `CVPixelBufferPool` から `CVPixelBuffer` を取得 (90 / 270 度の場合は幅と高さが入れ替わる)。
- `CIImage(cvPixelBuffer:)` → `oriented(_:)` (`CGImagePropertyOrientation` で 90 / 180 / 270 を指定) → `CIContext.render(_:to:bounds:colorSpace:)` で回転後 `CVPixelBuffer` に書き出す。`CIContext` は queue 上で 1 個保持し、`init` 時に `[.useSoftwareRenderer: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]` を明示する。`render(_:to:bounds:colorSpace:)` の `colorSpace` にも同じ BT.709 を渡す。
- 出力 `CVPixelBuffer` に `CVBufferSetAttachment` で `kCVImageBufferYCbCrMatrixKey = kCVImageBufferYCbCrMatrix_ITU_R_709_2` を付与する。
- HD/SDR 前提として BT.709 で統一する。送信側が SD/BT.601 映像を送った場合は色ずれが発生し得るが本 issue では許容する (`RTCVideoFrame` 自体が色空間メタデータを露出していないため SDK 側で正確に判別できない)。色空間メタデータの取り扱いは別 issue で対応する。

`CVPixelBufferPool` の attribute:

- pixel format: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` 固定
- `kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()` (空辞書) を `CFDictionary` キャストで指定し IOSurface バックを必須化する (`AVSampleBufferDisplayLayer` の HW 経路要件)
- pool の `auxAttributes` に `kCVPixelBufferPoolAllocationThresholdKey` を設定し、`CVPixelBufferPoolCreatePixelBufferWithAuxAttributes` の戻り値が `kCVReturnWouldExceedAllocationThreshold` の場合は当該フレームを破棄する (バックプレッシャと整合)
- それ以外の確保失敗 (`kCVReturnAllocationFailed` 等) も当該フレームを破棄し `Logger.debug` でログ記録する。連続失敗は本 issue では特別扱いしない (まずは drop 倒し、必要なら後続 issue で escalation 設計)
- 幅・高さは `onChange(size:)` で確定して再生成する。`drainLoop` で pool が未生成の場合は擬似コードどおりフレームの幅高さ (回転後) でフォールバック生成する。`onChange(size: .zero)` は無視する (libwebrtc 側がリセット相当で `.zero` を出す可能性に対する安全策。実装着手時に実際の発生条件を確認し「解決方法」に記録する)

`CMSampleBuffer` 生成:

- `CMVideoFormatDescriptionCreateForImageBuffer` で生成した `CMVideoFormatDescription` は **幅・高さ・pixel format が変わったときのみ再構築** し、変わらなければキャッシュしたものを使い回す。
- `CMSampleBufferCreateReadyWithImageBuffer` で `CMSampleBuffer` 化する。`sampleTiming` の `presentationTimeStamp` は `VideoFrame.timestamp` を使う。`nil` の場合 (現実装では到達しないが API 契約上の安全策) は `CMClockGetTime(CMClockGetHostTimeClock())` をフォールバックとして使う。`duration` と `decodeTimeStamp` は `.invalid` で問題ない。
- 各 `CMSampleBuffer` に `kCMSampleAttachmentKey_DisplayImmediately = true` を付与し、`controlTimebase` 未設定環境でも即時表示されるようにする。

### 4. iOS 18 における AVSampleBufferDisplayLayer の deprecation と本 issue の選択

iOS 18 で `AVSampleBufferDisplayLayer` の `enqueue` / `flush` / `flushAndRemoveImage` / `error` / `status` / `requiresFlushToResumeDecoding` / `isReadyForMoreMediaData` は `API_DEPRECATED("Use sampleBufferRenderer's ... instead")` 化された。代替は iOS 17+ で導入された `sampleBufferRenderer: AVSampleBufferVideoRenderer`。

本 issue では旧 API (`displayLayer.enqueue` 等) をそのまま使用する。理由:

- `Makefile` が `-warnings-as-errors` を指定していないため deprecation 警告でビルド失敗にはならない (制約と前提参照)。
- SDK の `Package.swift` の `platforms: [.iOS(.v14)]` を据え置く方針との整合 (`AVSampleBufferVideoRenderer` は iOS 17+ で利用側に分岐コードを強いる)。
- 本 issue のスコープを `SampleBufferVideoRenderer` 自体の追加に限定するため。

`AVSampleBufferDisplayLayerFailedToDecodeNotification` 等の Notification 名定数自体は iOS 18 でも deprecated になっていない。

`AVSampleBufferVideoRenderer` への移行は別 issue で扱う (スコープ外参照)。

### 5. AVSampleBufferDisplayLayer のリカバリ

- **失敗検出**: `NotificationCenter` で `AVSampleBufferDisplayLayerFailedToDecodeNotification` (iOS 8+ 文書化) を購読する。`addObserver(forName:object:queue:using:)` の `object` に `displayLayer` を渡してフィルタする。`queue: nil` で受け、ハンドラ内では即 `processingQueue.async` に再投入する。observer token は `init` 時に保持し、`deinit` で `removeObserver` する。クロージャは `[weak self]` で循環参照を防ぐ。
  - 受信したら queue 上で `displayLayer.flush()` を試み (旧 API のフラッシュ。`flushAndRemoveImage` ではない)、それでも `displayLayer.error` が non-nil なら failure フラグを立てて新規 enqueue を停止する。`onFailureHandler` を main thread にディスパッチして `displayLayer.error` を引数で呼ぶ。
- **flush 要求検出**: `requiresFlushToResumeDecoding` (iOS 14+) はプロパティ参照する。`drainLoop` で `displayLayer.enqueue(_:)` を呼ぶ直前に `if displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }` を毎回チェックする。iOS 14 未満では同プロパティは存在しないため `@available(iOS 14, *)` で分岐する。
- **テスト用フック**: failure 経路の単体テストは Notification 人工投入では `displayLayer.error` が nil のため失敗フラグ遷移を再現できない。内部に `internal func simulateFailureForTesting(error: Error?)` を queue 上で failure フラグ立て + `onFailureHandler` 呼び出しを行う internal メソッドを用意し、`@testable import Sora` で叩く。これにより onFailureHandler の main thread 呼び出しと `flush()` でのリセットを検証可能にする。
- `isEnabled = false` の間に到着したフレームは即破棄する。`true` に戻った時点で次フレームから enqueue を再開する。`isEnabled = false → true` の遷移自体では failure フラグはリセットしない (`isEnabled` は ON/OFF、`flush()` は復帰用 API、と役割を分離する)。

ライフサイクル通知:

- `onAdded(from:)`: `Logger.debug(type: .videoRenderer, message: "SampleBufferVideoRenderer(\(ObjectIdentifier(self))) added to stream")` でログ。状態変更はしない。
- `onRemoved(from:)`: queue 上で `flushAndRemoveImage` を呼んで表示を空にする。
- `onDisconnect(from:)`: queue 上で `flushAndRemoveImage` を呼んで表示を空にする。
- `onSwitch(video: false)`: 相手側 (送信元) の映像が無効化された通知。`isEnabled` (利用側設定) とは独立に表示を `flushAndRemoveImage` でクリアする。`isEnabled` 自体は変更しない。
- `onSwitch(video: true)`: 次フレームから enqueue を再開する (`isEnabled == true` かつ failure フラグ false の場合)。
- `onSwitch(audio: _)`: 何もしない (`VideoView` と同じ流儀)。

主要分岐は `Logger.debug(type: .videoRenderer, message: ...)` で構造化ログを出す。message は英語、コメントは日本語 (AGENTS.md 規約)。message にはレンダラ識別子 (`\(ObjectIdentifier(self))`) を含めて既存 `Sora/VideoRenderer.swift:76` / `Sora/MediaStream.swift:155` の流儀に揃える。`Sora/Logger.swift:15` に `LogType.videoRenderer` 既存、追加実装不要。

### 6. 関連 issue 0027 / 0060 との関係

本 issue は既存の `VideoRenderer` プロトコルに準拠し、0027 / 0060 の進捗状況にかかわらず独立して完了させる。0027 で導入される `Task { @MainActor in renderer.render(videoFrame:) }` 経路は `DispatchQueue.main.async` と比較して `setSize` と `renderFrame` の相対順序が入れ替わる可能性がある (0027 本文に明記)。本 renderer はこの順序入替に備え、`drainLoop` で pool 未生成なら現フレームのサイズからフォールバック生成する設計 (設計方針 2 擬似コード参照)。

具体的な追従作業 (準拠先切り替え / `queue` プロパティ実装) は別 issue で扱う (スコープ外参照)。

### 7. SDK 同梱範囲の線引き

SDK 同梱:

- `SampleBufferVideoRenderer` 本体
- `RTCVideoFrame` → `CMSampleBuffer` 変換 (I420 → NV12 変換とピクセル単位回転を含む)

SDK 同梱しない (利用側責務):

- AirPlay ミラーリング状態の検出
- `UIWindowSceneDelegate` での `externalDisplayNonInteractive` 取得
- `AVPictureInPictureController` / `AVPictureInPictureSampleBufferPlaybackDelegate` の生成と制御

各 OS API はアプリ固有の状態管理に依存し、SDK が巻き取ると利用側の柔軟性を奪う。

### 8. 利用イメージ

```swift
let renderer = SampleBufferVideoRenderer()
renderer.onFailureHandler = { error in
    // 利用側で UI 復帰やリトライ判断
}
mediaStream.videoRenderer = renderer

// 画面表示 (任意。displayLayer を任意の UIView の layer に追加する)
videoContainer.layer.addSublayer(renderer.displayLayer)

// PiP 開始 (任意)。画面表示しない場合は上の addSublayer を省略する
let source = AVPictureInPictureController.ContentSource(
    sampleBufferDisplayLayer: renderer.displayLayer,
    playbackDelegate: pipDelegate)
let pip = AVPictureInPictureController(contentSource: source)
```

## 完了条件

### コード

- `Sora/SampleBufferVideoRenderer.swift` が追加され、`public final class SampleBufferVideoRenderer: VideoRenderer, @unchecked Sendable` が定義されていること。import は `AVFoundation` / `CoreMedia` / `CoreVideo` / `CoreImage` / `WebRTC` を必須、`Accelerate` は設計方針 3 で採用した場合のみ。
- 公開 API: `displayLayer` / `isEnabled` / `onFailureHandler` / `init()` / `flush()` + `VideoRenderer` プロトコルメソッド。`Sora.h` / `Package.swift` への追加 export 設定は不要。
- 公開 `flush()` の doc コメントで「内部の `displayLayer.flush()` とは別物 (`flushAndRemoveImage` 相当 + failure フラグリセット)」を明記すること。
- 設計方針 1〜5 のすべての要件を満たすこと (内部 serial queue、`os_unfair_lock`、バックプレッシャ、`render(videoFrame: nil)` 表示クリア、Apple 公開 API のみによる I420 → NV12 変換と回転、BT.709 統一、`CVPixelBufferPool` IOSurface + threshold 属性、`CMVideoFormatDescription` キャッシュ、`kCMSampleAttachmentKey_DisplayImmediately`、`displayLayer.flush()` と公開 `flush()` の役割分離、Notification 主軸 + `requiresFlushToResumeDecoding` プロパティ参照、`Logger.debug(type: .videoRenderer, ...)`)。
- 単体テスト観測用に `internal var enqueuedFrameCount: Int` を queue 上で更新する形で持つこと。`@testable import Sora` で外部から読めること。
- 単体テスト用フックとして `internal func simulateFailureForTesting(error: Error?)` を持ち、queue 上で failure フラグ立て + `onFailureHandler` 呼び出しが行えること。
- `Package.swift` の `platforms: [.iOS(.v14)]` を変更しないこと。

### テスト

- 既存テストがすべて通ること。
- 新規ユニットテスト `SoraTests/SampleBufferVideoRendererTests.swift` を追加すること (モック禁止)。`RTCVideoFrame(buffer:rotation:timeStampNs:)` を直接構築する手法は libwebrtc の公開 initializer による実物構築であり、本 SDK の「モック / スタブ禁止」規約に該当しない。
  - NV12 入力 (`RTCCVPixelBuffer`) → `CMSampleBuffer` 変換が幅高さ / `presentationTimeStamp` を正しく反映する (`DummyVideoCapturer` の NV12 フレームを使う)。
  - I420 入力 (`RTCI420Buffer`) → `CMSampleBuffer` 変換が幅高さ / `presentationTimeStamp` を正しく反映する。I420 フレームは `DummyVideoCapturer` の NV12 フレームに `RTCVideoFrame.newI420VideoFrame()` を適用して得る (`RTCVideoFrame.h:60` で `nonnull` 保証なので Optional チェックは不要、`XCTAssertTrue(i420Frame.buffer is RTCI420Buffer)` のアサートのみ入れて経路を保証)。
  - rotation = 90 / 180 / 270 で、`CMSampleBuffer` の幅高さが回転後の値になっていること。rotation 付きフレームは `RTCVideoFrame(buffer:rotation:timeStampNs:)` で直接構築する。
  - 既知バイト列の I420 plane を入力したとき、出力 NV12 `CVPixelBuffer` の Y plane / UV interleaved plane が期待バイト列と一致すること (`CVPixelBufferLockBaseAddress` 経由でメモリ比較)。
  - `isEnabled = false` の間に渡されたフレームは `enqueuedFrameCount` が増えないこと。
  - `render(videoFrame: nil)` を呼ぶと `flushAndRemoveImage` 相当の効果が出ること (`enqueuedFrameCount` リセット観測、または `displayLayer.isReadyForMoreMediaData` 等での確認)。
  - `flush()` が完了するまで呼び出し元がブロックされること (同期投入)。
  - `simulateFailureForTesting(error:)` 経由で failure フラグ立て → `onFailureHandler` が main thread で呼ばれる → `flush()` でリセットして enqueue 再開する状態遷移。
  - バックプレッシャ動作: 短時間に N フレーム投入したとき `enqueuedFrameCount` が N より少なく、最新フレームが必ず含まれること。
- 非同期検証は `queue.sync { }` を内部に持つ internal な「drain 完了待ち」フックを介して行うか、`XCTestExpectation` で待つ。具体的にはレンダラ内に `internal func waitForIdle()` を用意して queue.sync で空回りさせる方式を採る。
- 変換と回転の純粋ロジックは `internal` 関数として切り出し、`@testable import Sora` でテストから直接呼び出す (既存 `SoraTests/` の方式を踏襲)。

### 必須の実機検証

実機 2 台 (送信側 / 受信側) または送信側 1 台 + 受信側 (本 SDK) 1 台の計 2 接続で実施する。送信側は `sora-ios-sdk-samples` の sendonly 構成または別途検証用 sendonly クライアントを用意し、`type: sendrecv` での自己ループバックでも可。

- `SampleBufferVideoRenderer.displayLayer` を画面 (任意の `UIView` の `layer`) に貼り、Sora 受信映像 (recvonly 接続) が表示されること。
- 送信側で `RTCVideoFrame(buffer:rotation:timeStampNs:)` を構築し `VideoFrame.native(capturer: nil, frame:)` でラップして `mediaStream.send(videoFrame:)` で投げる。受信側の表示が 0 / 90 / 180 / 270 すべてで正しい向きになること。
- 接続切断 / トラック再受信時にクリーンアップされること (古いフレームが残らない)。
- background → foreground 復帰時に `flush()` を呼んで描画が継続できること。
- `onFailureHandler` が main thread で呼ばれること。検証は `simulateFailureForTesting(error:)` を実機ビルドからも叩いてハンドラ内で `Thread.isMainThread` を `Logger.debug` 出力する。

### 推奨の実機検証 (機材がある場合に実施)

- AirPlay 分離表示 (`UIWindowScene` + Apple TV / Mac AirPlay 受信)。
- HDMI 等の有線外部ディスプレイ (`UIWindowScene.SessionRole.windowExternalDisplayNonInteractive` で別 `UIWindow` に `displayLayer` を貼る、iOS 16+)。
- 実機での `AVPictureInPictureController` 起動 / バックグラウンド継続 / 復帰 (シミュレータでは PiP の挙動が不安定なため実機推奨)。

### 変更履歴

`CHANGES.md` の `## develop` セクションの既存 `[ADD]` ブロック末尾に以下を追記すること。

```
- [ADD] 外部メディアパイプライン出力用の SampleBufferVideoRenderer を追加する
  - @voluntas
```

## 解決方法

実装着手時に以下の判断結果を本セクションに記録する (PR description にも同じ内容を添える):

- I420 → NV12 変換: 手書きループのまま行ったか、Accelerate / SIMD を採用したか。プロファイル結果と判断根拠。
- NV12 回転: CIImage 経路で問題なかったか、Accelerate `vImageRotate90_Planar8` などの代替に倒したか。
- `onChange(size: .zero)` が libwebrtc 側で実際に発生する条件 (トラック切替時 / リセット時など)。
- `kCVReturnAllocationFailed` の発生頻度と escalation 設計の要否。

## スコープ外

- `MediaStream` に複数 `VideoRenderer` 登録 API (`addVideoRenderer` / `removeVideoRenderer`) を追加する作業。`VideoView` と `SampleBufferVideoRenderer` の同時利用が必要な場合は別 issue で扱う。`MediaStream` プロトコルおよび `BasicMediaStream` には本 issue では変更を加えない。
- 送信側 (sender loopback プレビュー) の外部メディアパイプライン出力。別 issue で扱う。
- AirPlay ミラーリング状態の検出 API、`UIWindowScene` ヘルパー、`AVPictureInPictureController` ヘルパー、サンプル実装 (`sora-ios-sdk-samples` 側で別 PR)。
- 関連 issue 0027 / 0060 の追従 (`MainActorVideoRenderer` 移行 / `queue` プロパティ追従)、iOS 17+ の `AVSampleBufferVideoRenderer` への移行 (iOS 18 deprecation 解消) は別 issue で扱う。CI / Makefile が `-warnings-as-errors` を将来追加した場合は本 renderer の利用を保留するか、`AVSampleBufferVideoRenderer` 移行 issue を先行させること。
- 直前フレームを残す `flush` バリエーション。本 issue では `flushAndRemoveImage` 一択。
- 既存 SDK ハンドラ (`SoraHandlers.onChangeAudioRoute` 等) のスレッド保証文書化。本 renderer の `onFailureHandler` のみ明文化する。
- 送信映像が SD/BT.601 だった場合の色空間正確化。`RTCVideoFrame` の色空間メタデータ拡張と合わせて別 issue で対応する。
