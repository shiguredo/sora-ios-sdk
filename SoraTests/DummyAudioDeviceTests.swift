import XCTest

@testable import Sora

/// E2E テストと単体テストで利用する 440Hz 正弦波ジェネレーター
///
/// DummyAudioDevice の pcmGenerator (`@Sendable`) として注入する。
/// サンプルごとに位相を進めて保持するため、フレーム境界 (20ms) を跨いでも
/// 波形が不連続にならず、クリックノイズが発生しない。
///
/// `@unchecked Sendable` としているのは、可変状態が `phase` だけで、その読み書きを
/// すべて `lock` で排他しているためである (ADM の音声スレッドから呼ばれる)。
final class SineWaveGenerator: @unchecked Sendable {
  private let lock = NSLock()
  private var phase: Double = 0
  private let frequency: Double

  init(frequency: Double) {
    self.frequency = frequency
  }

  /// 生成した累積時間 (秒)
  ///
  /// 並行呼び出しで位相の更新が失われないことをテストから確認するために公開する。
  var elapsedTime: Double {
    lock.lock()
    defer { lock.unlock() }
    return phase
  }

  /// 正弦波の PCM データを生成する
  /// - Parameter data: データ書き込み先
  /// - Parameter frameCount: フレーム数
  /// - Parameter sampleRate: サンプルレート
  func generate(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double) {
    lock.lock()
    defer { lock.unlock() }
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
///
/// `@unchecked Sendable` としているのは、可変状態が `time` だけで、その読み書きを
/// すべて `lock` で排他しているためである (ADM の音声スレッドから呼ばれる)。
final class StereoSineWaveGenerator: @unchecked Sendable {
  private let lock = NSLock()
  private var time: Double = 0

  /// 生成した累積時間 (秒)
  ///
  /// 並行呼び出しで位相の更新が失われないことをテストから確認するために公開する。
  var elapsedTime: Double {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  func generate(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double) {
    lock.lock()
    defer { lock.unlock() }
    let pcm = data.assumingMemoryBound(to: Int16.self)
    for frame in 0..<frameCount {
      pcm[frame * 2] = Int16(sin(2 * .pi * 600 * time) * 9830)
      pcm[frame * 2 + 1] = Int16(sin(2 * .pi * 1200 * time) * 9830)
      time += 1 / sampleRate
    }
  }
}

/// ADM の再生 PCM から左右の周波数成分を測る。受信した実データだけを判定する。
///
/// `@unchecked Sendable` としているのは、可変状態が `separatedDuration` だけで、その読み書きを
/// すべて `lock` で排他しているためである (ADM の音声スレッドから呼ばれる)。
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

/// pcmGenerator が呼ばれたかどうかを callback とテストスレッドで共有する箱
///
/// pcmGenerator は `@Sendable` な closure のため可変な `var` を capture できない。
/// `@unchecked Sendable` としているのは、可変状態が `called` だけで、その読み書きをすべて
/// `lock` で排他しているためである (注入先の pcmGenerator は ADM の音声スレッドからも呼ばれ得る)。
private final class CallFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var called = false

  var isCalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return called
  }

  func set() {
    lock.lock()
    called = true
    lock.unlock()
  }
}

/// DummyAudioDevice の単体テスト
///
/// `DummyAudioDevice` 自体は次の点を検証する。
///
/// - チャンネル数の既定値と 2 ch 指定の反映、2 ch 指定によるステレオ SDP の要求
/// - `fillPCMData` が外部注入された pcmGenerator へ委譲すること
/// - ハードミュート制御と、`terminateDevice` で初期状態へ戻ること
///
/// 併せてテスト用ヘルパーの動作を検証する。
///
/// - 生成器 (`SineWaveGenerator` / `StereoSineWaveGenerator`) の周波数・位相の連続性・並行利用
/// - ステレオ判定器 (`StereoToneProbe`) が無音・左右交換・モノラル化を成功扱いしないこと
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
    XCTAssertNoThrow(
      try MediaChannel.validate(
        snapshot: ConnectionConfigurationSnapshot(configuration: configuration)))
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
    let generatorCalled = CallFlag()
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in
      generatorCalled.set()
    }

    let dataSize = 960 * MemoryLayout<Int16>.size
    let data = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 1)
    defer { data.deallocate() }
    device.fillPCMData(data: data, frameCount: 960, sampleRate: 48000)

    XCTAssertTrue(generatorCalled.isCalled, "fillPCMData は pcmGenerator を呼ぶべき")
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

  /// 生成器の lock が並行呼び出しで位相の更新を失わないことを確認する
  ///
  /// ADM は lifecycle メソッドを直列化するが、テストから `fillPCMData` を直接呼ぶ経路とは
  /// 交差し得るため、生成器の可変状態は複数スレッドから保護されている必要がある。
  ///
  /// このテストは競合が起きれば必ず落ちる (位相が総フレーム数に一致しなくなる) が、
  /// `concurrentPerform` の並列度は保証されないため、単体では best-effort の検出である。
  /// lock を外した場合の検出は Thread Sanitizer を有効にした実行を最終的な検出器とする。
  func testGeneratorsAreSafeForConcurrentUse() {
    /// 同じ生成器を並行に呼び、位相が総フレーム数ぶん前進したことを確認する
    ///
    /// 書き込み先は生成器が書き込む分 (`channelCount × frameCount` の Int16) を確保する。
    /// `iterations` × `frameCount` は 61440 サンプルで、位相の期待値 1.28 秒に対する
    /// 加算の丸め誤差の上限 (約 1e-11) より十分大きい 1e-9 を許容誤差にする。
    func verify(
      generate: @Sendable (UnsafeMutableRawPointer, Int, Double) -> Void,
      elapsedTime: () -> Double,
      channels: Int,
      name: String
    ) {
      let iterations = 64
      let frameCount = 960
      let sampleRate = 48000.0
      DispatchQueue.concurrentPerform(iterations: iterations) { _ in
        let data = UnsafeMutableRawPointer.allocate(
          byteCount: frameCount * channels * MemoryLayout<Int16>.size, alignment: 1)
        defer { data.deallocate() }
        generate(data, frameCount, sampleRate)
      }

      XCTAssertEqual(
        elapsedTime(), Double(iterations * frameCount) / sampleRate, accuracy: 1e-9,
        "\(name) が並行呼び出しでも総フレーム数ぶん位相を進めること")
    }

    let sine = SineWaveGenerator(frequency: 440)
    verify(
      generate: sine.generate, elapsedTime: { sine.elapsedTime }, channels: 1,
      name: "SineWaveGenerator")

    let stereo = StereoSineWaveGenerator()
    verify(
      generate: stereo.generate, elapsedTime: { stereo.elapsedTime }, channels: 2,
      name: "StereoSineWaveGenerator")
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

    _ = device.setHardMute(true)
    XCTAssertTrue(device.isHardMuted, "setHardMute(true) でミュートになるべき")

    _ = device.setHardMute(false)
    XCTAssertFalse(device.isHardMuted, "setHardMute(false) でミュートが解除されるべき")
  }

  /// terminateDevice で初期のハードミュート状態へ戻ることを確認する
  ///
  /// `Configuration.initialMicrophoneEnabled` は接続時点の状態を定めるため、接続をまたいで
  /// `setAudioHardMute` の状態を持ち越さない。持ち越すと再接続後も無音のままになる。
  func testTerminateRestoresInitialHardMute() {
    let device = DummyAudioDevice(initialMicrophoneEnabled: true) { _, _, _ in }
    _ = device.setHardMute(true)
    XCTAssertTrue(device.isHardMuted, "setHardMute(true) でミュートになるべき")

    XCTAssertTrue(device.terminateDevice(), "terminateDevice が成功すること")
    XCTAssertFalse(device.isHardMuted, "terminate 後に初期状態 (ミュートなし) へ戻るべき")

    let mutedDevice = DummyAudioDevice(initialMicrophoneEnabled: false) { _, _, _ in }
    _ = mutedDevice.setHardMute(false)
    XCTAssertFalse(mutedDevice.isHardMuted, "setHardMute(false) でミュートが解除されるべき")

    XCTAssertTrue(mutedDevice.terminateDevice(), "terminateDevice が成功すること")
    XCTAssertTrue(mutedDevice.isHardMuted, "terminate 後に初期状態 (ミュート) へ戻るべき")
  }
}
