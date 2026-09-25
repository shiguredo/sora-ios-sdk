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
///
/// 可変状態はすべて `State` が持ち、読み書きは `withState` で `stateLock` を取って行う。
/// `RTCAudioDevice` のプロトコルメソッドは ADM スレッドから呼ばれる一方、timer の event handler は
/// `recordingQueue` / `playoutQueue` で、`terminateDevice` は接続の切断を実行したスレッドで走るため、
/// 状態ごとに別々の排他を置かずに 1 つの lock へ統一する。
///
/// `withState` の中から delegate、pcmGenerator、AUAudioUnit を呼ばない。
/// これらは lock の外で呼ぶ (lock を保持したまま callback を呼ぶと、callback が別スレッドから
/// 同じ lock を取る経路で deadlock する)。
final class DummyAudioDevice: NSObject, RTCAudioDevice {

  /// PCM データ生成処理。
  /// 第 1 引数: データ書き込み先、第 2 引数: フレーム数、第 3 引数: サンプルレート
  ///
  /// ADM の音声スレッドから呼ばれるため `@Sendable` とし、生成器側の可変状態は
  /// 生成器が排他する (呼び出し側では排他しない)。
  private let pcmGenerator:
    @Sendable (_ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double) -> Void

  /// 入出力のチャンネル数。PCM は L、R の順の interleaved Int16 とする。
  private let channelCount: Int
  /// 指定時は音声ハードウェアを使わず、ADM から取り出した再生 PCM を同期的に渡す。
  /// バッファは callback の間だけ有効であり、保持する場合はコピーすること。
  private let playoutHandler: (@Sendable (UnsafeBufferPointer<Int16>, Double) -> Void)?

  /// DummyAudioDevice が持つ可変状態
  ///
  /// すべての読み書きを `stateLock` で排他する。timer と audioUnit もこの型が所有し、
  /// timer の generation で「差し替え・停止のあとに届いた callback」を識別する。
  private struct State {
    /// delegate は弱参照で保持する (ADM が所有する)
    weak var delegate: RTCAudioDeviceDelegate?

    var isInitialized = false
    var isPlayoutInitialized = false
    var isPlaying = false
    var isRecordingInitialized = false
    var isRecording = false

    /// ハードミュート状態。initialMicrophoneEnabled = false の場合は初期状態でミュートする
    /// (Configuration.initialMicrophoneEnabled の契約をダミー音声経路でも守る)
    var isHardMuted = false

    /// 録音タイマーと、その callback を識別する世代
    var recordingTimer: DispatchSourceTimer?
    var recordingGeneration: UInt64 = 0

    /// 再生タイマーと、その callback を識別する世代
    var playoutTimer: DispatchSourceTimer?
    var playoutGeneration: UInt64 = 0

    /// AUAudioUnit (RemoteIO)。操作は ADM スレッドに限定する (「再生 (Playout)」を参照)
    var audioUnit: AUAudioUnit?
  }

  /// 録音用
  private let recordingQueue = DispatchQueue(
    label: "jp.shiguredo.sora.dummy-audio.recording")
  /// 再生用
  private let playoutQueue = DispatchQueue(label: "jp.shiguredo.sora.dummy-audio.playout")

  private let stateLock = NSLock()
  private var state = State()

  /// state を lock 付きで読み書きする
  ///
  /// `body` の中から delegate、pcmGenerator、AUAudioUnit を呼ばないこと (上の注意を参照)。
  private func withState<T>(_ body: (inout State) -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body(&state)
  }

  /// 初期化する
  /// - Parameter initialMicrophoneEnabled: 初期状態でハードミュートするかどうか
  /// - Parameter channelCount: 入出力のチャンネル数。1 または 2 を指定する
  /// - Parameter playoutHandler: 再生 PCM の取得処理。指定時は AudioSession と音声ハードウェアを使わない
  /// - Parameter pcmGenerator: PCM データ生成処理 (波形の内容を決める)。ADM の音声スレッドから呼ばれる
  init(
    initialMicrophoneEnabled: Bool,
    channelCount: Int = 1,
    playoutHandler: (@Sendable (UnsafeBufferPointer<Int16>, Double) -> Void)? = nil,
    pcmGenerator:
      @escaping @Sendable (
        _ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double
      ) -> Void
  ) {
    precondition((1...2).contains(channelCount), "channelCount must be 1 or 2")
    self.channelCount = channelCount
    self.playoutHandler = playoutHandler
    self.pcmGenerator = pcmGenerator
    state.isHardMuted = !initialMicrophoneEnabled
    super.init()
  }

