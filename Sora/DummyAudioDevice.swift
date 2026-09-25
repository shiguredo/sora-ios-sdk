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
/// 可変状態はすべて `State` が持ち、読み書きは `withState` で `stateLock` を取って行う
/// (`init` と `deinit` は他スレッドから到達しないため直接読む)。
/// `RTCAudioDevice` のプロトコルメソッドは ADM スレッドから呼ばれる一方、timer の event handler は
/// `recordingQueue` / `playoutQueue` で、`terminateDevice` は接続の切断を実行したスレッドから
/// 呼ばれる (後始末は delegate があれば `dispatchSync` で ADM スレッドへ渡してから行う) ため、
/// 状態ごとに別々の排他を置かずに 1 つの lock へ統一する。
///
/// timer / AudioUnit / state フラグを差し込む開始処理 (startRecording / startPlayout /
/// initializePlayout / initializeRecording) は、準備 (delegate や間隔の取得) と差し込みが別の
/// lock 区間になる。差し込みは `withCurrentLifecycle` で `lifecycleGeneration` を確認してから
/// 行うため、準備の途中で `terminateDevice` が走った場合に停止後の state が書き換わることはない。
///
/// state が持つ timer は、停止側が常に `cancel` できるよう、`TimerSlot.install(_:)` が差し込みと
/// `resume()` を同じ lock 区間で行う。
///
/// `withState` の中から delegate、pcmGenerator、AUAudioUnit を呼ばない。
/// これらは lock の外で呼ぶ (lock を保持したまま callback を呼ぶと、callback が別スレッドから
/// 同じ lock を取る経路で deadlock する)。
final class DummyAudioDevice: NSObject, RTCAudioDevice {

  /// PCM データ生成処理。
  /// 第 1 引数: データ書き込み先、第 2 引数: フレーム数、第 3 引数: サンプルレート
  ///
  /// 生成器は `channelCount × フレーム数` の Int16 (interleaved) を書き込む。
  /// ADM の音声スレッドから呼ばれるため `@Sendable` とし、生成器側の可変状態は
  /// 生成器が排他する (呼び出し側では排他しない)。
  /// テストから `fillPCMData` を直接呼ぶ経路とは交差し得るため、複数スレッドから同時に
  /// 呼ばれても安全でなければならない。1 回の呼び出しの途中で再入はしない。
  private let pcmGenerator:
    @Sendable (_ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double) -> Void

  /// 入出力のチャンネル数。PCM は L、R の順の interleaved Int16 とする。
  private let channelCount: Int
  /// 指定時は音声ハードウェアを使わず、ADM から取り出した再生 PCM を同期的に渡す。
  /// バッファは callback の間だけ有効であり、保持する場合はコピーすること。
  private let playoutHandler: (@Sendable (UnsafeBufferPointer<Int16>, Double) -> Void)?

  /// timer と、その callback を識別する世代の組
  ///
  /// callback は自分の世代が `callbackGeneration` と一致するときだけ state を読む。世代は
  /// `install(_:)` (差し込み) と `detach()` (停止) のたびに進み、停止前の callback を無効化する。
  private struct TimerSlot {
    /// 稼働中の timer。停止側は常に `cancel()` できる (差し込む timer は resume 済みで入れる)
    private(set) var timer: DispatchSourceTimer?
    /// 差し込んだ timer の callback を識別する世代
    private(set) var callbackGeneration: UInt64 = 0

    /// timer を差し込む
    ///
    /// `makeTimer` に「これから差し込む callback を識別する世代」を渡して timer を組み立てさせ、
    /// state への差し込みと `resume()` までをこの呼び出しで行う。suspended のまま release された
    /// DispatchSourceTimer は libdispatch がクラッシュするため、state に入る timer は resume 済みで
    /// なければならない。世代の加算と差し込みを分けないことで、古い callback が新しい世代を
    /// すり抜ける経路を作らない。
    /// - Returns: 差し替えで外れた timer
    mutating func install(_ makeTimer: (UInt64) -> DispatchSourceTimer) -> DispatchSourceTimer? {
      callbackGeneration &+= 1
      let timer = makeTimer(callbackGeneration)
      let previous = self.timer
      self.timer = timer
      timer.resume()
      return previous
    }

    /// 世代を進めて timer を外し、外した timer を返す
    mutating func detach() -> DispatchSourceTimer? {
      callbackGeneration &+= 1
      let timer = self.timer
      self.timer = nil
      return timer
    }
  }

  /// DummyAudioDevice が持つ可変状態
  ///
  /// すべての読み書きを `stateLock` で排他する。timer と audioUnit もこの型が所有する。
  private struct State {
    /// delegate は弱参照で保持する (ADM が所有する)
    weak var delegate: RTCAudioDeviceDelegate?

