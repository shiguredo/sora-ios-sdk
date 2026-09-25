import CoreVideo
import Foundation
import WebRTC
import XCTest

@testable import Sora

// テスト用のヘルパーです。モックやスタブは使用せず、実プロトコルの実装と実 API だけを使います。
//
// - 接続の構築 (`makeTestConfiguration` / `makeTestMediaChannel` / `makeSenderStreamWithVideoTrack`) は
//   ScreenCaptureFrameGenerationTests / StreamFrameOwner 系テスト / DummyVideoCapturerTests で共有します。
// - 画面キャプチャの drain は ScreenCaptureFrameGenerationTests と StreamFrameOwner 系テストで共有します。
// - owner の観測 (`ownerForTesting` / `drainOwnerAndMainQueue`) と観測用の実装
//   (`RecordingVideoFilter` / `RecordingVideoRenderer` / `SynchronousFilterGate`) は
//   StreamFrameOwner 系テスト専用です。

/// テストで共通利用する `Configuration` を構築します。
func makeTestConfiguration() -> Configuration {
  guard let url = URL(string: "wss://example.com") else {
    fatalError("テスト URL の生成に失敗しました")
  }
  return Configuration(
    urlCandidates: [url],
    channelId: "test",
    role: .sendonly)
}

/// テストで共通利用する `MediaChannel` を構築します。
func makeTestMediaChannel() throws -> MediaChannel {
  try MediaChannel(configuration: makeTestConfiguration())
}

/// 映像トラックと video source を持つ sender stream を構築します。
///
/// `createNativeStream` が作る stream は video track を持たず、`BasicMediaStream` の
/// video source が `nil` になります。映像フレームの配送経路を検証するテストでは
/// video track を持つこの stream を使います。
func makeSenderStreamWithVideoTrack(mediaChannel: MediaChannel) -> MediaStream {
  let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
  let nativeStream = nativeFactory.createNativeSenderStream(
    streamId: "test-stream",
    videoTrackId: "test-video-track",
    audioTrackId: nil,
    constraints: MediaConstraints())
  return BasicMediaStream(peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
}

/// `MediaStream` から frame 処理の owner を取り出します。テスト専用の accessor です。
func ownerForTesting(_ stream: MediaStream) -> StreamFrameOwner {
  guard let basicStream = stream as? BasicMediaStream else {
    fatalError("BasicMediaStream を期待しました")
  }
  return basicStream.streamOwner
}

/// 送信キューと owner queue の両方の処理完了を待ちます。
///
/// 画面キャプチャ経路は「送信キュー → owner queue」の 2 段で frame を処理するため、
/// `VideoFilter` の到達回数を assert する前に両方を drain する必要があります。
func drainSendVideoFrameQueueAndOwner(
  controller: ScreenCaptureController,
  senderStream: MediaStream
) {
  controller.drainSendVideoFrameQueue()
  ownerForTesting(senderStream).drainForTesting()
}

/// owner queue を drain し、main queue への配送完了を待ちます。
///
/// owner は「owner queue → main queue」の 2 段で配送するため、callback を assert する前に
/// 両方を待つ必要があります。main queue の待ち合わせは、配送 block より後に投入した
/// 自分の block を `XCTestExpectation` で待つことで行います。main queue を回すために
/// テスト本体が main thread で動いている必要があります (同期テストの前提)。
func drainOwnerAndMainQueue(_ stream: MediaStream, timeout: TimeInterval = 5) {
  XCTAssertTrue(Thread.isMainThread, "main queue を回すため main thread から呼ぶこと")
  ownerForTesting(stream).drainForTesting()
  let expectation = XCTestExpectation(description: "main queue への配送を待つ")
  DispatchQueue.main.async {
    expectation.fulfill()
  }
  XCTAssertEqual(
    XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
    "main queue への配送が制限時間内に完了すること")
}

/// テスト用の frame を生成し、生成できなければテストを失敗させます。
func requireVideoFrame(timeStampNs: Int64) -> VideoFrame {
  guard let frame = makeVideoFrameForTesting(timeStampNs: timeStampNs) else {
    fatalError("テスト用の VideoFrame を生成できませんでした")
  }
  return frame
}

/// テスト用の native frame を生成し、生成できなければテストを失敗させます。
func requireNativeVideoFrame(timeStampNs: Int64, width: Int = 64) -> RTCVideoFrame {
  guard let frame = makeNativeVideoFrameForTesting(timeStampNs: timeStampNs, width: width) else {
    fatalError("テスト用の RTCVideoFrame を生成できませんでした")
  }
  return frame
}

/// テスト用の実 `VideoFrame` を生成します。
///
/// 実 CoreVideo の API で pixel buffer を作り、`RTCCVPixelBuffer` 経由で `RTCVideoFrame` を
/// 組み立てます。モックやスタブは使用しません。
func makeVideoFrameForTesting(
  timeStampNs: Int64,
  width: Int = 64
) -> VideoFrame? {
  var createdPixelBuffer: CVPixelBuffer?
  let attributes: [String: Any] = [
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
  ]
  let pixelBufferStatus = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    48,
    kCVPixelFormatType_32BGRA,
    attributes as CFDictionary,
    &createdPixelBuffer)
  guard pixelBufferStatus == kCVReturnSuccess, let pixelBuffer = createdPixelBuffer else {
    return nil
  }
  let frame = RTCVideoFrame(
    buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
    rotation: ._0,
    timeStampNs: timeStampNs)
  return .native(capturer: nil, frame: frame)
}

