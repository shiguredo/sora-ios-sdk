@preconcurrency import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import WebRTC

@testable import Sora

/// E2E テスト用のダミー映像キャプチャ
///
/// 物理カメラを使用せずにカラーバー映像を生成して送信する。
/// `@testable import Sora` により `MediaStream.send(videoFrame:)` にアクセスする。
final class DummyVideoCapturer: @unchecked Sendable {
  /// 出力先のストリーム
  weak var stream: MediaStream?

  /// 起動中かどうか
  private(set) var isRunning: Bool = false

  /// 送信に成功したフレーム数
  private(set) var frameCount: Int = 0

  /// フレーム生成用の設定
  let width: Int32
  let height: Int32
  let frameRate: Int

  /// フレーム生成用の Timer
  private var timer: Timer?

  /// 連続失敗カウンタ
  private var consecutiveFailureCount: Int = 0

  /// タイムスタンプの基準時刻
  private var startTime: TimeInterval = 0

  // MARK: - カラーバー色定義 (RGBA)

  private static let colorBarColors: [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = [
    (1, 1, 1, 1),  // 白
    (1, 1, 0, 1),  // 黄
    (0, 1, 1, 1),  // シアン
    (0, 1, 0, 1),  // 緑
    (1, 0, 1, 1),  // マゼンタ
    (1, 0, 0, 1),  // 赤
    (0, 0, 1, 1),  // 青
    (0, 0, 0, 1),  // 黒
  ]

  // MARK: - 初期化

  init(width: Int32, height: Int32, frameRate: Int) {
    // 値域検証とクランプ
    let clampedWidth = max(1, Int(width))
    let clampedHeight = max(1, Int(height))
    // YUV 4:2:0 は偶数が必須のため奇数を切り上げる
    self.width = Int32((clampedWidth + 1) / 2 * 2)
    self.height = Int32((clampedHeight + 1) / 2 * 2)
    self.frameRate = min(max(1, frameRate), 120)
  }

  deinit {
    timer?.invalidate()
  }

  // MARK: - 操作

  /// フレーム生成を開始する。重複呼び出しは無視する。
  func start() {
    guard !isRunning else {
      Logger.warn(type: .user("DummyVideoCapturer"), message: "DummyVideoCapturer already running")
      return
    }
    guard stream != nil else {
      Logger.warn(type: .user("DummyVideoCapturer"), message: "DummyVideoCapturer stream not set")
      return
    }
    startTime = ProcessInfo.processInfo.systemUptime
    consecutiveFailureCount = 0
    isRunning = true
    let interval = 1.0 / Double(frameRate)
    timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      self?.onTimer()
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  /// フレーム生成を停止する。重複呼び出しは無視する。
  func stop() {
    guard isRunning else {
      Logger.warn(type: .user("DummyVideoCapturer"), message: "DummyVideoCapturer already stopped")
      return
    }
    timer?.invalidate()
    timer = nil
    isRunning = false
  }

  // MARK: - フレーム生成

  /// Timer コールバック
  ///
  /// 毎フレーム以下の処理を行う:
  /// 1. ARGB 形式の CVPixelBuffer を確保
  /// 2. CoreGraphics でカラーバーを描画
  /// 3. vImage で ARGB → YpCbCr (420BiPlanarFullRange) に変換
  /// 4. RTCVideoFrame を構築し MediaStream.send(videoFrame:) で送信
  ///
  /// バッファ確保の連続失敗が 10 回に達すると自動停止する。
  /// vImage 変換失敗時はフレームをスキップする。
  private func onTimer() {
    // 1. ARGB バッファを確保
    guard let argbBuffer = createARGBBuffer() else {
      consecutiveFailureCount += 1
      if consecutiveFailureCount >= 10 {
        Logger.error(
          type: .user("DummyVideoCapturer"),
          message: "DummyVideoCapturer stopped due to consecutive failures")
        stop()
      }
      return
    }
    consecutiveFailureCount = 0

    // 2. カラーバーを描画
    drawColorBar(to: argbBuffer)

    // 3. ARGB → YpCbCr 変換（変換失敗時はフレームスキップ）
    guard let yuvBuffer = convertToYpCbCr(from: argbBuffer) else {
      Logger.error(
        type: .user("DummyVideoCapturer"),
        message: "DummyVideoCapturer vImageConvert failed, frame skipped")
      return
    }

    // 4. RTCVideoFrame を構築（タイムスタンプは systemUptime 基準）
    let pixelBuffer = RTCCVPixelBuffer(pixelBuffer: yuvBuffer)
    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
    let elapsedNs = Int64(elapsed * 1_000_000_000)
    let frame = RTCVideoFrame(
      buffer: pixelBuffer, rotation: RTCVideoRotation._0, timeStampNs: elapsedNs)
    let videoFrame = VideoFrame.native(capturer: nil, frame: frame)

    // 5. MediaStream に送信
    if let stream {
      stream.send(videoFrame: videoFrame)
      frameCount += 1
    } else {
      Logger.warn(
        type: .user("DummyVideoCapturer"),
        message: "DummyVideoCapturer stream is nil, frame discarded")
    }
  }

  // MARK: - バッファ操作

  /// ARGB 形式の CVPixelBuffer を確保する
  ///
  /// カラーバー描画に使用する。CGContext 互換のため
  /// `kCVPixelBufferCGImageCompatibilityKey` と
  /// `kCVPixelBufferCGBitmapContextCompatibilityKey` を有効にする。
  private func createARGBBuffer() -> CVPixelBuffer? {
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferMetalCompatibilityKey: false,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(width),
      Int(height),
      kCVPixelFormatType_32ARGB,
      attrs as CFDictionary,
      &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      return nil
    }
    return buffer
  }

  /// YpCbCr 4:2:0 BiPlanar Full Range 形式の CVPixelBuffer を確保する
  ///
  /// `vImageConvert_ARGB8888To420Yp8_CbCr8` の出力先。
  /// `RTCVideoFrame` に渡すため `RTCCVPixelBuffer` でラップする前提。
  private func createYUVBuffer() -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(width),
      Int(height),
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      nil,
      &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      return nil
    }
    return buffer
  }

  private func drawColorBar(to buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
      return
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))

    guard
      let context = CGContext(
        data: baseAddress,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue)
    else {
      return
    }

    let colors = Self.colorBarColors
    let stripeWidth = Int(width) / colors.count
    let remainder = Int(width) % colors.count
    for (i, color) in colors.enumerated() {
      context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
      let x = i * stripeWidth
      let w = stripeWidth + (i == colors.count - 1 ? remainder : 0)
      context.fill(CGRect(x: x, y: 0, width: w, height: Int(height)))
    }
    context.flush()
  }

  /// ARGB → YpCbCr 4:2:0 BiPlanar Full Range 変換
  ///
  /// `vImageConvert_ARGB8888To420Yp8_CbCr8` を使用する。
  /// BT.601 の変換行列と Full Range (0-255) のピクセル範囲を指定する。
  /// 出力先の Y プレーンは幅×高さ、CbCr プレーンは幅/2×高さ/2 のサイズ。
  private func convertToYpCbCr(from srcBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    guard let dstBuffer = createYUVBuffer() else {
      return nil
    }

    CVPixelBufferLockBaseAddress(srcBuffer, .readOnly)
    CVPixelBufferLockBaseAddress(dstBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(srcBuffer, .readOnly)
      CVPixelBufferUnlockBaseAddress(dstBuffer, [])
    }

    guard let srcBaseAddress = CVPixelBufferGetBaseAddress(srcBuffer),
      let yPlane = CVPixelBufferGetBaseAddressOfPlane(dstBuffer, 0),
      let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(dstBuffer, 1)
    else {
      return nil
    }

    var src = vImage_Buffer(
      data: srcBaseAddress,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRow(srcBuffer))

    var dstY = vImage_Buffer(
      data: yPlane,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dstBuffer, 0))

    var dstCbCr = vImage_Buffer(
      data: cbcrPlane,
      height: vImagePixelCount(height / 2),
      width: vImagePixelCount(width / 2),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dstBuffer, 1))

    var pixelRange = vImage_YpCbCrPixelRange(
      Yp_bias: 0, CbCr_bias: 128,
      YpRangeMax: 255, CbCrRangeMax: 255,
      YpMax: 255, YpMin: 0,
      CbCrMax: 255, CbCrMin: 0)
    var info = vImage_ARGBToYpCbCr()
    _ = vImageConvert_ARGBToYpCbCr_GenerateConversion(
      kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
      &pixelRange, &info,
      kvImageARGB8888, kvImage420Yp8_CbCr8,
      vImage_Flags(kvImageNoFlags))
    var permuteMap: [UInt8] = [0, 1, 2, 3]  // ARGB → RGB そのまま

    let error = vImageConvert_ARGB8888To420Yp8_CbCr8(
      &src, &dstY, &dstCbCr,
      &info, &permuteMap,
      vImage_Flags(kvImageNoFlags))

    guard error == kvImageNoError else {
      return nil
    }

    return dstBuffer
  }
}
