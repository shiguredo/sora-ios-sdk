import AVFoundation
import Foundation
import WebRTC

/// `Sora` オブジェクトのイベントハンドラです。
///
/// 呼び出し元のスレッドは保証されない。UI 更新や共有状態の変更は main queue / main actor へ
/// 束ねること。
///
/// 配送のたびにプロパティを読むため、接続の途中で設定を変更しても次の配送から反映される
/// (プロパティの読み書きを排他する lock は無く、並行する設定変更はデータ競合になる)。
///
/// Swift 6 言語モードで `@MainActor` の文脈からハンドラーを設定する場合は、クロージャに
/// `@Sendable` を付けるか `nonisolated` な関数へ処理を分離して隔離を外す。`MediaChannel` と
/// `RTCAudioSession` は `Sendable` ではないため、main actor へ渡す場合は
/// `nonisolated(unsafe) let` で運び、`Task { @MainActor in ... }` で main actor 上へ移す
/// (`AVAudioSession.RouteChangeReason` と `AVAudioSessionRouteDescription` は `Sendable` のため
/// そのまま渡せる)。
///
/// イベントを actor / Task から購読する場合は `Sora.subscribeEvents(bufferingPolicy:)` を使う
/// (接続ごとのイベントは `MediaChannel.subscribeEvents(bufferingPolicy:)`)。新しい購読 API は、
/// この handler と同じ配送点から対応するイベントを配送する。
public final class SoraHandlers {
  /// 接続成功時に呼ばれるクロージャー
  public var onConnect: ((MediaChannel?, Error?) -> Void)?

  /// 接続解除時に呼ばれるクロージャー
  public var onDisconnect: ((MediaChannel, Error?) -> Void)?

  /// メディアチャネルが追加されたときに呼ばれるクロージャー
  public var onAddMediaChannel: ((MediaChannel) -> Void)?

  /// メディアチャネルが除去されたときに呼ばれるクロージャー
  public var onRemoveMediaChannel: ((MediaChannel) -> Void)?

  /// 音声入出力ルートが変更されたときに呼ばれるクロージャー
  ///
  /// - parameter session: 変更通知元の `RTCAudioSession`
  /// - parameter reason: 変更理由
  /// - parameter previousRoute: 変更前のルート情報
  public var onChangeAudioRoute:
    (
      (
        RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription
      ) -> Void
    )?

  /// 初期化します。
  public init() {}
}

// SDK の共有インスタンスを提供し、内部状態は SDK 側で管理するため、 @unchecked Sendable を付与します。
/// サーバーへのインターフェースです。
/// `Sora` オブジェクトを使用してサーバーへの接続を行います。
public final class Sora: @unchecked Sendable {
  // MARK: - SDK の操作

  private static let isInitialized: Bool = {
    initialize()
    return true
  }()

  private static func initialize() {
    Logger.debug(type: .sora, message: "initialize SDK")
    RTCInitializeSSL()
    RTCEnableMetrics()
  }

  /// SDK の終了処理を行います。
  /// アプリケーションの終了と同時に SDK の使用を終了する場合、
  /// この関数を呼ぶ必要はありません。
  public static func finish() {
    Logger.debug(type: .sora, message: "finish SDK")
    RTCShutdownInternalTracer()
    RTCCleanupSSL()
  }

  /// ログレベル。指定したレベルより高いログは出力されません。
  /// デフォルトは `info` です。
  public static var logLevel: LogLevel {
    get {
      Logger.shared.level
    }
    set {
      Logger.shared.level = newValue
    }
  }

  // MARK: - プロパティ

  /// 接続中のメディアチャネルのリスト
  public var mediaChannels: [MediaChannel] {
    mediaChannelLock.lock()
    defer { mediaChannelLock.unlock() }
    return _mediaChannels
  }

  // mediaChannels の実体。読み書きは必ず mediaChannelLock で保護する
  private var _mediaChannels: [MediaChannel] = []

  // _mediaChannels への全アクセスを保護する排他ロック
  private let mediaChannelLock = NSLock()

  /// イベントハンドラ
  public let handlers = SoraHandlers()

  // MARK: - イベントの購読