  // 異常経路で terminateDevice が呼ばれずに解放された場合に備える。
  // この時点で self への強参照は残っていないため、lock の競合は起きない
  deinit {
    let timers = withState { state -> [DispatchSourceTimer] in
      let timers = [state.recordingTimer, state.playoutTimer].compactMap { $0 }
      state.recordingTimer = nil
      state.playoutTimer = nil
      return timers
    }
    for timer in timers {
      timer.cancel()
    }
  }

  // MARK: - RTCAudioDevice プロパティ

  /// delegate を lock 付きで取得する。
  /// 弱参照のため、取得した時点で強参照としてローカルに保持する必要がある
  private func lockedDelegate() -> RTCAudioDeviceDelegate? {
    withState { $0.delegate }
  }

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

  // 同期 getter は ADM スレッドと任意のスレッドから読まれるため、すべて同じ lock で読む
  var isInitialized: Bool { withState { $0.isInitialized } }
  var isPlayoutInitialized: Bool { withState { $0.isPlayoutInitialized } }
  var isPlaying: Bool { withState { $0.isPlaying } }
  var isRecordingInitialized: Bool { withState { $0.isRecordingInitialized } }
  var isRecording: Bool { withState { $0.isRecording } }
  var isHardMuted: Bool { withState { $0.isHardMuted } }

  // MARK: - RTCAudioDevice メソッド

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    withState { $0.delegate = delegate }

    // PCM を callback で消費する場合は、マイク・スピーカー・共有 AudioSession に触れない。
    if playoutHandler != nil {
      withState { $0.isInitialized = true }
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
      // isInitialized は true に設定したままにする。false のままだと 2 回目以降の
      // ADM の Init で再初期化が試みられ、録音・再生が不安定になるためである
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to configure AVAudioSession: \(error.localizedDescription)")
    }