/// テスト用の実 `RTCVideoFrame` を生成します。
///
/// `RTCVideoRenderer.renderFrame(_:)` へ直接渡す frame を作るために使います。
func makeNativeVideoFrameForTesting(
  timeStampNs: Int64,
  width: Int = 64
) -> RTCVideoFrame? {
  guard
    let videoFrame = makeVideoFrameForTesting(timeStampNs: timeStampNs, width: width)
  else {
    return nil
  }
  switch videoFrame {
  case .native(_, let nativeFrame):
    return nativeFrame
  }
}

/// `VideoFilter.filter` を任意の時点で停止・再開するゲートです。
///
/// `filter` は同期メソッドのため actor で待たせられません。`DispatchSemaphore` を使い、
/// 「filter が停止したこと」と「再開したこと」をテスト側から決定的に観測します。
/// 再開後は以降に到着する frame も停止しません (1 回の再開で全 frame を通します)。
final class SynchronousFilterGate {
  /// filter が停止したことを通知するセマフォです。
  private let enteredFilterSemaphore = DispatchSemaphore(value: 0)
  /// filter の再開を待つセマフォです。
  private let resumeFilterSemaphore = DispatchSemaphore(value: 0)

  /// 再開済みかどうかを保護する lock です。
  private let lock = NSLock()

  /// 再開済みかどうかです。
  private var isOpen = false

  /// `VideoFilter.filter` の中から呼びます。停止して再開を待ちます。
  ///
  /// 既に再開済みの場合は停止せずに戻ります。
  func waitInsideFilter() {
    lock.lock()
    let open = isOpen
    lock.unlock()

    enteredFilterSemaphore.signal()
    if open {
      return
    }
    resumeFilterSemaphore.wait()
  }

  /// filter が停止するまで待ちます。
  ///
  /// - Returns: 制限時間内に filter が停止した場合は `true`。
  func waitUntilFilterIsBlocked() -> Bool {
    enteredFilterSemaphore.wait(timeout: .now() + 5) == .success
  }

  /// 停止している filter を再開します。以降に到着する frame も停止しません。
  func resumeFilter() {
    lock.lock()
    isOpen = true
    lock.unlock()
    resumeFilterSemaphore.signal()
  }
}

/// 呼び出し順と同時実行の有無を記録する実 `VideoFilter` です。
///
/// モックではなく実プロトコルの実装であり、SDK から実際に呼ばれた回数だけを記録します。
final class RecordingVideoFilter: VideoFilter {
  /// 実行を停止するゲートです。設定した場合、filter はゲートが再開されるまで停止します。
  var gate: SynchronousFilterGate?

