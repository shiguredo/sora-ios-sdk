import AVFoundation
import AudioToolbox
import Foundation
import WebRTC

/// ダミー音声を生成・注入する RTCAudioDevice 実装
///
/// 物理マイクの代わりに DispatchSourceTimer で PCM データを生成して
/// delegate.deliverRecordedData で ADM に注入する。
/// 遠隔音声の再生は AUAudioUnit (RemoteIO) の outputProvider 経由で
/// delegate.getPlayoutData を呼び出す。
/// playoutHandler を指定した場合は、音声ハードウェアを起動せず再生 PCM を callback に渡す。
///
/// PCM データの生成 (波形の内容) は pcmGenerator として外部から注入する。
/// 波形のロジック (正弦波等) はテスト・デモの用途に依存するため、SDK 側では持たない。
///
/// delegate が未設定 (nil) の場合のデフォルト値は、サンプルレート 48000 Hz、
/// IO バッファ期間 0.02 秒 (20ms) である。
/// 接続時は delegate が選択する値 (preferredInputSampleRate /
/// preferredInputIOBufferDuration 等) を使用する。
final class DummyAudioDevice: NSObject, RTCAudioDevice {

  /// PCM データ生成処理。
  /// 第 1 引数: データ書き込み先、第 2 引数: フレーム数、第 3 引数: サンプルレート
  private let pcmGenerator:
    (_ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double)
      -> Void

  /// 入出力のチャンネル数。PCM は L、R の順の interleaved Int16 とする。
  private let channelCount: Int
  /// 指定時は音声ハードウェアを使わず、ADM から取り出した再生 PCM を同期的に渡す。
  /// バッファは callback の間だけ有効であり、保持する場合はコピーすること。
  private let playoutHandler: (@Sendable (UnsafeBufferPointer<Int16>, Double) -> Void)?

  // delegate と録音状態へのアクセスを保護する。
  // PCM の生成・注入は、タイマーから ADM スレッドへ dispatch した後に実行する。
  private let stateLock = NSLock()

  private weak var delegate: RTCAudioDeviceDelegate?

