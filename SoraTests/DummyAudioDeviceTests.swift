import XCTest

@testable import Sora

/// E2E テストと単体テストで利用する 440Hz 正弦波ジェネレーター
///
/// DummyAudioDevice の pcmGenerator として注入する。
/// サンプルごとに位相を進めて保持するため、フレーム境界 (20ms) を跨いでも
/// 波形が不連続にならず、クリックノイズが発生しない。
final class SineWaveGenerator {
  private var phase: Double = 0
  private let frequency: Double

  init(frequency: Double) {
    self.frequency = frequency
  }

  /// 正弦波の PCM データを生成する
  /// - Parameter data: データ書き込み先
  /// - Parameter frameCount: フレーム数
  /// - Parameter sampleRate: サンプルレート
  func generate(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double) {
    let pcm = data.assumingMemoryBound(to: Int16.self)
    // 波形は sin(2π × 周波数 × 時刻) で表され、時刻は位相 (phase) で管理する。
    // 振幅はフルスケール (Int16 の最大値 32767) の 30% とする。
    // フルスケールで連続再生するとクリッピングの恐れがあるため、余裕を持たせている。
    let amplitude = 32767.0 * 0.3
    for i in 0..<frameCount {
      let value = Int16(sin(2.0 * .pi * frequency * phase) * amplitude)
      pcm[i] = value
      // サンプルごとに位相を 1 / サンプルレート 秒進める
      phase += 1.0 / sampleRate
    }
  }
}

/// 左を 600 Hz、右を 1200 Hz とする、左右を区別できるステレオ音源。
final class StereoSineWaveGenerator {
  private var time: Double = 0

  func generate(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double) {
    let pcm = data.assumingMemoryBound(to: Int16.self)
    for frame in 0..<frameCount {
      pcm[frame * 2] = Int16(sin(2 * .pi * 600 * time) * 9830)
      pcm[frame * 2 + 1] = Int16(sin(2 * .pi * 1200 * time) * 9830)
      time += 1 / sampleRate
    }
  }
}

/// ADM の再生 PCM から左右の周波数成分を測る。受信した実データだけを判定する。
/// callback とテストスレッドの共有カウンターはロックで保護する。
final class StereoToneProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var separatedDuration: Double = 0

  var stereoDuration: Double {
    lock.lock()
    defer { lock.unlock() }
    return separatedDuration
  }

  func consume(_ samples: UnsafeBufferPointer<Int16>, sampleRate: Double) {
    let frames = samples.count / 2
    guard frames > 0, samples.count.isMultiple(of: 2), sampleRate > 0 else { return }
    // 位相はエンコードやジッタバッファで変わるため、sin と cos の両成分の二乗和を使う。
    func power(channel: Int, frequency: Double) -> Double {
      var real = 0.0
      var imaginary = 0.0
      for frame in 0..<frames {
        let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
        let sample = Double(samples[frame * 2 + channel])
        real += sample * cos(phase)
        imaginary += sample * sin(phase)
      }
      return (real * real + imaginary * imaginary) / Double(frames * frames)
    }
    let left600 = power(channel: 0, frequency: 600)
    let left1200 = power(channel: 0, frequency: 1200)
    let right600 = power(channel: 1, frequency: 600)
    let right1200 = power(channel: 1, frequency: 1200)
    // 圧縮による漏れは許容するが、無音・左右交換・モノラル化後の複製は成功にしない。
    guard left600 > 100_000, right1200 > 100_000,
      left600 > left1200 * 8, right1200 > right600 * 8
    else { return }
    lock.lock()
    separatedDuration += Double(frames) / sampleRate
    lock.unlock()
  }
}

/// DummyAudioDevice の単体テスト
///
/// PCM 生成 (fillPCMData) は外部注入された pcmGenerator への委譲のみであるため、
/// 注入するジェネレーター (SineWaveGenerator) の動作と、
/// DummyAudioDevice のハードミュート制御を検証する。
final class DummyAudioDeviceTests: XCTestCase {