    var isInitialized = false
    var isPlayoutInitialized = false
    var isPlaying = false
    var isRecordingInitialized = false
    var isRecording = false

    /// ハードミュート状態
    ///
    /// `initialize(with:)` の `initialMicrophoneEnabled` に従って初期化し、`terminateDevice` で
    /// `initialHardMuted` へ戻す (`Configuration.initialMicrophoneEnabled` は接続時点の状態を
    /// 定めるため、接続をまたいで `setHardMute` の状態を持ち越さない)
    var isHardMuted = false
    /// 初期状態のハードミュート。`isHardMuted` を元へ戻すために保持する
    var initialHardMuted = false

    /// 録音タイマー
    var recording = TimerSlot()
    /// 再生タイマー
    var playout = TimerSlot()

    /// ライフサイクルの世代
    ///
    /// `terminateDevice` の後始末のたびに進める。開始処理 (startRecording / startPlayout /
    /// initializePlayout / initializeRecording) は準備の前後でこの値が変わっていないことを確認し、
    /// 停止の後始末より後に timer / AudioUnit / state フラグを差し込まないようにする
    /// (停止後に届いた開始要求は、その世代の不一致で破棄される)。
    var lifecycleGeneration: UInt64 = 0

    /// AUAudioUnit (RemoteIO)。操作は ADM スレッドに限定する (「再生 (Playout)」を参照)
    var audioUnit: AUAudioUnit?
    /// AudioUnit のハードウェアを起動済みかどうか
    ///
    /// `startHardware()` に成功したときだけ true にし、停止側はこれを見て未起動の AudioUnit へ
    /// `stopHardware()` を呼ばない
    var isHardwareRunning = false
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
  private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body(&state)
  }

  /// 開始処理の前提 (delegate とライフサイクルの世代) を同じ lock 区間で取得する
  ///
  /// 取得した世代を `updateIfCurrentLifecycle` に渡すことで、準備の途中に `terminateDevice` が
  /// 走っていないことを確認できる。
  /// - Parameter requirePlayoutInitialized: 再生の初期化済みを必要とする場合に true
  /// - Returns: 停止済み・未初期化の場合は nil
  private func startContext(
    requirePlayoutInitialized: Bool = false
  ) -> (delegate: RTCAudioDeviceDelegate, lifecycle: UInt64)? {
    withState { state in
      if requirePlayoutInitialized && !state.isPlayoutInitialized { return nil }
      guard let delegate = state.delegate else { return nil }
      return (delegate, state.lifecycleGeneration)
    }
  }

  /// ライフサイクルの世代が変わっていないことを確認してから state を更新し、その結果を返す
  ///
  /// timer や AudioUnit を差し込む開始処理は、準備 (delegate や間隔の取得) と差し込みが
  /// 別の lock 区間になる。準備の途中で `terminateDevice` の後始末が走った場合は nil を返して
  /// state を変更しないため、停止後に timer / AudioUnit / state フラグは残らない。
  /// 世代の確認と更新は同じ lock 区間で行うため、両者の間に停止の後始末が入ることもない。
  private func withCurrentLifecycle<T>(
    _ lifecycle: UInt64, _ body: (inout State) -> T
  ) -> T? {
    withState { state in
      // delegate が外れている場合も停止済みとして扱う
      guard state.lifecycleGeneration == lifecycle, state.delegate != nil else { return nil }
      return body(&state)
    }
  }

  /// 更新だけを行う `withCurrentLifecycle`
  ///
  /// - Returns: 更新した場合は true、準備の途中で停止していた場合は false (state は変更しない)
  private func updateIfCurrentLifecycle(
    _ lifecycle: UInt64, _ body: (inout State) -> Void
  ) -> Bool {
    withCurrentLifecycle(lifecycle, body) != nil
  }

  /// AUAudioUnit 経路の開始処理の前提 (audioUnit とライフサイクルの世代) を同じ lock 区間で取得する
  ///
  /// AudioUnit の操作は ADM スレッドに限定するため、delegate は必要としない。
  /// - Returns: 初期化済みでない場合は nil
  private func playoutContext() -> (audioUnit: AUAudioUnit, lifecycle: UInt64)? {
    withState { state in
      guard let audioUnit = state.audioUnit else { return nil }
      return (audioUnit, state.lifecycleGeneration)
    }
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
    // 初期状態を保持し、terminateDevice で元へ戻せるようにする
    state.initialHardMuted = !initialMicrophoneEnabled
    state.isHardMuted = state.initialHardMuted
    super.init()
  }