  /// `Sora` インスタンスのイベントを購読します。
  ///
  /// 購読者ごとに独立した `AsyncStream` を返します。購読ごとに buffer / drop 方針 / 終端が
  /// 独立しており、1 つの購読を解除しても他の購読者へ影響しません。接続ごとのイベントは
  /// `MediaChannel.subscribeEvents(bufferingPolicy:)` で購読します。
  ///
  /// - 配送されるのは `mediaChannelAdded` / `mediaChannelRemoved` / `audioRouteChanged` と、
  ///   このインスタンスが開始した接続の `connected` / `connectFailed` / `disconnected` です。
  /// - イベントは配送順に届きます。通し番号の順序と一致しない場合はあります (同時に配送された
  ///   イベントのみ)。
  /// - buffer は既定で `SoraEvent.defaultBufferSize` 件です。あふれた場合は最も古いイベントが
  ///   破棄されます。`sequence` で欠落を検出できます。
  /// - 購読を開始する前に配送されたイベントは届きません (buffer は購読ごとに作られます)。
  ///   接続前に開始しておけば、`mediaChannelAdded` と接続結果を取り逃しません。
  /// - payload はすべて値として確定しており、配送後も購読者が保持できます。
  /// - 購読の解除は、購読している `Task` の cancel、購読に使った `AsyncStream` への参照の解放、
  ///   または `Sora` インスタンスの解放です。
  /// - 購読している `Task` の loop の中から同期 API (`mediaChannels` などの getter、`connect`、
  ///   `disconnect` を含む) を呼べます。配送は排他区間の外で行うため deadlock しません。
  /// - 配送 executor はイベントの発生元によって異なります (libwebrtc の callback スレッド、
  ///   signaling の受信スレッド、`DispatchQueue.global()`、呼び出し元の executor など)。`AsyncStream`
  ///   の再開後に実行される購読者のコードは、購読している `Task` の executor 上で動きます。
  ///   UI 更新は main actor / main queue へ束ねてください。
  /// - この API の追加によって、既存の `handlers` の callback 型・配送 executor・配送順序・
  ///   発火回数は変わりません。
  ///
  /// - parameter bufferingPolicy: 購読者ごとの buffer と drop 方針
  /// - returns: このインスタンスのイベントを配送する stream
  public func subscribeEvents(
    bufferingPolicy: AsyncStream<SoraEvent>.Continuation.BufferingPolicy = .bufferingNewest(
      SoraEvent.defaultBufferSize)
  ) -> AsyncStream<SoraEvent> {
    eventPublisher.subscribe(bufferingPolicy: bufferingPolicy)
  }

  /// このインスタンスの購読者を管理する storage です。
  private let eventPublisher = SoraEventPublisher()

  /// このインスタンスに紐づくイベントを配送します。
  ///
  /// 呼び出し側は `mediaChannelLock` などの排他区間を保持せずに呼びます。
  func publishEvent(
    kind: SoraEventKind,
    connectionId: String? = nil,
    transportEpoch: Int? = nil,
    error: Error? = nil,
    audioRoute: SoraAudioRouteEvent? = nil
  ) {
    eventPublisher.publish(
      SoraEvent(
        kind: kind,
        connectionId: connectionId,
        transportEpoch: transportEpoch,
        error: error.map(SoraEventError.init),
        audioRoute: audioRoute))
  }

  private lazy var audioSessionDelegateAdapter = SoraRTCAudioSessionDelegateAdapter {
    [weak self] session, reason, previousRoute in
    self?.handlers.onChangeAudioRoute?(session, reason, previousRoute)
    self?.publishEvent(
      kind: .audioRouteChanged,
      audioRoute: SoraAudioRouteEvent(reason: reason, previousRoute: previousRoute))
  }

  // MARK: - インスタンスの生成と取得

  /// シングルトンインスタンス
  public static let shared = Sora()