    withState { $0.isInitialized = true }
    return true
  }

  func terminateDevice() -> Bool {
    let stop: () -> Void = { [weak self] in
      guard let self else { return }
      // 世代を進めてから timer を外す。発火済みの callback は世代が一致しないため破棄される
      let (timers, audioUnit) = self.withState {
        state -> ([DispatchSourceTimer], AUAudioUnit?) in
        state.recordingGeneration += 1
        state.playoutGeneration += 1
        let timers = [state.recordingTimer, state.playoutTimer].compactMap { $0 }
        let audioUnit = state.audioUnit
        state.recordingTimer = nil
        state.playoutTimer = nil
        state.audioUnit = nil
        state.isRecording = false
        state.isRecordingInitialized = false
        state.isPlaying = false
        state.isPlayoutInitialized = false
        return (timers, audioUnit)
      }
      // callback と AudioUnit は lock の外で停止する
      for timer in timers {
        timer.cancel()
      }
      audioUnit?.stopHardware()
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(stop)
    } else {
      stop()
    }
    withState {
      $0.delegate = nil
      $0.isInitialized = false
    }
    return true
  }

  // MARK: - 再生 (Playout)

  /// AUAudioUnit (RemoteIO) の操作は ADM スレッドに限定する。
  ///
  /// `initializePlayout` / `startPlayout` / `stopPlayout` は ADM が呼び、
  /// `terminateDevice` の後始末は delegate の ADM executor へ dispatch してから行う。
  /// `deinit` は AudioUnit を触らない (所有権は ADM にある)。
  func initializePlayout() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    if playoutHandler != nil {
      withState { $0.isPlayoutInitialized = true }
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

    withState {
      $0.audioUnit = au
      $0.isPlayoutInitialized = true
    }
    return true
  }

  func startPlayout() -> Bool {
    if playoutHandler != nil {
      // 起動可否の確認と delegate の取得を同じ lock 区間で行う
      let delegate = withState { state -> RTCAudioDeviceDelegate? in
        state.isPlayoutInitialized ? state.delegate : nil
      }
      guard let delegate else { return false }
      let timer = DispatchSource.makeTimerSource(queue: playoutQueue)
      let interval = delegate.preferredOutputIOBufferDuration
      timer.schedule(deadline: .now() + interval, repeating: interval)
      // 世代を進めてから差し替え、外したタイマーの callback を破棄する
      let (previous, generation) = withState {
        state -> (DispatchSourceTimer?, UInt64) in
        state.playoutGeneration += 1
        let previous = state.playoutTimer
        state.playoutTimer = timer
        state.isPlaying = true
        return (previous, state.playoutGeneration)
      }
      timer.setEventHandler { [weak self, weak delegate] in
        // ADM は同一スレッドでの callback を要求するため、タイマーの実行スレッドは使わない。
        delegate?.dispatchAsync { [weak self] in
          self?.consumePlayoutData(generation: generation)
        }
      }
      previous?.cancel()
      timer.resume()
      return true
    }

    guard let audioUnit = withState({ $0.audioUnit }) else { return false }
    do {
      try audioUnit.startHardware()
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to start hardware: \(error.localizedDescription)")
      return false
    }
    withState { $0.isPlaying = true }
    return true
  }

  func stopPlayout() -> Bool {
    let (timer, audioUnit) = withState {
      state -> (DispatchSourceTimer?, AUAudioUnit?) in
      // 世代を進めて、発火済みの callback を無効化する
      state.playoutGeneration += 1
      let timer = state.playoutTimer
      let audioUnit = state.audioUnit
      state.playoutTimer = nil
      state.isPlaying = false
      return (timer, audioUnit)
    }
    // callback と AudioUnit は lock の外で停止する
    timer?.cancel()
    audioUnit?.stopHardware()
    return true
  }

  /// 音声デバイスを起動せずに実際の ADM の再生データを取得する。ADM スレッドから呼ぶ。
  private func consumePlayoutData(generation: UInt64) {
    // 停止済み・再起動済みの世代の callback はここで破棄する
    let (isCurrent, delegate) = withState {
      state -> (Bool, RTCAudioDeviceDelegate?) in
      (state.isPlaying && state.playoutGeneration == generation, state.delegate)
    }
    guard isCurrent, let delegate, let playoutHandler else { return }

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
    withState { $0.isRecordingInitialized = true }
    return true
  }

  func startRecording() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
    let interval = delegate.preferredInputIOBufferDuration
    let intervalNs = Int(interval * Double(NSEC_PER_SEC))

    // ADM 側が recording フラグを立てる前に届いた最初のフレームが破棄されるため、
    // 1 インターバル分遅らせて開始する
    timer.schedule(
      deadline: .now() + .nanoseconds(intervalNs),
      repeating: .nanoseconds(intervalNs))

    // 既存タイマーが残っている場合は先に外す。
    // Offer SDP 作成のたびに startRecording が呼ばれ得るため、再入は安全でなければならない。
    // 世代を進めてから差し替え、外したタイマーの callback を破棄する
    let (previous, generation) = withState {
      state -> (DispatchSourceTimer?, UInt64) in
      state.recordingGeneration += 1
      let previous = state.recordingTimer
      state.recordingTimer = timer
      state.isRecording = true
      return (previous, state.recordingGeneration)
    }
    timer.setEventHandler { [weak self, weak delegate] in
      // キューのワーカースレッドが変わっても、ADM への PCM 注入は同じスレッドに固定する。
      delegate?.dispatchAsync { [weak self] in
        self?.deliverPCMData(generation: generation)
      }
    }
    previous?.cancel()
    timer.resume()
    return true
  }

  func stopRecording() -> Bool {
    let timer = withState { state -> DispatchSourceTimer? in
      // 世代を進めて、発火済みの callback を無効化する
      state.recordingGeneration += 1
      let timer = state.recordingTimer
      state.recordingTimer = nil
      state.isRecording = false
      return timer
    }
    timer?.cancel()
    return true
  }

  /// ハードミュートを有効化/無効化する
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`
  func setHardMute(_ mute: Bool) -> Bool {
    let update: () -> Void = { [weak self] in
      self?.withState { $0.isHardMuted = mute }
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(update)
    } else {
      update()
    }
    return true
  }

  private func deliverPCMData(generation: UInt64) {
    // 終了済み・停止済み・再起動済み・ミュート中の録音は実行せず、注入中は delegate の強参照を保持する。
    // 判定と強参照の取得を同じ lock 区間で行い、delegate の利用は lock の外で行う
    let (isCurrent, isHardMuted, delegate) = withState {
      state -> (Bool, Bool, RTCAudioDeviceDelegate?) in
      let isCurrent = state.isRecording && state.recordingGeneration == generation
      return (isCurrent, state.isHardMuted, state.delegate)
    }

    guard isCurrent, let delegate else { return }

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
