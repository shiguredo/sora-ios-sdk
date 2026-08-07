import XCTest

@testable import Sora

/// DummyAudioDevice の PCM 生成 (fillPCMData) の単体テスト
///
/// RTCAudioDeviceDelegate のテストダブルは作らず (AGENTS.md のモック・スタブ禁止)、
/// delegate を必要としない fillPCMData のみを検証する。
/// DummyAudioDevice のライフサイクルは実際の ADM 経由でのみ動作するため、E2E テストで検証する。
final class DummyAudioDeviceTests: XCTestCase {

  // fillPCMData で生成した PCM データを Int16 配列として読み出す
  private func readPCMData(
    _ device: DummyAudioDevice,
    frameCount: Int,
    sampleRate: Double = 48000
  ) -> [Int16] {
    let dataSize = frameCount * MemoryLayout<Int16>.size
    let data = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 1)
    defer { data.deallocate() }
    device.fillPCMData(data: data, frameCount: frameCount, sampleRate: sampleRate)
    let pcm = data.assumingMemoryBound(to: Int16.self)
    return Array(UnsafeBufferPointer(start: pcm, count: frameCount))
  }

  /// .silence の場合、全サンプルが 0 になることを確認する
  func testSilenceProducesZeroSamples() {
    let device = DummyAudioDevice(config: DummyAudioConfig(content: .silence))

    let samples = readPCMData(device, frameCount: 960)

    XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "silence のサンプルは全て 0 であるべき")
  }

  /// .sineWave(frequency: 440) の場合、負→正の符号反転が 1 秒あたり 440 ± 1 回になることを確認する
  func testSineWaveProducesExpectedFrequency() {
    let device = DummyAudioDevice(config: DummyAudioConfig(content: .sineWave(frequency: 440)))
    let sampleRate = 48000.0

    let samples = readPCMData(device, frameCount: Int(sampleRate), sampleRate: sampleRate)

    // 位相が 0 から始まるため先頭サンプルは 0 になり、境界の扱いで ±1 のずれが生じるため範囲判定にする
    var crossings = 0
    for i in 1..<samples.count {
      if samples[i - 1] < 0 && samples[i] >= 0 {
        crossings += 1
      }
    }
    XCTAssertTrue(
      (439...441).contains(crossings),
      "負→正の符号反転は 1 秒あたり 440 ± 1 回であるべき (実際: \(crossings))")
  }

  /// フレーム境界を跨いでも位相が連続すること (クリックノイズ防止) を確認する
  func testPhaseIsContinuousAcrossFrames() {
    let sampleRate = 48000.0

    // 1 回で 1920 サンプル生成した場合
    let wholeDevice = DummyAudioDevice(
      config: DummyAudioConfig(content: .sineWave(frequency: 440)))
    let whole = readPCMData(wholeDevice, frameCount: 1920, sampleRate: sampleRate)

    // 2 回に分けて生成した場合 (位相が保持される)
    let splitDevice = DummyAudioDevice(
      config: DummyAudioConfig(content: .sineWave(frequency: 440)))
    let first = readPCMData(splitDevice, frameCount: 960, sampleRate: sampleRate)
    let second = readPCMData(splitDevice, frameCount: 960, sampleRate: sampleRate)
    let split = first + second

    XCTAssertEqual(whole, split, "フレーム境界を跨いでも位相が連続しているべき")
  }
}