  /// delegate をロック付きで取得する。
  /// 弱参照のため、取得した時点で強参照としてローカルに保持する必要がある
  private func lockedDelegate() -> RTCAudioDeviceDelegate? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return delegate
  }

  // 録音用
  private var recordingTimer: DispatchSourceTimer?
  private let recordingQueue = DispatchQueue(
    label: "jp.shiguredo.sora.dummy-audio.recording")

  // 再生用
  private var audioUnit: AUAudioUnit?
  private var playoutTimer: DispatchSourceTimer?
  private let playoutQueue = DispatchQueue(label: "jp.shiguredo.sora.dummy-audio.playout")

  private var _isInitialized = false
  private var _isPlayoutInitialized = false
  private var _isPlaying = false
  private var _isRecordingInitialized = false
  private var _isRecording = false

  // ハードミュート状態。initialMicrophoneEnabled = false の場合は初期状態でミュートする
  // (Configuration.initialMicrophoneEnabled の契約をダミー音声経路でも守る)
  private(set) var isHardMuted: Bool

  /// 初期化する
  /// - Parameter initialMicrophoneEnabled: 初期状態でハードミュートするかどうか
  /// - Parameter channelCount: 入出力のチャンネル数。1 または 2 を指定する
  /// - Parameter playoutHandler: 再生 PCM の取得処理。指定時は AudioSession と音声ハードウェアを使わない
  /// - Parameter pcmGenerator: PCM データ生成処理 (波形の内容を決める)
  init(
    initialMicrophoneEnabled: Bool,
    channelCount: Int = 1,
    playoutHandler: (@Sendable (UnsafeBufferPointer<Int16>, Double) -> Void)? = nil,
    pcmGenerator:
      @escaping (
        _ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double
      ) -> Void
  ) {
    precondition((1...2).contains(channelCount), "channelCount must be 1 or 2")
    self.channelCount = channelCount
    self.playoutHandler = playoutHandler
    self.pcmGenerator = pcmGenerator
    self.isHardMuted = !initialMicrophoneEnabled
    super.init()
  }

  // 異常経路で terminateDevice が呼ばれずに解放された場合に備える
  deinit {
    recordingTimer?.cancel()
    playoutTimer?.cancel()
  }

  // MARK: - RTCAudioDevice プロパティ

  var deviceInputSampleRate: Double {
    lockedDelegate()?.preferredInputSampleRate ?? 48000
  }

  var inputIOBufferDuration: TimeInterval {
    lockedDelegate()?.preferredInputIOBufferDuration ?? 0.02
  }

  var inputNumberOfChannels: Int { channelCount }

  var inputLatency: TimeInterval { 0 }

  var deviceOutputSampleRate: Double {
    lockedDelegate()?.preferredOutputSampleRate ?? 48000
  }

  var outputIOBufferDuration: TimeInterval {
    lockedDelegate()?.preferredOutputIOBufferDuration ?? 0.02
  }

  var outputNumberOfChannels: Int { channelCount }

  var outputLatency: TimeInterval { 0 }

  var isInitialized: Bool { _isInitialized }
  var isPlayoutInitialized: Bool { _isPlayoutInitialized }
  var isPlaying: Bool { _isPlaying }
  var isRecordingInitialized: Bool { _isRecordingInitialized }
  var isRecording: Bool { _isRecording }

  // MARK: - RTCAudioDevice メソッド

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    stateLock.lock()
    self.delegate = delegate
    stateLock.unlock()

    // PCM を callback で消費する場合は、マイク・スピーカー・共有 AudioSession に触れない。
    if playoutHandler != nil {
      _isInitialized = true
      return true
    }

    // RTCAudioDevice 実装は AVAudioSession の設定責務を持つ (RTCAudioDevice.h)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker])
      try session.setActive(true)
    } catch {
      // 失敗時も true を返す。false を返すと ADM の初期化失敗となり、
      // 接続処理がクラッシュする (adm_helpers.cc の RTC_CHECK) ため、警告ログのみで継続する。
      // _isInitialized は true に設定したままにする。false のままだと 2 回目以降の
      // ADM の Init で再初期化が試みられ、録音・再生が不安定になるためである
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to configure AVAudioSession: \(error.localizedDescription)")
    }

    _isInitialized = true
    return true
  }

  func terminateDevice() -> Bool {
    let stop: () -> Void = { [weak self] in
      guard let self else { return }
      self.recordingTimer?.cancel()
      self.recordingTimer = nil
      self.playoutTimer?.cancel()
      self.playoutTimer = nil
      self.stateLock.lock()
      self._isRecording = false
      self._isRecordingInitialized = false
      self.stateLock.unlock()
      self.audioUnit?.stopHardware()
      self.audioUnit = nil
      self._isPlaying = false
      self._isPlayoutInitialized = false
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(stop)
    } else {
      stop()
    }
    stateLock.lock()
    self.delegate = nil
    stateLock.unlock()
    _isInitialized = false
    return true
  }

  // MARK: - 再生 (Playout)

  func initializePlayout() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    if playoutHandler != nil {
      _isPlayoutInitialized = true
      return true
    }

    let desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_RemoteIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0)

    guard let au = try? AUAudioUnit(componentDescription: desc) else {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to create AUAudioUnit")
      return false
    }
    au.isOutputEnabled = true
    au.isInputEnabled = false  // 録音は別経路（タイマー）のため入力不要
    au.maximumFramesToRender = 1024

    // outputProvider が提供するデータのフォーマットは inputBus 0 のフォーマットに従う。
    // ADM の OnGetPlayoutData は AudioBufferList が Int16 かつ 1〜2 チャネルであることを要求するため、
    // RemoteIO のデフォルト (Float32) ではなく Int16 フォーマットを inputBusses[0] に明示設定する
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: delegate.preferredOutputSampleRate,
      channels: AVAudioChannelCount(channelCount),
      interleaved: true)
    guard let format else { return false }
    do {
      try au.inputBusses[0].setFormat(format)
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to set output format: \(error.localizedDescription)")
      return false
    }

    let getPlayoutData = delegate.getPlayoutData
    au.outputProvider = {
      (actionFlags, timestamp, frameCount, inputBusNumber, outputData) -> AUAudioUnitStatus in
      return getPlayoutData(actionFlags, timestamp, inputBusNumber, frameCount, outputData)
    }

    do {
      try au.allocateRenderResources()
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to allocate render resources: \(error.localizedDescription)")
      return false
    }

    audioUnit = au
    _isPlayoutInitialized = true
    return true
  }

  func startPlayout() -> Bool {
    if playoutHandler != nil {
      guard let delegate = lockedDelegate(), _isPlayoutInitialized else { return false }
      playoutTimer?.cancel()
      _isPlaying = true
      let timer = DispatchSource.makeTimerSource(queue: playoutQueue)
      let interval = delegate.preferredOutputIOBufferDuration
      timer.schedule(deadline: .now() + interval, repeating: interval)
      timer.setEventHandler { [weak self, weak delegate] in
        // ADM は同一スレッドでの callback を要求するため、タイマーの実行スレッドは使わない。
        delegate?.dispatchAsync { [weak self] in
          self?.consumePlayoutData()
        }
      }
      timer.resume()
      playoutTimer = timer
      return true
    }
    guard let au = audioUnit else { return false }
    do {
      try au.startHardware()
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to start hardware: \(error.localizedDescription)")
      return false
    }
    _isPlaying = true
    return true
  }

  func stopPlayout() -> Bool {
    playoutTimer?.cancel()
    playoutTimer = nil
    audioUnit?.stopHardware()
    _isPlaying = false
    return true
  }

  /// 音声デバイスを起動せずに実際の ADM の再生データを取得する。ADM スレッドから呼ぶ。
  private func consumePlayoutData() {
    guard _isPlaying, let delegate = lockedDelegate(), let playoutHandler else { return }
    let sampleRate = delegate.preferredOutputSampleRate
    let frameCount = UInt32((sampleRate * delegate.preferredOutputIOBufferDuration) + 0.5)
    guard frameCount > 0 else { return }
    var samples = [Int16](repeating: 0, count: Int(frameCount) * channelCount)
    samples.withUnsafeMutableBytes { bytes in
      var buffers = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: UInt32(channelCount),
          mDataByteSize: UInt32(bytes.count),
          mData: bytes.baseAddress))
      var timestamp = AudioTimeStamp()
      timestamp.mFlags = .hostTimeValid
      timestamp.mHostTime = mach_absolute_time()
      var flags = AudioUnitRenderActionFlags()
      let result = delegate.getPlayoutData(&flags, &timestamp, 0, frameCount, &buffers)
      guard result == noErr else {
        Logger.warn(type: .dummyAudioDevice, message: "getPlayoutData failed with status \(result)")
        return
      }
      playoutHandler(UnsafeBufferPointer(bytes.bindMemory(to: Int16.self)), sampleRate)
    }
  }

  // MARK: - 録音 (Recording)

  func initializeRecording() -> Bool {
    _isRecordingInitialized = true
    return true
  }

  func startRecording() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    // 既存タイマーが残っている場合は先にキャンセルする。
    // Offer SDP 作成のたびに startRecording が呼ばれ得るため、再入は安全でなければならない
    recordingTimer?.cancel()

    stateLock.lock()
    _isRecording = true
    stateLock.unlock()

    let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
    let interval = delegate.preferredInputIOBufferDuration
    let intervalNs = Int(interval * Double(NSEC_PER_SEC))

    // ADM 側が recording フラグを立てる前に届いた最初のフレームが破棄されるため、
    // 1 インターバル分遅らせて開始する
    timer.schedule(
      deadline: .now() + .nanoseconds(intervalNs),
      repeating: .nanoseconds(intervalNs))
    timer.setEventHandler { [weak self, weak delegate] in
      // キューのワーカースレッドが変わっても、ADM への PCM 注入は同じスレッドに固定する。
      delegate?.dispatchAsync { [weak self] in
        self?.deliverPCMData()
      }
    }
    timer.resume()
    recordingTimer = timer
    return true
  }

  func stopRecording() -> Bool {
    recordingTimer?.cancel()
    recordingTimer = nil
    stateLock.lock()
    _isRecording = false
    stateLock.unlock()
    return true
  }

  /// ハードミュートを有効化/無効化する
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`
  func setHardMute(_ mute: Bool) -> Bool {
    let update: () -> Void = { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      self.isHardMuted = mute
      self.stateLock.unlock()
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(update)
    } else {
      update()
    }
    return true
  }

  private func deliverPCMData() {
    // 終了済み・ミュート中の録音は実行せず、注入中は delegate の強参照を保持する。
    stateLock.lock()
    let delegate = self.delegate
    let isRecording = _isRecording
    let isHardMuted = self.isHardMuted
    stateLock.unlock()

    guard let delegate, isRecording else { return }

    // ハードミュート中は録音データを送信しない
    // (Configuration.initialMicrophoneEnabled = false の契約と setAudioHardMute に対応する)
    if isHardMuted {
      return
    }

    let sampleRate = delegate.preferredInputSampleRate
    // ADM 側と同じ四捨五入でフレーム数を算出する (objc_audio_device.mm に合わせる)
    let frameCount = UInt32((sampleRate * delegate.preferredInputIOBufferDuration) + 0.5)
    // サンプルレート・IO バッファ期間が異常値の場合に備える
    guard frameCount > 0 else {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "invalid frame count: \(frameCount)")
      return
    }
    // ADM のジッタバッファ制御がタイムスタンプを参照するため、ホスト時刻と有効フラグを設定する
    // (mFlags がないと AudioTimeStampGetNanoseconds が nullopt を返し、時刻が無視される)
    var timestamp = AudioTimeStamp()
    timestamp.mFlags = .hostTimeValid
    timestamp.mHostTime = mach_absolute_time()
    var flags = AudioUnitRenderActionFlags()

    // libwebrtc の inputData 経路はフレーム数をサンプル数として扱い、2 ch では半分を失う。
    // renderBlock 経路ではチャンネル数を含むバッファ全体が渡るため、こちらで PCM を生成する。
    let result = delegate.deliverRecordedData(
      &flags, &timestamp, 0, frameCount, nil, nil
    ) { _, _, _, frames, buffers, _ in
      let buffer = buffers.pointee.mBuffers
      let requiredBytes = Int(frames) * self.channelCount * MemoryLayout<Int16>.size
      guard buffers.pointee.mNumberBuffers == 1,
        buffer.mNumberChannels == UInt32(self.channelCount),
        Int(buffer.mDataByteSize) >= requiredBytes, let data = buffer.mData
      else { return kAudio_ParamError }
      self.fillPCMData(data: data, frameCount: Int(frames), sampleRate: sampleRate)
      return noErr
    }
    if result != noErr {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "deliverRecordedData failed with status \(result)")
    }
  }

  /// PCM データを生成する。
  ///
  /// 単体テストから直接呼べるよう internal とし、サンプルレートは引数で受け取る。
  /// 波形の生成は pcmGenerator (外部注入) に委譲する。
  func fillPCMData(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double = 48000) {
    pcmGenerator(data, frameCount, sampleRate)
  }
}