  // 異常経路で terminateDevice が呼ばれずに解放された場合に備える。
  // deinit の時点で self への強参照は残っていない (timer の handler も dispatchAsync の block も
  // weak self を capture する) ため、state は lock なしで読める
  deinit {
    state.recording.timer?.cancel()
    state.playout.timer?.cancel()
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
    // delegate の設定と isInitialized の更新は同じ lock 区間で行う。別の区間だと、その間に
    // terminateDevice の後始末が入った場合に delegate だけ / フラグだけが残る
    if playoutHandler != nil {
      // PCM を callback で消費する場合は、マイク・スピーカー・共有 AudioSession に触れない。
      withState { state in
        state.delegate = delegate
        state.isInitialized = true
      }
      return true
    }

    withState { state in
      state.delegate = delegate
      state.isInitialized = true
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

    return true
  }

  func terminateDevice() -> Bool {
    let stop: () -> Void = { [weak self] in
      guard let self else { return }
      // 世代を進めてから timer・delegate を外す。発火済みの callback は世代が一致しないため破棄される。
      // delegate も同じ区間で外す。別の区間で外すと、その間の開始処理が delegate を取得して
      // 停止後に timer を差し込めてしまう
      let (timers, audioUnit, isHardwareRunning) = self.withState {
        state -> ([DispatchSourceTimer], AUAudioUnit?, Bool) in
        state.lifecycleGeneration &+= 1
        let timers = [state.recording.detach(), state.playout.detach()].compactMap { $0 }
        let audioUnit = state.audioUnit
        let isHardwareRunning = state.isHardwareRunning
        state.audioUnit = nil
        state.isHardwareRunning = false
        state.isRecording = false
        state.isRecordingInitialized = false
        state.isPlaying = false
        state.isPlayoutInitialized = false
        // 停止後は初期状態へ戻す (接続をまたいで setHardMute の状態を持ち越さない)
        state.isHardMuted = state.initialHardMuted
        state.delegate = nil
        state.isInitialized = false
        return (timers, audioUnit, isHardwareRunning)
      }
      // callback と AudioUnit は lock の外で停止する
      for timer in timers {
        timer.cancel()
      }
      if isHardwareRunning {
        audioUnit?.stopHardware()
      }
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(stop)
    } else {
      stop()
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
    if playoutHandler != nil {
      // 再生ハンドラ経路は AudioUnit を持たないが、停止の後始末をまたいでフラグを立てないよう
      // 世代を取得してから更新する
      guard let (_, lifecycle) = startContext() else { return false }
      guard
        updateIfCurrentLifecycle(lifecycle, { $0.isPlayoutInitialized = true })
      else { return false }
      return true
    }

    // AudioUnit を差し込むため、準備の途中で停止していないことを確認できるよう世代も取得する
    guard let (delegate, lifecycle) = startContext() else { return false }

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

    // 準備の途中で停止した場合は、作成した AudioUnit を解放して初期化しない
    guard
      updateIfCurrentLifecycle(
        lifecycle,
        { state in
          state.audioUnit = au
          state.isPlayoutInitialized = true
        })
    else {
      au.deallocateRenderResources()
      return false
    }
    return true
  }

  func startPlayout() -> Bool {
    if playoutHandler != nil {
      // 起動可否の確認と delegate・世代の取得を同じ lock 区間で行う
      guard let (delegate, lifecycle) = startContext(requirePlayoutInitialized: true) else {
        return false
      }
      let interval = delegate.preferredOutputIOBufferDuration

      // 準備の途中で停止した場合は timer を差し込まずに開始しない (差し込みと resume は
      // `TimerSlot.install(_:)` が同じ lock 区間で行う)
      guard
        let previous = withCurrentLifecycle(
          lifecycle,
          { state -> DispatchSourceTimer? in
            state.isPlaying = true
            return state.playout.install { generation in
              let timer = DispatchSource.makeTimerSource(queue: playoutQueue)
              timer.schedule(deadline: .now() + interval, repeating: interval)
              timer.setEventHandler { [weak self, weak delegate] in
                // ADM は同一スレッドでの callback を要求するため、タイマーの実行スレッドは使わない。
                delegate?.dispatchAsync { [weak self] in
                  self?.consumePlayoutData(generation: generation)
                }
              }
              return timer
            }
          })
      else { return false }
      // 差し替えで外れた timer の callback は世代が一致しないため破棄される
      previous?.cancel()
      return true
    }

    // AudioUnit の起動と isPlaying の更新は別の lock 区間になるため、世代で停止を検出する
    guard let (audioUnit, lifecycle) = playoutContext() else { return false }
    do {
      try audioUnit.startHardware()
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to start hardware: \(error.localizedDescription)")
      return false
    }
    // 起動の途中で停止した場合は、起動したハードウェアを停止して開始しない
    guard
      updateIfCurrentLifecycle(
        lifecycle,
        { state in
          state.isPlaying = true
          state.isHardwareRunning = true
        })
    else {
      audioUnit.stopHardware()
      return false
    }
    return true
  }

  func stopPlayout() -> Bool {
    let (timer, audioUnit, isHardwareRunning) = withState {
      state -> (DispatchSourceTimer?, AUAudioUnit?, Bool) in
      // 再開できるよう AudioUnit は残し、timer だけを外す (AudioUnit を破棄するのは terminateDevice だけ)
      let isHardwareRunning = state.isHardwareRunning
      state.isPlaying = false
      state.isHardwareRunning = false
      return (state.playout.detach(), state.audioUnit, isHardwareRunning)
    }
    // callback と AudioUnit は lock の外で停止する。起動していない AudioUnit へは停止を呼ばない
    timer?.cancel()
    if isHardwareRunning {
      audioUnit?.stopHardware()
    }
    return true
  }

  /// 音声デバイスを起動せずに実際の ADM の再生データを取得する。ADM スレッドから呼ぶ。
  private func consumePlayoutData(generation: UInt64) {
    // 停止済み・再起動済みの世代の callback はここで破棄する
    let snapshot = withState {
      state -> (isCurrent: Bool, delegate: RTCAudioDeviceDelegate?) in
      (state.isPlaying && state.playout.callbackGeneration == generation, state.delegate)
    }
    guard snapshot.isCurrent, let delegate = snapshot.delegate, let playoutHandler else { return }

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
    // 停止の後始末をまたいでフラグを立てないよう、delegate と世代を取得してから更新する
    guard let (_, lifecycle) = startContext() else { return false }
    guard updateIfCurrentLifecycle(lifecycle, { $0.isRecordingInitialized = true }) else {
      return false
    }
    return true
  }

  func startRecording() -> Bool {
    // 準備の途中で停止していないことを確認できるよう、delegate と世代を組で取得する
    guard let (delegate, lifecycle) = startContext() else { return false }
    let interval = delegate.preferredInputIOBufferDuration
    let intervalNs = Int(interval * Double(NSEC_PER_SEC))

    // 準備の途中で停止した場合は timer を差し込まずに開始しない (差し込みと resume は
    // `TimerSlot.install(_:)` が同じ lock 区間で行う)
    guard
      let previous = withCurrentLifecycle(
        lifecycle,
        { state -> DispatchSourceTimer? in
          state.isRecording = true
          return state.recording.install { generation in
            let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
            // ADM 側が recording フラグを立てる前に届いた最初のフレームが破棄されるため、
            // 1 インターバル分遅らせて開始する
            timer.schedule(
              deadline: .now() + .nanoseconds(intervalNs),
              repeating: .nanoseconds(intervalNs))
            timer.setEventHandler { [weak self, weak delegate] in
              // キューのワーカースレッドが変わっても、ADM への PCM 注入は同じスレッドに固定する。
              delegate?.dispatchAsync { [weak self] in
                self?.deliverPCMData(generation: generation)
              }
            }
            return timer
          }
        })
    else { return false }
    // 既存タイマーが残っている場合は先に外す。Offer SDP 作成のたびに startRecording が
    // 呼ばれ得るため、再入は安全でなければならない。外した timer の callback は
    // 世代が一致しないため破棄される
    previous?.cancel()
    return true
  }

  func stopRecording() -> Bool {
    let timer = withState { state -> DispatchSourceTimer? in
      state.isRecording = false
      return state.recording.detach()
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
    // 判定と強参照の取得を同じ lock 区間で行い、delegate の利用は lock の外で行う。
    // 世代の一致だけでも同じ timer の callback は識別できるが、フラグが同じ区間で更新される前提に
    // 依存しないよう、フラグも確認する
    let snapshot = withState {
      state -> (isCurrent: Bool, isHardMuted: Bool, delegate: RTCAudioDeviceDelegate?) in
      let isCurrent = state.isRecording && state.recording.callbackGeneration == generation
      return (isCurrent, state.isHardMuted, state.delegate)
    }

    guard snapshot.isCurrent, let delegate = snapshot.delegate else { return }

    // ハードミュート中は録音データを送信しない
    // (Configuration.initialMicrophoneEnabled = false の契約と setAudioHardMute に対応する)
    if snapshot.isHardMuted {
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