  /// filter の実行時間を延ばす待ち時間 (秒) です。並行実行の検出窓を広げるために使います。
  var executionInterval: TimeInterval = 0

  /// 記録した frame の timestamp (ナノ秒) を保護する lock です。
  private let lock = NSLock()

  /// filter を通った frame の timestamp (ナノ秒) です。実行順に並びます。
  private var recordedTimestamps: [Int64] = []

  /// filter の実行中に他スレッドから入られた回数です。
  private var concurrentCallCount = 0

  /// この filter が実行中かどうかです。
  private var isRunning = false

  /// filter を通った frame の timestamp (ナノ秒) の一覧です。
  var timestamps: [Int64] {
    lock.lock()
    defer { lock.unlock() }
    return recordedTimestamps
  }

  /// filter が呼ばれた回数です。
  var count: Int {
    timestamps.count
  }

  /// filter の実行中に他スレッドから入られた回数です。
  ///
  /// 直列化が守られていれば 0 です。
  var concurrentCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return concurrentCallCount
  }

  /// frame をそのまま返し、呼び出しを記録します。
  func filter(videoFrame: VideoFrame) -> VideoFrame {
    lock.lock()
    if isRunning {
      concurrentCallCount += 1
    }
    isRunning = true
    lock.unlock()

    if executionInterval > 0 {
      Thread.sleep(forTimeInterval: executionInterval)
    }
    gate?.waitInsideFilter()

    if let timestamp = videoFrame.timestamp {
      lock.lock()
      recordedTimestamps.append(timestamp.value)
      lock.unlock()
    }

    lock.lock()
    isRunning = false
    lock.unlock()
    return videoFrame
  }
}

/// 呼ばれた renderer callback を順序どおりに記録する実 `VideoRenderer` です。
///
/// モックではなく実プロトコルの実装であり、SDK から実際に呼ばれた callback だけを記録します。
final class RecordingVideoRenderer: VideoRenderer {
  /// 記録する callback の種類です。
  enum Callback: Equatable {
    case added
    case removed
    case disconnect
    /// frame の幅です。`nil` は frame が `nil` のまま配送されたことを表します。
    case render(frameWidth: Int?)
    case size(CGSize)
    case switchVideo(Bool)
    case switchAudio(Bool)
  }

  /// 記録を保護する lock です。callback は main queue から呼ばれますが、テスト側は
  /// 任意のスレッドから読むため排他します。
  private let lock = NSLock()

  /// 記録した callback の一覧です。
  private var recordedCallbacks: [Callback] = []

  /// 各 callback が main queue 上で呼ばれたかどうかです。
  private var recordedOnMainThread: [Bool] = []

  /// 記録した callback の一覧です。
  var callbacks: [Callback] {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallbacks
  }

  /// 各 callback が main queue 上で呼ばれたかどうかです。
  var onMainThread: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return recordedOnMainThread
  }

  /// 配送された frame の数です (`.render` の件数)。
  var renderCount: Int {
    callbacks.filter { callback in
      if case .render = callback {
        return true
      }
      return false
    }.count
  }

  func onChange(size: CGSize) {
    record(.size(size))
  }

  func render(videoFrame: VideoFrame?) {
    record(.render(frameWidth: videoFrame?.width))
  }

  func onDisconnect(from: MediaChannel?) {
    record(.disconnect)
  }

  func onAdded(from: MediaStream) {
    record(.added)
  }

  func onRemoved(from: MediaStream) {
    record(.removed)
  }

  func onSwitch(video: Bool) {
    record(.switchVideo(video))
  }

  func onSwitch(audio: Bool) {
    record(.switchAudio(audio))
  }

  /// callback と main queue 上で呼ばれたかどうかを記録します。
  private func record(_ callback: Callback) {
    lock.lock()
    recordedCallbacks.append(callback)
    recordedOnMainThread.append(Thread.isMainThread)
    lock.unlock()
  }
}