  /// 初期化します。
  /// 大抵の用途ではシングルトンインスタンスで問題なく、
  /// インスタンスを生成する必要はないでしょう。
  /// メディアチャネルのリストをグループに分けたい、
  /// または複数のイベントハンドラを使いたいなどの場合に
  /// インスタンスを生成してください。
  public init() {
    // This will guarantee that `Sora.initialize()` is called only once.
    // - It works even if user initialized `Sora` directly
    // - It works even if user directly use `Sora.shared`
    // - It guarantees `initialize()` is called only once thanks to the `static let` https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Properties.html#//apple_ref/doc/uid/TP40014097-CH14-ID254
    let initialized = Sora.isInitialized
    // This looks silly, but this will ensure `Sora.isInitialized` is not be omitted,
    // no matter how clang optimizes compilation.
    // If we go for `let _ = Sora.isInitialized`, clang may omit this line,
    // which is fatal to the initialization logic.
    // The following line will NEVER fail.
    if !initialized { fatalError() }
    RTCAudioSession.sharedInstance().add(audioSessionDelegateAdapter)
  }

  deinit {
    RTCAudioSession.sharedInstance().remove(audioSessionDelegateAdapter)
    // Sora インスタンスの解放で購読を終端する。
    eventPublisher.finish()
  }

  // MARK: - メディアチャネルの管理

  // mediaChannelLock で _mediaChannels を保護し、handlers コールバックはロック外で呼ぶ。
  //
  // ロック内でコールバックを呼ぶと、ユーザーのハンドラから connect() を再呼び出しした場合にデッドロックする。
  func add(mediaChannel: MediaChannel) {
    var added = false
    mediaChannelLock.lock()
    if !_mediaChannels.contains(mediaChannel) {
      _mediaChannels.append(mediaChannel)
      added = true
    }
    mediaChannelLock.unlock()

    if added {
      // ログは排他区間の外で出す。ロックを保持したまま Logger を呼ぶと、利用者の
      // onOutputHandler が同じロックを取る経路で deadlock する。
      Logger.debug(type: .sora, message: "add media channel")
      handlers.onAddMediaChannel?(mediaChannel)
      publishEvent(
        kind: .mediaChannelAdded,
        connectionId: mediaChannel.connectionId,
        transportEpoch: mediaChannel.transportEpoch)
    }
  }

  // add と同様、mediaChannelLock で _mediaChannels を保護し、handlers コールバックはロック外で呼ぶ。
  func remove(mediaChannel: MediaChannel) {
    var removed = false
    mediaChannelLock.lock()
    if _mediaChannels.contains(mediaChannel) {
      _mediaChannels.remove(mediaChannel)
      removed = true
    }
    mediaChannelLock.unlock()

    if removed {
      // ログは排他区間の外で出す (add と同じ理由)。
      Logger.debug(type: .sora, message: "remove media channel")
      handlers.onRemoveMediaChannel?(mediaChannel)
      publishEvent(
        kind: .mediaChannelRemoved,
        connectionId: mediaChannel.connectionId,
        transportEpoch: mediaChannel.transportEpoch)
    }
  }

  // MARK: - 接続