  /// チャンネル数の既定値を維持しつつ、2 ch 指定を入出力の双方へ反映する。
  func testChannelCounts() {
    let mono = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }
    let stereo = DummyAudioDevice(initialMicrophoneEnabled: true, channelCount: 2) { _, _, _ in }
    XCTAssertEqual(mono.inputNumberOfChannels, 1)
    XCTAssertEqual(mono.outputNumberOfChannels, 1)
    XCTAssertEqual(stereo.inputNumberOfChannels, 2)
    XCTAssertEqual(stereo.outputNumberOfChannels, 2)
  }

  /// ネイティブ ADM の切替とは独立に、カスタムデバイスの 2 ch 再生要求を SDP へ渡す。
  func testCustomStereoDeviceRequestsStereoSDP() throws {
    var configuration = Configuration(
      url: try XCTUnwrap(URL(string: "wss://example.invalid")), channelId: "test", role: .recvonly)
    XCTAssertFalse(configuration.requiresStereoAudioSDP)
    configuration.audioDevice = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }
    XCTAssertFalse(configuration.requiresStereoAudioSDP)
    configuration.audioDevice = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2
    ) { _, _, _ in }
    XCTAssertTrue(configuration.requiresStereoAudioSDP)
    XCTAssertFalse(configuration.audioStereoOutputEnabled)
    XCTAssertNoThrow(try MediaChannel.validate(configuration: configuration))
  }

  /// 判定器自身が無音・左右交換・モノラル化を検出することを実 PCM で確認する。
  func testStereoProbeRejectsSilenceSwappedAndMixedChannels() {
    let generator = StereoSineWaveGenerator()
    let device = DummyAudioDevice(
      initialMicrophoneEnabled: true, channelCount: 2, pcmGenerator: generator.generate)
    var stereo = [Int16](repeating: 0, count: 960 * 2)
    stereo.withUnsafeMutableBytes {
      device.fillPCMData(data: $0.baseAddress!, frameCount: 960)
    }
    let correct = StereoToneProbe()
    stereo.withUnsafeBufferPointer { correct.consume($0, sampleRate: 48000) }
    XCTAssertEqual(correct.stereoDuration, 0.02, accuracy: 0.000001)

    for transformation in 0..<4 {
      var invalid = stereo
      for frame in 0..<960 {
        let left = stereo[frame * 2]
        let right = stereo[frame * 2 + 1]
        switch transformation {
        case 0:
          invalid[frame * 2] = 0
          invalid[frame * 2 + 1] = 0
        case 1:
          invalid[frame * 2] = right
          invalid[frame * 2 + 1] = left
        case 2:
          let mixed = Int16((Int(left) + Int(right)) / 2)
          invalid[frame * 2] = mixed
          invalid[frame * 2 + 1] = mixed
        default:
          invalid[frame * 2 + 1] = 0
        }
      }
      let probe = StereoToneProbe()
      invalid.withUnsafeBufferPointer { probe.consume($0, sampleRate: 48000) }
      XCTAssertEqual(probe.stereoDuration, 0, "不正な左右データを成功扱いしないこと: \(transformation)")
    }
  }

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

  /// fillPCMData が注入した pcmGenerator を呼ぶことを確認する
  func testFillPCMDataInvokesGenerator() {
    var generatorCalled = false
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in
      generatorCalled = true
    }

    let dataSize = 960 * MemoryLayout<Int16>.size
    let data = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 1)
    defer { data.deallocate() }
    device.fillPCMData(data: data, frameCount: 960, sampleRate: 48000)

    XCTAssertTrue(generatorCalled, "fillPCMData は pcmGenerator を呼ぶべき")
  }

  /// 全 0 を生成する pcmGenerator を注入した場合、全サンプルが 0 になることを確認する
  func testSilencePCMGeneratorProducesZeroSamples() {
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { data, frameCount, _ in
      let pcm = data.assumingMemoryBound(to: Int16.self)
      pcm.initialize(repeating: 0, count: frameCount)
    }

    let samples = readPCMData(device, frameCount: 960)

    XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "全 0 ジェネレーターのサンプルは全て 0 であるべき")
  }

  /// SineWaveGenerator が 440Hz の正弦波を生成することを確認する
  /// (負→正の符号反転が 1 秒あたり 440 ± 1 回になることを利用する)
  func testSineWaveGeneratorProducesExpectedFrequency() {
    let generator = SineWaveGenerator(frequency: 440)
    let sampleRate = 48000.0
    let dataSize = Int(sampleRate) * MemoryLayout<Int16>.size
    let data = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 1)
    defer { data.deallocate() }

    generator.generate(data: data, frameCount: Int(sampleRate), sampleRate: sampleRate)
    let pcm = data.assumingMemoryBound(to: Int16.self)
    let samples = Array(UnsafeBufferPointer(start: pcm, count: Int(sampleRate)))

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

  /// SineWaveGenerator がフレーム境界を跨いでも位相が連続すること (クリックノイズ防止) を確認する
  func testSineWaveGeneratorPhaseIsContinuousAcrossFrames() {
    let sampleRate = 48000.0

    // 1 回で 1920 サンプル生成した場合
    let wholeGenerator = SineWaveGenerator(frequency: 440)
    let wholeDataSize = 1920 * MemoryLayout<Int16>.size
    let wholeData = UnsafeMutableRawPointer.allocate(byteCount: wholeDataSize, alignment: 1)
    defer { wholeData.deallocate() }
    wholeGenerator.generate(data: wholeData, frameCount: 1920, sampleRate: sampleRate)
    let wholePcm = wholeData.assumingMemoryBound(to: Int16.self)
    let whole = Array(UnsafeBufferPointer(start: wholePcm, count: 1920))

    // 2 回に分けて生成した場合 (位相が保持される)
    let splitGenerator = SineWaveGenerator(frequency: 440)
    let splitDataSize = 960 * MemoryLayout<Int16>.size
    let splitData = UnsafeMutableRawPointer.allocate(byteCount: splitDataSize, alignment: 1)
    defer { splitData.deallocate() }
    splitGenerator.generate(data: splitData, frameCount: 960, sampleRate: sampleRate)
    let firstPcm = splitData.assumingMemoryBound(to: Int16.self)
    let first = Array(UnsafeBufferPointer(start: firstPcm, count: 960))
    splitGenerator.generate(data: splitData, frameCount: 960, sampleRate: sampleRate)
    let secondPcm = splitData.assumingMemoryBound(to: Int16.self)
    let second = Array(UnsafeBufferPointer(start: secondPcm, count: 960))
    let split = first + second

    XCTAssertEqual(whole, split, "フレーム境界を跨いでも位相が連続しているべき")
  }

  /// initialMicrophoneEnabled = false の場合、初期状態でハードミュートされることを確認する
  /// (Configuration.initialMicrophoneEnabled の契約をダミー音声経路でも守る)
  func testInitialMicrophoneDisabledStartsMuted() {
    let device = DummyAudioDevice(initialMicrophoneEnabled: false) { _, _, _ in }

    XCTAssertTrue(device.isHardMuted, "initialMicrophoneEnabled = false なら初期状態でミュートであるべき")
  }

  /// initialMicrophoneEnabled = true の場合、初期状態でミュートされていないことを確認する
  func testInitialMicrophoneEnabledStartsUnmuted() {
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }

    XCTAssertFalse(device.isHardMuted, "initialMicrophoneEnabled = true なら初期状態でミュートではないべき")
  }

  /// setHardMute でハードミュート状態が切り替わることを確認する
  /// (setAudioHardMute の契約をダミー音声経路でも守る)
  func testSetHardMuteTogglesState() {
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }

    device.setHardMute(true)
    XCTAssertTrue(device.isHardMuted, "setHardMute(true) でミュートになるべき")

    device.setHardMute(false)
    XCTAssertFalse(device.isHardMuted, "setHardMute(false) でミュートが解除されるべき")
  }
}