  /// サーバーに接続します。
  ///
  /// - parameter configuration: クライアントの設定
  /// - parameter webRTCConfiguration: WebRTC の設定
  /// - parameter handler: 接続試行後に呼ばれるクロージャー。
  ///
  ///   呼び出し元のスレッドは保証されない (接続に成功した場合、設定エラーで終端した場合、接続に
  ///   失敗した場合のいずれも、接続を開始したスレッドとは異なるスレッドから呼ばれ得る)。
  ///   UI 更新や共有状態の変更は main queue / main actor へ束ねること。
  ///
  ///   Swift 6 言語モードで `@MainActor` の文脈から接続する場合は、クロージャに `@Sendable` を
  ///   付けるか `nonisolated` な関数へ処理を分離して隔離を外す。`MediaChannel` は `Sendable` では
  ///   ないため、main actor へ渡す場合は `nonisolated(unsafe) let` で運び、
  ///   `Task { @MainActor in ... }` で main actor 上へ移す。
  /// - parameter mediaChannel: (接続成功時のみ) メディアチャネル
  /// - parameter error: (接続失敗時のみ) エラー
  /// - returns: 接続試行中の状態
  public func connect(
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
    handler:
      @escaping (
        _ mediaChannel: MediaChannel?,
        _ error: Error?
      ) -> Void
  ) -> ConnectionTask {
    let mediaChan: MediaChannel
    do {
      // 接続開始後に利用者所有の可変値を参照しないよう、チャネルを生成する前に
      // 設定を snapshot へ写し取る。JSON 化できない設定はここで終端する。
      let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
      mediaChan = try MediaChannel(
        snapshot: snapshot,
        configuration: configuration,
        audioDevice: configuration.audioDevice,
        mediaChannelHandlers: configuration.mediaChannelHandlers,
        webSocketChannelHandlers: configuration.webSocketChannelHandlers)
    } catch {
      // 設定エラーや ADM 初期化エラーはチャネルを登録せず接続試行を終端する。
      // 通常の接続経路と同様に、利用者の callback は connect() の呼び出しスタック外で通知する。
      let connectionTask = ConnectionTask()
      if connectionTask.complete() {
        // 完了ログは ConnectionTask の排他区間の外で出す。
        Logger.debug(type: .mediaChannel, message: "connection task completed")
      }
      // 接続 handler は `@Sendable` ではないため、公開している引数の型を変えずに box へ包んで渡す。
      let handlerBox = ConnectErrorHandlerBox(handler)
      DispatchQueue.global().async { [weak self] in
        handlerBox(nil, error)
        self?.handlers.onConnect?(nil, error)
        self?.publishEvent(kind: .connectFailed, error: error)
      }
      return connectionTask
    }
    mediaChan.internalHandlers.onDisconnectLegacy = { [weak self, weak mediaChan] error in
      guard let weakSelf = self else {
        return
      }
      guard let mediaChan else {
        return
      }
      weakSelf.remove(mediaChannel: mediaChan)
      weakSelf.handlers.onDisconnect?(mediaChan, error)
      weakSelf.publishEvent(
        kind: .disconnected,
        connectionId: mediaChan.connectionId,
        transportEpoch: mediaChan.transportEpoch,
        error: error)
    }

    // MediaChannel が接続試行を予約して `.connecting` へ遷移した後に管理対象へ追加する。
    // onAddMediaChannel から同期的に disconnect されても、接続開始前に確実に終端できる。
    return mediaChan.connect(
      webRTCConfiguration: webRTCConfiguration,
      onPrepared: { [weak self, mediaChan] in
        self?.add(mediaChannel: mediaChan)
      },
      handler: { [weak self, mediaChan] error in
        if let error {
          handler(nil, error)
          self?.handlers.onConnect?(nil, error)
          self?.publishEvent(
            kind: .connectFailed,
            connectionId: mediaChan.connectionId,
            transportEpoch: mediaChan.transportEpoch,
            error: error)
          return
        }

        handler(mediaChan, nil)
        self?.handlers.onConnect?(mediaChan, nil)
        self?.publishEvent(
          kind: .connected,
          connectionId: mediaChan.connectionId,
          transportEpoch: mediaChan.transportEpoch)
      })
  }

  // MARK: - 音声ユニットの操作

  /// 音声ユニットの手動による初期化の可否。
  /// ``false`` をセットした場合、音声トラックの生成時に音声ユニットが自動的に初期化されます。
  /// (音声ユニットを使用するには ``audioEnabled`` に ``true`` をセットして初期化する必要があります)
  /// ``true`` をセットした場合、音声ユニットは自動的に初期化されません。
  /// デフォルトは ``false`` です。
  public var usesManualAudio: Bool {
    get {
      RTCAudioSession.sharedInstance().useManualAudio
    }
    set {
      RTCAudioSession.sharedInstance().useManualAudio = newValue
    }
  }

  /// 音声ユニットの使用の可否。
  /// このプロパティは ``usesManualAudio`` が ``true`` の場合のみ有効です。
  /// デフォルトは ``false`` です。
  ///
  /// ``true`` をセットした場合、音声ユニットは必要に応じて初期化されます。
  /// ``false`` をセットした場合、すでに音声ユニットが初期化済みで起動されていれば、
  /// 音声ユニットを停止します。
  ///
  /// このプロパティを使用すると、音声ユニットの初期化によって
  /// AVPlayer などによる再生中の音声が中断されてしまうことを防げます。
  public var audioEnabled: Bool {
    get {
      RTCAudioSession.sharedInstance().isAudioEnabled
    }
    set {
      RTCAudioSession.sharedInstance().isAudioEnabled = newValue
    }
  }

  /// ``AVAudioSession`` の設定を変更する際に使います。
  /// WebRTC で使用中のスレッドをロックします。
  /// このメソッドは次のプロパティとメソッドの使用時に使ってください。
  ///
  /// - ``category``
  /// - ``categoryOptions``
  /// - ``mode``
  /// - ``secondaryAudioShouldBeSilencedHint``
  /// - ``currentRoute``
  /// - ``maximumInputNumberOfChannels``
  /// - ``maximumOutputNumberOfChannels``
  /// - ``inputGain``
  /// - ``inputGainSettable``
  /// - ``inputAvailable``
  /// - ``inputDataSources``
  /// - ``inputDataSource``
  /// - ``outputDataSources``
  /// - ``outputDataSource``
  /// - ``sampleRate``
  /// - ``preferredSampleRate``
  /// - ``inputNumberOfChannels``
  /// - ``outputNumberOfChannels``
  /// - ``outputVolume``
  /// - ``inputLatency``
  /// - ``outputLatency``
  /// - ``ioBufferDuration``
  /// - ``preferredIOBufferDuration``
  /// - ``setCategory(_:withOptions:)``
  /// - ``setMode(_:)``
  /// - ``setInputGain(_:)``
  /// - ``setPreferredSampleRate(_:)``
  /// - ``setPreferredIOBufferDuration(_:)``
  /// - ``setPreferredInputNumberOfChannels(_:)``
  /// - ``setPreferredOutputNumberOfChannels(_:)``
  /// - ``overrideOutputAudioPort(_:)``
  /// - ``setPreferredInput(_:)``
  /// - ``setInputDataSource(_:)``
  /// - ``setOutputDataSource(_:)``
  ///
  /// - parameter block: ロック中に実行されるクロージャー
  public func configureAudioSession(block: () -> Void) {
    let session = RTCAudioSession.sharedInstance()
    session.lockForConfiguration()
    block()
    session.unlockForConfiguration()
  }

  /// 音声モードを変更します。
  /// このメソッドは **接続完了後** に実行してください。
  ///
  /// - parameter mode: 音声モード
  /// - returns: 変更の成否
  public func setAudioMode(
    _ mode: AudioMode,
    options: AVAudioSession.CategoryOptions = [
      .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay,
    ]
  ) -> Result<Void, Error> {
    do {
      var options = options
      let session = RTCAudioSession.sharedInstance()
      session.lockForConfiguration()
      defer {
        session.unlockForConfiguration()
      }
      // 音声出力経路のリセットを行います。
      // RTCAudioSession.overrideOutputAudioPort はカテゴリが playAndRecord の場合のみ有効なため
      // カテゴリ遷移前のこの状態でリセットを行います。
      if shouldResetPortOverride(for: mode)
        && session.category == AVAudioSession.Category.playAndRecord.rawValue
      {
        try session.overrideOutputAudioPort(.none)
      }
      switch mode {
      case .default(let category, let output):
        if output == .speaker {
          options = [options, .defaultToSpeaker]
        }
        try session.setCategory(category, with: options)
        try session.setMode(.default)
      case .videoChat:
        try session.setCategory(.playAndRecord, with: options)
        try session.setMode(.videoChat)
      case .voiceChat(let output):
        if output == .speaker {
          options = [options, .defaultToSpeaker]
        }
        try session.setCategory(.playAndRecord, with: options)
        try session.setMode(.voiceChat)
        try session.overrideOutputAudioPort(output.portOverride)
      }
      return .success(())
    } catch {
      return .failure(error)
    }
  }

  // setAudioMode にて音声入力経路のリセットを行うか判定します
  private func shouldResetPortOverride(for mode: AudioMode) -> Bool {
    switch mode {
    case .default(_, let output):
      return output == .default
    case .videoChat:
      return false
    case .voiceChat(let output):
      return output == .default
    }
  }

  // MARK: - libwebrtc のログ出力

  private nonisolated(unsafe) static var webRTCCallbackLogger: RTCCallbackLogger = {
    let logger = RTCCallbackLogger()
    logger.severity = .none
    return logger
  }()

  private static let webRTCLoggingDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  /// libwebrtc のログレベルを指定します。
  /// ログは `RTCSetMinDebugLogLevel()` でも指定可能ですが、 `RTCSetMinDebugLogLevel()` ではログの時刻が表示されません。
  /// 本メソッドでログレベルを指定すると、時刻を含むログを出力します。
  public static func setWebRTCLogLevel(_ severity: RTCLoggingSeverity) {
    // RTCSetMinDebugLogLevel() でログレベルを指定すると
    // RTCCallbackLogger 以外のログも出力されてしまい、
    // ログ出力が二重になるので RTCSetMinDebugLogLevel() は使わない。
    webRTCCallbackLogger.severity = severity
    webRTCCallbackLogger.stop()
    webRTCCallbackLogger.start { message, callbackSeverity in
      let severityName: String
      switch callbackSeverity {
      case .info:
        severityName = "INFO"
      case .verbose:
        severityName = "VERBOSE"
      case .warning:
        severityName = "WARNING"
      case .error:
        severityName = "ERROR"
      case .none:
        return
      @unknown default:
        return
      }
      let timestamp = Date()
      print(
        "\(webRTCLoggingDateFormatter.string(from: timestamp)) libwebrtc \(severityName): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }
}

/// 設定エラー通知の接続 handler を並行処理境界へ渡すための、用途限定の内部ラッパーです。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する handler は `init` で確定した `let` であること
/// - 変更前から handler を渡していた `DispatchQueue.global()` の block を包み直すだけで、
///   配送先・通知順序・呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持するのは handler の closure だけで、SDK 内部の参照型を新たに保持しないこと
///
/// 生成は `Sora.connect` の設定エラー経路の 1 箇所だけで、1 つの block へ 1 回だけ渡して
/// 1 回だけ実行する使用契約です (型では強制されません)。`Sendable` にするのはこの入れ物だけで、
/// handler とその捕捉状態を `Sendable` にはしません。捕捉状態の所有と同期は、呼び出しスレッドを
/// 保証しない既存の挙動の下で利用者の責務です。実行スレッドの同一性・直列性も契約にしません。
private final class ConnectErrorHandlerBox: @unchecked Sendable {
  private let handler: (MediaChannel?, (any Error)?) -> Void

  init(_ handler: @escaping (MediaChannel?, (any Error)?) -> Void) {
    self.handler = handler
  }

  func callAsFunction(_ mediaChannel: MediaChannel?, _ error: (any Error)?) {
    handler(mediaChannel, error)
  }
}

/// サーバーへの接続試行中の状態を表します。
/// `cancel()` で接続をキャンセル可能です。
public final class ConnectionTask {
  /// 接続状態を表します。
  ///
  /// 公開 API であるため、利用者が switch で全ケースを網羅している場合に備えて
  /// ケースは追加しない。内部でキャンセル処理中の `cancelRequested` 状態を
  /// 持つ場合も、外部からは `.canceled` として観測される。
  public enum State: Sendable {
    /// 接続試行中
    case connecting

    /// 接続試行が終端した。成功・接続失敗・切断を区別しない
    case completed

    /// キャンセル済み
    case canceled
  }

  /// 内部の状態遷移を表します。
  /// `cancelRequested` (キャンセル要求を受領し、キャンセル処理中) を公開 enum から
  /// 分離するために、公開 `State` とは別に管理する。
  private enum InternalState {
    case connecting
    case cancelRequested
    case completed
    case canceled
  }

  private let stateLock = NSLock()
  private weak var _peerChannel: PeerChannel?
  private var _internalState: InternalState

  /// 接続状態
  public var state: State {
    stateLock.lock()
    defer { stateLock.unlock() }
    switch _internalState {
    case .connecting:
      return .connecting
    case .cancelRequested:
      return .canceled
    case .completed:
      return .completed
    case .canceled:
      return .canceled
    }
  }

  init() {
    _internalState = .connecting
  }

  /// 接続処理を開始するために PeerChannel を設定します。
  /// キャンセル要求済みの場合は false を返し、呼び出し元は接続処理を開始してはいけません。
  func attach(peerChannel: PeerChannel) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard _internalState == .connecting else {
      return false
    }
    _peerChannel = peerChannel
    return true
  }

  /// キャンセル要求を受領済みかどうかの確認を伴わず、キャンセル状態を確定させます。
  /// `attach` が false を返した場合、または `cancel()` が peerChannel を切断した場合に、
  /// 呼び出し元がキャンセルとして終端するために使います。
  func markCanceled() {
    stateLock.lock()
    defer { stateLock.unlock() }
    if _internalState == .cancelRequested {
      _internalState = .canceled
    }
  }

  /// 接続試行をキャンセルします。
  /// すでに接続済みであれば何もしません。
  public func cancel() {
    // peerChannel の取得はロック下で行い、disconnect の呼び出しはロックの外で行う。
    // ロックを保持したまま disconnect を呼ぶと、切断時の callback から complete() や
    // cancel() が再入した場合に deadlock するためである。
    let peerChannel: PeerChannel?
    var requestedCancellation = false
    stateLock.lock()
    if _internalState == .connecting {
      _internalState = .cancelRequested
      peerChannel = _peerChannel
      requestedCancellation = true
    } else {
      peerChannel = nil
    }
    stateLock.unlock()

    // ログは排他区間の外で出す。ロックを保持したまま Logger を呼ぶと、利用者の
    // onOutputHandler が ConnectionTask.state を読む経路で deadlock する。
    if requestedCancellation {
      Logger.debug(type: .mediaChannel, message: "connection task cancelled")
    }

    if let peerChannel {
      // reason: .user としているため、 cancel は SDK 内部で使用してはならない
      peerChannel.disconnect(error: SoraError.connectionCancelled, reason: .user)
    }
    // peerChannel の有無にかかわらず、キャンセル要求を必ず確定させる。
    // (peerChannel が nil の場合は disconnect が行われないため、ここで確定しないと
    // attach の呼び出し元が markCanceled() を呼ぶまで .cancelRequested のまま残る)
    markCanceled()
  }

  /// 接続試行中であれば完了状態へ遷移し、遷移できたかを返します。
  ///
  /// 接続成功と `cancel()` が競合した場合に、どちらが先に終端状態を確定したかを
  /// 呼び出し元が判断できるようにするための操作です。
  /// ログは排他区間の外で出すため本メソッドでは出力せず、遷移できたかを返します。
  @discardableResult
  func tryComplete() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard _internalState == .connecting else {
      return false
    }
    _internalState = .completed
    return true
  }

  /// 接続試行中であれば完了状態へ遷移し、遷移できたかを返します。
  /// ログは排他区間の外で出すため、呼び出し元が戻り値を確認して出力します。
  @discardableResult
  func complete() -> Bool {
    tryComplete()
  }
}

// RTCAudioSessionDelegate を実装し、audioSessionDidChangeRoute イベントを受けて、
// handlers.onChangeAudioRoute を呼び出す中継クラスです。
//
// オーディオ経路変更通知の流れ
// 1. オーディオ経路の変更を RTCAudioSession::handleRouteChangeNotification で AVAudioSessionRouteChangeNotification で受信
// 2. RTCAudioSession::notifyDidChangeRouteWithReason で audioSessionDidChangeRoute:reason:previousRoute: が呼ばれる
// 3. SoraRTCAudioSessionDelegateAdapter(本クラス) の audioSessionDidChangeRoute で通知を受ける
// 4. onChangeAudioRoute で SDK 利用者へ通知する
private final class SoraRTCAudioSessionDelegateAdapter: NSObject, RTCAudioSessionDelegate {
  private let onChangeAudioRoute:
    (
      RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription
    ) -> Void

  init(
    onChangeAudioRoute:
      @escaping (
        RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription
      ) -> Void
  ) {
    self.onChangeAudioRoute = onChangeAudioRoute
  }

  func audioSessionDidChangeRoute(
    _ session: RTCAudioSession,
    reason: AVAudioSession.RouteChangeReason,
    previousRoute: AVAudioSessionRouteDescription
  ) {
    switch reason {
    case .unknown, .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override,
      .wakeFromSleep, .noSuitableRouteForCategory:
      onChangeAudioRoute(session, reason, previousRoute)
    case .routeConfigurationChange:
      // WebRTC 側でも routeConfigurationChange を無視しているため、ここでも無視します
      break
    @unknown default:
      onChangeAudioRoute(session, reason, previousRoute)
    }
  }
}
