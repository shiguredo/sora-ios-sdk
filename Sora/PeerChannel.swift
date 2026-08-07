import Foundation
import Security
import WebRTC

/// :nodoc:
extension RTCDegradationPreference: CustomStringConvertible {
  public var description: String {
    switch self {
    case .balanced: "balanced"
    case .disabled: "disabled"
    case .maintainFramerate: "maintain-framerate"
    case .maintainResolution: "maintain-resolution"
    @unknown default: "-"
    }
  }
}

/// :nodoc:
/// デバッグログ出力用に RTCPriority の文字列表現を提供する
extension RTCPriority: CustomStringConvertible {
  public var description: String {
    switch self {
    case .veryLow: "very-low"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    @unknown default: "unknown(\(rawValue))"
    }
  }
}

/// :nodoc:
extension RTCRtpParameters {
  override open var description: String {
    let degradationPreference =
      if let unwrapped = self.degradationPreference {
        String(describing: RTCDegradationPreference(rawValue: unwrapped.intValue))
      } else {
        "-"
      }

    // RTCRtpParameters は他にもプロパティーを持つが、ここでは SDK で利用している値のみ出力する
    // encodings もここに追加したい
    return "\(transactionId) \(String(describing: degradationPreference))"
  }
}

final class PeerChannelInternalHandlers {
  /// 接続解除時に呼ばれるクロージャー
  var onDisconnect: ((Error?, DisconnectReason) -> Void)?

  /// ストリームの追加時に呼ばれるクロージャー
  var onAddStream: ((MediaStream) -> Void)?

  /// ストリームの除去時に呼ばれるクロージャー
  var onRemoveStream: ((MediaStream) -> Void)?

  /// マルチストリームの状態の更新に呼ばれるクロージャー。
  /// 更新により、ストリームの追加または除去が行われます。
  var onUpdate: ((String) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー
  var onReceiveSignaling: ((Signaling) -> Void)?

  /// シグナリング受信時に JSON 文字列で呼ばれるクロージャー
  var onReceiveSignalingJSON: ((String) -> Void)?

  /// DataChannel の open 時に呼ばれるクロージャー
  var onOpenDataChannel: ((String) -> Void)?

  /// DataChannel のメッセージ受信時に呼ばれるクロージャー
  var onDataChannelMessage: ((String, Data) -> Void)?

  /// DataChannel の close 時に呼ばれるクロージャー
  var onCloseDataChannel: ((String) -> Void)?

  /// DataChannel の bufferedAmount 変更時に呼ばれるクロージャー
  var onDataChannelBufferedAmount: ((String, UInt64) -> Void)?

  /// 初期化します。
  public init() {}
}

class PeerChannel: NSObject, RTCPeerConnectionDelegate {
  // MARK: - Constants

  /// DataChannel の signaling ラベル受信後、WebSocket 切断までの待機時間（秒）
  /// NOTE: DataChannel への切り替え後、WebSocket 経由でまだ送信中のメッセージがある可能性を考慮し、
  /// 余裕を持って WebSocket を切断するために待機時間を設けている。
  private static let switchedDisconnectDelay: TimeInterval = 10.0

  /// 接続完了後に `RTCPeerConnectionState` が `.disconnected` になってから切断するまでの猶予時間（秒）
  ///
  /// 一時的なネットワーク切断 (`.disconnected` → `.connected` の回復) を阻害しないために設ける。
  /// 再ネゴシエーション (ICE 再起動) は `.disconnected` → `.connecting` を経由するため、
  /// タイマーは `.connecting` への遷移でキャンセルされる。
  private static let disconnectedGracePeriod: TimeInterval = 5.0

  final class Lock {
    weak var context: PeerChannel?

    // 進行中の非同期処理数。lock() でインクリメント、unlock() でデクリメントする
    private var count: Int = 0

    // 切断処理が開始されたことを示すフラグ。true の場合 lock() は false を返す。
    // 不変条件: isDisconnecting == true ならば count == 0
    private var isDisconnecting: Bool = false

    // count > 0 の間に切断要求があった場合に遅延実行用パラメータを保持する
    private var shouldDisconnect: (Bool, Error?, DisconnectReason) = (false, nil, .unknown)

    // count, isDisconnecting, shouldDisconnect への全アクセスを保護する排他ロック
    private let nsLock = NSLock()

    /// 猶予タイマー由来の切断要求が、接続の回復により無効化されるかを返す。
    ///
    /// タイマー発火時点の確認から切断実行までの間に接続が回復している場合、
    /// 切断すると一時的な切断の回復を阻害するためキャンセルする。
    /// `.disconnected` のままなら切断を継続する。 `.failed` は終端状態であり
    /// 回復し得ないためキャンセルしない。他の reason はユーザーの意図または
    /// 確定した切断なので、この再確認の対象外とする。
    private func shouldCancelDisconnectTimerBasedDisconnect(reason: DisconnectReason) -> Bool {
      reason == .peerConnectionStateDisconnected
        && context?.state != .disconnected
        && context?.state != .failed
    }

    func waitDisconnect(error: Error?, reason: DisconnectReason) {
      var shouldCallBasicDisconnect = false
      nsLock.lock()
      if isDisconnecting {
        // 切断処理が既に開始されている場合、追加の切断要求は無視する
      } else if count == 0 {
        // 猶予タイマー由来の切断は、タイマー発火時点の確認からここまでの間に
        // 接続が回復している場合は切断しない
        if !shouldCancelDisconnectTimerBasedDisconnect(reason: reason) {
          isDisconnecting = true
          shouldCallBasicDisconnect = true
        }
      } else if count == 1, context?.onConnect != nil {
        // 接続試行中 (connect() の初期ロックのみが残っている状態) の切断要求。
        // 初期ロックは finishConnecting() か sendConnectMessage(error:) でのみ解放されるため、
        // answer 送信後の接続失敗などではそのまま解放されず basicDisconnect が呼ばれない。
        // その結果 RTCPeerConnection がクローズされずに残り続けるため、
        // ここで初期ロックを解放して basicDisconnect を直接実行する。
        count = 0
        isDisconnecting = true
        shouldCallBasicDisconnect = true
      } else {
        // 進行中の非同期処理が完了するまで切断要求を遅延保存する。
        // 保存済みの切断要求は最後の切断要求で上書きされる。猶予タイマー由来の
        // 切断要求がその後の .failed 遷移の切断要求で上書きされると NO-ERROR 送信が
        // 失われるが (sendDisconnectMessageIfNeeded の state == .failed ガード)、
        // .failed は ICE の完全失敗であり送信が届く可能性が低いため妥当とする
        shouldDisconnect = (true, error, reason)
      }
      nsLock.unlock()

      if shouldCallBasicDisconnect {
        context?.basicDisconnect(error: error, reason: reason)
      }
    }

    @discardableResult
    func lock() -> Bool {
      nsLock.lock()
      if isDisconnecting {
        nsLock.unlock()
        return false
      }
      count += 1
      nsLock.unlock()
      return true
    }

    func unlock() {
      var disconnectParams: (Error?, DisconnectReason)?
      nsLock.lock()
      if isDisconnecting {
        // 切断処理の開始後に非同期処理が完了した場合の unlock は無視する。
        // waitDisconnect が接続試行中の切断要求を basicDisconnect へ直接到達させるため、
        // 後続の非同期処理が unlock を呼んでも count は 0 のままである。
        nsLock.unlock()
        return
      }
      if count <= 0 {
        fatalError("count is already 0")
      }
      count -= 1
      // count == 0 になった場合に加えて、接続試行中 (count == 1) に切断要求が
      // あった場合も、進行中の非同期処理が完了したここで basicDisconnect へ到達させる。
      // これがないと、 createAndSendAnswer 実行中の切断要求が保存されたまま
      // 初期ロックが解放されず、 basicDisconnect が呼ばれない。
      if count == 0 || (count == 1 && shouldDisconnect.0) {
        switch shouldDisconnect {
        case (true, let error, let reason):
          if shouldCancelDisconnectTimerBasedDisconnect(reason: reason) {
            // 接続が回復しているため切断をキャンセルする。
            // isDisconnecting は設定しない (設定すると以後の切断・再ネゴシエーションが
            // すべて不能になり、 Lock が恒久的に破壊されるため。キャンセル後は再び
            // .disconnected になればタイマーが再開始される)
            shouldDisconnect = (false, nil, .unknown)
          } else {
            count = 0
            isDisconnecting = true
            shouldDisconnect = (false, nil, .unknown)
            disconnectParams = (error, reason)
          }
        default:
          break
        }
      }
      nsLock.unlock()

      if let (error, reason) = disconnectParams {
        if let context {
          if context.state != .closed {
            context.basicDisconnect(error: error, reason: reason)
          }
        }
      }
    }

  }

  // MARK: - Properties

  var internalHandlers = PeerChannelInternalHandlers()
  let configuration: Configuration
  let signalingChannel: SignalingChannel
  let nativePeerChannelFactory: NativePeerChannelFactory

  private(set) var streams: [MediaStream] = []
  private(set) var iceCandidates: [ICECandidate] = []

  var dataChannels: [String: DataChannel] = [:]
  var switchedToDataChannel: Bool = false
  nonisolated(unsafe) var webSocketDisconnectScheduled: Bool = false

  // 接続完了後の切断検出 (RTCPeerConnectionState.disconnected) 用の猶予タイマー。
  // タイマーの開始・キャンセルのフラグは webSocketDisconnectScheduled と同じく
  // nonisolated(unsafe) で扱う (ベストエフォート)。二重開始は disconnectTimerScheduled
  // で防止し、フラグ競合で発火が重複した場合の二重 disconnect は Lock.waitDisconnect の
  // isDisconnecting ガードで吸収する
  nonisolated(unsafe) private var disconnectTimerScheduled: Bool = false

  // 猶予タイマーの世代 (トークン)。キャンセル・破棄のたびに +1 する。
  // asyncAfter で投入済みのクロージャはキャンセルできないため、発火時に
  // 記録した世代が現在の世代と一致するか確認することで、無効化されたタイマーの
  // 発火を防ぐ (キャンセル後に再 .disconnected で新たなタイマーを開始した場合、
  // 古いタイマーが先に発火して猶予時間が短縮される問題の対策)
  nonisolated(unsafe) private var disconnectTimerGeneration: Int = 0
  var signalingOfferMessageDataChannels: [[String: Any]] = []
  var rpcChannel: RPCChannel?

  weak var mediaChannel: MediaChannel?

  var state: PeerChannelConnectionState {
    if let nativeChannel {
      let state = PeerChannelConnectionState(nativeChannel.connectionState)
      // connect() 開始後から finishConnecting() / basicDisconnect() までは onConnect が保持される。
      // そのため、 RTCPeerConnection を生成済みでも connectionState が .new の間は
      // 接続試行中として扱う。
      if onConnect != nil, state == .new {
        return .connecting
      }
      return state
    }

    if onConnect != nil {
      // offer.configuration を受け取るまで RTCPeerConnection を生成しないため、
      // nativeChannel が未生成でも、onConnect が保持されていれば接続試行中として扱う。
      return .connecting
    }

    return PeerChannelConnectionState(RTCPeerConnectionState.new)
  }

  var nativeChannel: RTCPeerConnection?

  var webRTCConfiguration: WebRTCConfiguration
  var clientId: String?
  var bundleId: String?
  var connectionId: String?

  var onConnect: ((Error?) -> Void)?

  var isAudioInputInitialized: Bool = false

  private var lock: Lock

  private var offerEncodings: [SignalingOffer.Encoding]?

  private var connectedAtLeastOnce: Bool = false

  /// DataChannel シグナリングで type: close メッセージを受信したときにメッセージ内容を保存するための変数
  private var dataChannelSignalingClose: (code: Int, reason: String)?

  // type: redirect のために SDP を保存しておく
  // 値が設定されている場合2回目の type: connect メッセージ送信とみなし、 redirect 中であると判断する
  private var sdp: String?

  // MARK: - Public methods

  required init(
    configuration: Configuration, signalingChannel: SignalingChannel,
    nativePeerChannelFactory: NativePeerChannelFactory,
    mediaChannel: MediaChannel?
  ) {
    self.signalingChannel = signalingChannel
    self.mediaChannel = mediaChannel
    self.configuration = configuration
    self.nativePeerChannelFactory = nativePeerChannelFactory
    webRTCConfiguration = configuration.webRTCConfiguration

    lock = Lock()
    super.init()
    lock.context = self

    signalingChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
      self?.disconnect(error: error, reason: reason)
    }

    signalingChannel.internalHandlers.onReceive = { [weak self] signaling in
      self?.handleSignalingOverWebSocket(signaling)
    }

    signalingChannel.internalHandlers.onReceiveJSON = { [weak self] json in
      self?.internalHandlers.onReceiveSignalingJSON?(json)
    }
  }

  func connect(handler: @escaping (Error?) -> Void) {
    if state == .connecting || state == .connected {
      handler(
        SoraError.connectionBusy(
          reason:
            "PeerChannel is already connected"))
      return
    }

    Logger.debug(type: .peerChannel, message: "try connecting")
    // このロックは finishConnecting() で解除される
    lock.lock()

    onConnect = handler

    // TODO(zztkm): WrapperVideoEncoderFactory は type: offer メッセージを受け取ったときに設定されるので、ここでの設定は不要かもしれない
    // サイマルキャストを利用する場合は、 RTCPeerConnection の生成前に WrapperVideoEncoderFactory を設定する必要がある
    WrapperVideoEncoderFactory.shared.simulcastEnabled = configuration.simulcastEnabled

    signalingChannel.connect { [weak self] error in
      guard let weakSelf = self else {
        return
      }

      if let sdp = weakSelf.sdp {
        weakSelf.sendConnectMessage(with: sdp, error: error, redirect: true)
      } else {
        weakSelf.sendConnectMessage(error: error)
      }
    }
  }

  func add(stream: MediaStream) {
    streams.append(stream)
    Logger.debug(type: .peerChannel, message: "call onAddStream")
    internalHandlers.onAddStream?(stream)
  }

  func remove(streamId: String) {
    let stream = streams.first { stream in stream.streamId == streamId }
    if let stream {
      remove(stream: stream)
    }
  }

  func remove(stream: MediaStream) {
    streams = streams.filter { each in each.streamId != stream.streamId }
    Logger.debug(type: .peerChannel, message: "call onRemoveStream")
    internalHandlers.onRemoveStream?(stream)
  }

  func add(iceCandidate: ICECandidate) {
    iceCandidates.append(iceCandidate)
  }

  func remove(iceCandidate: ICECandidate) {
    iceCandidates = iceCandidates.filter { each in each == iceCandidate }
  }

  func disconnect(error: Error?, reason: DisconnectReason) {
    switch state {
    case .closed:
      break
    default:
      Logger.debug(type: .peerChannel, message: "wait to disconnect")
      lock.waitDisconnect(error: error, reason: reason)
    }
  }

  // MARK: - Private methods

  private func sendConnectMessage(error: Error?) {
    if let error {
      lock.unlock()
      Logger.error(
        type: .peerChannel,
        message: "failed connecting to signaling channel (\(error.localizedDescription))")
      onConnect?(error)
      onConnect = nil
      return
    }

    if configuration.isSender {
      Logger.debug(type: .peerChannel, message: "try creating offer SDP")
      nativePeerChannelFactory
        .createClientOfferSDP(
          configuration: webRTCConfiguration,
          constraints: webRTCConfiguration.constraints
        ) { [weak self] sdp, sdpError in
          guard let self else {
            return
          }
          if let error = sdpError {
            Logger.debug(
              type: .peerChannel,
              message: "failed to create offer SDP (\(error.localizedDescription))")
          } else {
            self.sdp = sdp
            Logger.debug(
              type: .peerChannel,
              message: "did create offer SDP")
          }
          self.sendConnectMessage(with: sdp, error: error)
        }
    } else {
      sendConnectMessage(with: nil, error: nil)
    }
  }

  private func sendConnectMessage(with sdp: String?, error: Error?, redirect: Bool? = nil) {
    if error != nil {
      Logger.error(
        type: .peerChannel,
        // nil チェック直後のため安全
        // swiftlint:disable:next force_unwrapping
        message: "failed connecting to signaling channel (\(error!.localizedDescription))")
      disconnect(
        error: SoraError.peerChannelError(reason: "failed connecting to signaling channel"),
        reason: .signalingFailure)
      return
    }

    Logger.debug(
      type: .peerChannel,
      message: "did connect to signaling channel")

    let connect = makeSignalingConnect(sdp: sdp, redirect: redirect)

    Logger.debug(type: .peerChannel, message: "send connect")
    signalingChannel.send(message: Signaling.connect(connect))
  }

  /// Configuration から SignalingConnect を構築する。
  ///
  /// sendConnectMessage から呼び出す。テストから利用するため internal とする。
  func makeSignalingConnect(sdp: String?, redirect: Bool?) -> SignalingConnect {
    var role: SignalingRole
    switch configuration.role {
    case .sendonly:
      role = .sendonly
    case .recvonly:
      role = .recvonly
    case .sendrecv:
      role = .sendrecv
    }

    let soraClient = "Sora iOS SDK \(SDKInfo.version)"
    let webRTCVersion =
      "Shiguredo-build \(WebRTCInfo.version) (\(WebRTCInfo.version.dropFirst()).\(WebRTCInfo.branch).\(WebRTCInfo.commitPosition).\(WebRTCInfo.maintenanceVersion) \(WebRTCInfo.shortRevision))"

    let simulcast = configuration.simulcastEnabled
    return SignalingConnect(
      role: role,
      channelId: configuration.channelId,
      clientId: configuration.clientId,
      bundleId: configuration.bundleId,
      metadata: configuration.signalingConnectMetadata,
      notifyMetadata: configuration.signalingConnectNotifyMetadata,
      sdp: sdp,
      multistreamEnabled: configuration.multistreamEnabled,
      videoEnabled: configuration.videoEnabled,
      videoCodec: configuration.videoCodec,
      videoBitRate: configuration.videoBitRate,
      audioEnabled: configuration.audioEnabled,
      audioCodec: configuration.audioCodec,
      audioBitRate: configuration.audioBitRate,
      spotlightEnabled: configuration.spotlightEnabled,
      spotlightNumber: configuration.spotlightNumber,
      spotlightFocusRid: configuration.spotlightFocusRid,
      spotlightUnfocusRid: configuration.spotlightUnfocusRid,
      simulcastEnabled: simulcast,
      simulcastRid: configuration.simulcastRid,
      simulcastRequestRid: configuration.simulcastRequestRid,
      soraClient: soraClient,
      webRTCVersion: webRTCVersion,
      environment: DeviceInfo.current.description,
      dataChannelSignaling: configuration.dataChannelSignaling,
      ignoreDisconnectWebSocket: configuration.ignoreDisconnectWebSocket,
      audioStreamingLanguageCode: configuration.audioStreamingLanguageCode,
      redirect: redirect,
      forwardingFilter: configuration.forwardingFilter,
      forwardingFilters: configuration.forwardingFilters,
      vp9Params: configuration.videoCodec == .vp9 ? configuration.videoVp9Params : nil,
      av1Params: configuration.videoCodec == .av1 ? configuration.videoAv1Params : nil,
      h264Params: configuration.videoCodec == .h264 ? configuration.videoH264Params : nil,
      h265Params: configuration.videoCodec == .h265 ? configuration.videoH265Params : nil
    )
  }

  private func initializeSenderStream(mid: [String: String]? = nil) {
    guard let nativeChannel else {
      Logger.debug(type: .peerChannel, message: "nativeChannel shoud not be nil")
      return
    }

    Logger.debug(
      type: .peerChannel,
      message: "initialize sender stream")

    let nativeStream =
      nativePeerChannelFactory
      .createNativeSenderStream(
        streamId: configuration.publisherStreamId,
        videoTrackId:
          configuration.videoEnabled ? configuration.publisherVideoTrackId : nil,
        audioTrackId:
          configuration.audioEnabled ? configuration.publisherAudioTrackId : nil,
        constraints: webRTCConfiguration.constraints)
    let stream = BasicMediaStream(
      peerChannel: self,
      nativeStream: nativeStream)

    if let mid {
      Logger.info(type: .peerChannel, message: "mid => \(mid)")
      if let audioMid = mid["audio"] {
        guard
          let audioTransceiver = (nativeChannel.transceivers.first { $0.mid == audioMid })
        else {
          disconnect(
            error: SoraError.peerChannelError(
              reason: "transceiver for audio not found"),
            reason: .signalingFailure)
          return
        }

        var error: NSError?
        audioTransceiver.setDirection(RTCRtpTransceiverDirection.sendOnly, error: &error)
        guard error == nil else {
          disconnect(
            error: SoraError.peerChannelError(
              reason: "failed to set direction to transceiver for audio"),
            reason: .signalingFailure)
          return
        }

        audioTransceiver.sender.streamIds = [nativeStream.streamId]

        if let audioTrack = nativeStream.audioTracks.first {
          audioTransceiver.sender.track = audioTrack
        }
      }

      if let videoMid = mid["video"] {
        guard
          let videoTransceiver = (nativeChannel.transceivers.first { $0.mid == videoMid })
        else {
          disconnect(
            error: SoraError.peerChannelError(
              reason: "transceiver for video not found"),
            reason: .signalingFailure)
          return
        }

        var error: NSError?
        videoTransceiver.setDirection(RTCRtpTransceiverDirection.sendOnly, error: &error)
        guard error == nil else {
          disconnect(
            error: SoraError.peerChannelError(
              reason: "failed to set direction to transceiver for video"),
            reason: .signalingFailure)
          return
        }

        videoTransceiver.sender.streamIds = [nativeStream.streamId]
        if let videoTrack = nativeStream.videoTracks.first {
          videoTransceiver.sender.track = videoTrack
        }

        if let degradationPreference = configuration.webRTCConfiguration
          .degradationPreference
        {
          let parameters = videoTransceiver.sender.parameters
          parameters.degradationPreference = NSNumber(
            value: degradationPreference.nativeValue.rawValue)
          videoTransceiver.sender.parameters = parameters
        }

        Logger.debug(
          type: .peerChannel,
          message:
            "sender.parameters => \(String(describing: videoTransceiver.sender.parameters))"
        )
      }
    } else {
      // mid なしの場合はエラーにする
      Logger.error(type: .peerChannel, message: "mid not found")
      disconnect(
        error: SoraError.peerChannelError(reason: "mid not found"),
        reason: .signalingFailure)
      return
    }

    // マイクの初期化
    if configuration.audioEnabled {
      if !configuration.dummyAudioEnabled {
        initializeAudioInput()
      } else {
        // AVAudioSession の設定は DummyAudioDevice.initialize(with:) が行うためスキップする
        Logger.debug(
          type: .peerChannel,
          message: "dummy audio enabled, skip initialize audio input")
      }
    } else if configuration.dummyAudioEnabled {
      // 音声トラック自体が生成されないためダミー音声も無効となる
      Logger.warn(
        type: .peerChannel,
        message: "dummy audio enabled but audioEnabled is false, dummy audio is disabled")
    }

    // カメラの初期化
    if configuration.videoEnabled, configuration.cameraSettings.isEnabled,
      configuration.initialCameraEnabled
    {
      initializeCameraVideoCapture(stream: stream)
    }

    add(stream: stream)
    Logger.debug(
      type: .peerChannel,
      message: "create publisher stream (id: \(configuration.publisherStreamId))")
  }

  private func initializeAudioInput() {
    if isAudioInputInitialized {
      Logger.debug(
        type: .peerChannel,
        message: "audio input is already initialized")
    } else {
      Logger.debug(
        type: .peerChannel,
        message: "initialize audio input")

      let session = RTCAudioSession.sharedInstance()

      // 初期状態でマイクをミュートするかを設定します。
      // setInitialMicrophoneMute はマイクミュートを有効にするか、initialMicrophoneEnabled は初期のマイクを有効にするか
      // の設定のため、initialMicrophoneEnabled の否定値を渡します。
      //
      // 入力初期化後は変更できないため、 initializeInput の前に設定します。
      let initialMicrophoneMute = !configuration.initialMicrophoneEnabled
      if !session.setInitialMicrophoneMute(initialMicrophoneMute) {
        Logger.warn(type: .peerChannel, message: "failed to setInitialMicrophoneMute")
      }

      // カテゴリをマイク用途のものに変更する
      // libwebrtc の内部で参照される RTCAudioSessionConfiguration を使う必要がある
      Logger.debug(
        type: .peerChannel,
        message: "change audio session category (playAndRecord)")
      RTCAudioSessionConfiguration.webRTC().category =
        AVAudioSession.Category.playAndRecord.rawValue

      session.initializeInput { error in
        if let error {
          Logger.debug(
            type: .peerChannel,
            message: "failed to initialize audio input => \(error.localizedDescription)"
          )
          return
        }
        self.isAudioInputInitialized = true
        Logger.debug(
          type: .peerChannel,
          message:
            "audio input is initialized => category \(RTCAudioSession.sharedInstance().category)"
        )
      }
    }
  }

  private func initializeCameraVideoCapture(stream: MediaStream) {
    let position = configuration.cameraSettings.position

    // position に対応した CameraVideoCapturer を取得する
    let capturer: CameraVideoCapturer
    switch position {
    case .front:
      guard let front = CameraVideoCapturer.front else {
        Logger.error(type: .peerChannel, message: "front camera is not found")
        return
      }
      capturer = front
    case .back:
      guard let back = CameraVideoCapturer.back else {
        Logger.error(type: .peerChannel, message: "back camera is not found")
        return
      }
      capturer = back
    case .unspecified:
      Logger.error(
        type: .peerChannel, message: "CameraSettings.position should not be .unspecified")
      return
    @unknown default:
      guard let device = CameraVideoCapturer.device(for: position) else {
        Logger.error(type: .peerChannel, message: "device is not found for position")
        return
      }
      capturer = CameraVideoCapturer(device: device)
    }

    // デバイスに対応したフォーマットとフレームレートを取得する
    guard
      let format = CameraVideoCapturer.format(
        width: configuration.cameraSettings.resolution.width,
        height: configuration.cameraSettings.resolution.height,
        for: capturer.device,
        frameRate: configuration.cameraSettings.frameRate)
    else {
      Logger.error(
        type: .peerChannel,
        message:
          "CameraVideoCapturer.suitableFormat failed: suitable format rate is not found")
      return
    }

    guard
      let frameRate = CameraVideoCapturer.maxFrameRate(
        configuration.cameraSettings.frameRate, for: format)
    else {
      Logger.error(
        type: .peerChannel,
        message:
          "CameraVideoCapturer.suitableFormat failed: suitable frame rate is not found")
      return
    }

    if let current = CameraVideoCapturer.current, current.isRunning {
      // CameraVideoCapturer.current を停止してから capturer を start する
      current.stop { (error: Error?) in
        guard error == nil else {
          Logger.debug(
            type: .peerChannel,
            // guard の else 節で非 nil が保証されるため安全
            // swiftlint:disable:next force_unwrapping
            message: "CameraVideoCapturer.stop failed =>  \(error!)")
          return
        }

        capturer.start(format: format, frameRate: frameRate) { error in
          guard error == nil else {
            Logger.debug(
              type: .peerChannel,
              // guard の else 節で非 nil が保証されるため安全
              // swiftlint:disable:next force_unwrapping
              message: "CameraVideoCapturer.start failed =>  \(error!)")
            return
          }
          Logger.debug(
            type: .peerChannel,
            message: "set CameraVideoCapturer to sender stream")
          capturer.stream = stream
        }
      }
    } else {
      capturer.start(format: format, frameRate: frameRate) { error in
        guard error == nil else {
          Logger.debug(
            type: .peerChannel,
            // guard の else 節で非 nil が保証されるため安全
            // swiftlint:disable:next force_unwrapping
            message: "CameraVideoCapturer.start failed =>  \(error!)")
          return
        }
        Logger.debug(
          type: .peerChannel,
          message: "set CameraVideoCapturer to sender stream")
        capturer.stream = stream
      }
    }
  }

  /// `initializeSenderStream()` にて生成されたリソースを開放するための、対になるメソッドです。
  private func terminateSenderStream() {
    if configuration.videoEnabled || configuration.cameraSettings.isEnabled {
      // CameraVideoCapturer が起動中の場合は停止する
      if let current = CameraVideoCapturer.current {
        current.stop { error in
          if error != nil {
            Logger.debug(
              type: .peerChannel,
              // nil チェック直後のため安全
              // swiftlint:disable:next force_unwrapping
              message: "failed to stop CameraVideoCapturer =>  \(error!)")
          }
        }
      }
    }
  }

  private func createAnswer(
    isSender: Bool,
    offer: String,
    constraints: RTCMediaConstraints,
    initialOffer: Bool = false,
    mid: [String: String]? = nil,
    handler: @escaping (String?, Error?) -> Void
  ) {
    guard let nativeChannel else {
      Logger.debug(type: .peerChannel, message: "nativeChannel shoud not be nil")
      return
    }

    Logger.debug(type: .peerChannel, message: "try create answer")
    Logger.debug(type: .peerChannel, message: offer)

    Logger.debug(type: .peerChannel, message: "try setting remote description")
    let offer = RTCSessionDescription(type: .offer, sdp: offer)
    nativeChannel.setRemoteDescription(offer) { [weak self] error in
      guard let self else {
        return
      }
      guard error == nil else {
        Logger.debug(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed setting remote description: (\(error!.localizedDescription)")
        handler(nil, error)
        return
      }

      guard let nativeChannel = self.nativeChannel else {
        Logger.debug(type: .peerChannel, message: "nativeChannel shoud not be nil")
        return
      }

      Logger.debug(type: .peerChannel, message: "did set remote description")
      Logger.debug(type: .peerChannel, message: "\(offer.sdpDescription)")

      if isSender {
        if initialOffer {
          self.initializeSenderStream(mid: mid)
        }
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "try creating native answer")
      nativeChannel.answer(for: constraints) { answer, error in
        guard error == nil else {
          Logger.debug(
            type: .peerChannel,
            // guard の else 節で非 nil が保証されるため安全
            // swiftlint:disable:next force_unwrapping
            message: "failed creating native answer (\(error!.localizedDescription)")
          handler(nil, error)
          return
        }

        guard let nativeChannel = self.nativeChannel else {
          Logger.debug(type: .peerChannel, message: "nativeChannel shoud not be nil")
          return
        }

        Logger.debug(type: .peerChannel, message: "did create answer")

        Logger.debug(type: .peerChannel, message: "try setting local description")
        // guard error == nil 直後のため安全
        // swiftlint:disable:next force_unwrapping
        nativeChannel.setLocalDescription(answer!) { error in
          guard error == nil else {
            Logger.debug(
              type: .peerChannel,
              message: "failed setting local description")
            handler(nil, error)
            return
          }
          Logger.debug(
            type: .peerChannel,
            message: "did set local description")
          Logger.debug(
            type: .peerChannel,
            // guard error == nil 直後のため安全
            // swiftlint:disable:next force_unwrapping
            message: "\(answer!.sdpDescription)")
          Logger.debug(
            type: .peerChannel,
            message: "did create answer")
          // guard error == nil 直後のため安全
          // swiftlint:disable:next force_unwrapping
          handler(answer!.sdp, nil)
        }
      }
    }
  }

  private func updateSenderOfferEncodings() {
    guard let nativeChannel else {
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
      return
    }

    guard let oldEncodings = offerEncodings else {
      return
    }

    Logger.debug(type: .peerChannel, message: "update sender offer encodings")
    for sender in nativeChannel.senders {
      sender.updateOfferEncodings(oldEncodings)
    }
  }

  private func createAndSendAnswer(offer: SignalingOffer) {
    Logger.debug(type: .peerChannel, message: "try sending answer")
    offerEncodings = offer.encodings

    if let config = offer.configuration {
      Logger.debug(type: .peerChannel, message: "update configuration")
      Logger.debug(
        type: .peerChannel, message: "ICE server infos => \(config.iceServerInfos)")
      Logger.debug(
        type: .peerChannel, message: "ICE transport policy => \(config.iceTransportPolicy)")
      webRTCConfiguration.iceServerInfos = config.iceServerInfos
      webRTCConfiguration.iceTransportPolicy = config.iceTransportPolicy
    }

    webRTCConfiguration.isInsecure = configuration.insecure
    if configuration.insecure {
      Logger.warn(
        type: .peerChannel,
        message: "insecure mode is enabled: TURN-TLS certificate verification is skipped")
    }

    // offer.configuration で ICE サーバー設定を受け取った後に NativePeerChannel を
    // 生成することで TURN-TLS 向けの certificateVerifier を正しく設定する。

    // CA 証明書のパース
    // 既に SignalingChannel.connect() でパース成功しているため、
    // この throw パスは実運用では到達しない防御的コードである
    let caCertificates: [SecCertificate]?
    do {
      caCertificates = try configuration.parsedCACertificates()
    } catch {
      lock.unlock()
      disconnect(
        error: error,
        reason: .signalingFailure)
      return
    }

    nativeChannel =
      nativePeerChannelFactory
      .createNativePeerChannel(
        configuration: webRTCConfiguration,
        constraints: webRTCConfiguration.constraints,
        proxy: configuration.proxy,
        caCertificates: caCertificates,
        delegate: self)
    guard let nativeChannel else {
      // connect() で取得した初期ロックをここで解放しないと、
      // disconnect が defer されたままになってしまう。
      lock.unlock()
      disconnect(
        error: SoraError.peerChannelError(reason: "createNativePeerChannel failed"),
        reason: .signalingFailure)
      return
    }
    nativeChannel.setConfiguration(webRTCConfiguration.nativeValue)

    guard lock.lock() else {
      Logger.debug(type: .peerChannel, message: "already disconnecting, skip create answer")
      return
    }
    createAnswer(
      isSender: configuration.isSender,
      offer: offer.sdp,
      constraints: webRTCConfiguration.nativeConstraints,
      initialOffer: true,
      mid: offer.mid
    ) { sdp, error in
      guard error == nil else {
        Logger.error(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed to create answer (\(error!.localizedDescription))")
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "failed to create answer"),
          reason: .signalingFailure)
        return
      }

      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      let answer = SignalingAnswer(sdp: sdp!)
      self.signalingChannel.send(message: Signaling.answer(answer))
      self.lock.unlock()
      Logger.debug(type: .peerChannel, message: "did send answer")
    }
  }

  private func createAndSendUpdateAnswer(forOffer offer: String) {
    Logger.debug(type: .peerChannel, message: "create and send update-answer")
    guard lock.lock() else {
      Logger.debug(type: .peerChannel, message: "already disconnecting, skip create update-answer")
      return
    }
    createAnswer(
      isSender: false,
      offer: offer,
      constraints: webRTCConfiguration.nativeConstraints
    ) { answer, error in
      guard error == nil else {
        Logger.error(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed to create update-answer (\(error!.localizedDescription)")
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "failed to create update-answer"),
          reason: .signalingFailure)
        return
      }

      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      let message = Signaling.update(SignalingUpdate(sdp: answer!))
      self.signalingChannel.send(message: message)

      if self.configuration.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      self.internalHandlers.onUpdate?(answer!)

      self.lock.unlock()
    }
  }

  private func createAndSendReAnswer(forReOffer reOffer: String) {
    Logger.debug(type: .peerChannel, message: "create and send re-answer")

    createAnswer(
      isSender: false,
      offer: reOffer,
      constraints: webRTCConfiguration.nativeConstraints
    ) { answer, error in
      // 2025.1.1 までは lock() 呼び出しをこのクロージャーの外 = createAnswer の直前で行っていたが、
      // この場合、 SDP 再ハンドシェイク時に SDP を local description に設定する際に EXC_BAD_ACCESS (不正なメモリアクセス) が発生し、
      // アプリがクラッシュしてしまうことがあったが、lock() の呼び出しをクロージャー内にすることで、不正なメモリアクセスを防ぐことができるように
      // なったため、ここに移動させた (createAndSendReAnswerOverDataChannel も同様の理由で lock() の位置を移動)
      guard self.lock.lock() else {
        Logger.debug(type: .peerChannel, message: "already disconnecting, skip re-answer")
        return
      }
      guard error == nil else {
        Logger.error(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed to create re-answer (\(error!.localizedDescription)")
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "failed to create re-answer"),
          reason: .signalingFailure)
        return
      }

      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      let message = Signaling.reAnswer(SignalingReAnswer(sdp: answer!))
      self.signalingChannel.send(message: message)

      if self.configuration.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      self.internalHandlers.onUpdate?(answer!)

      self.lock.unlock()
    }
  }

  private func createAndSendReAnswerOverDataChannel(forReOffer reOffer: String) {
    Logger.debug(type: .peerChannel, message: "create and send re-answer over DataChannel")

    guard let dataChannel = dataChannels["signaling"] else {
      Logger.debug(type: .peerChannel, message: "DataChannel for label: signaling is unavailable")
      return
    }

    createAnswer(
      isSender: false,
      offer: reOffer,
      constraints: webRTCConfiguration.nativeConstraints
    ) { answer, error in
      // NOTE: PeerChannel のインスタンスをキャプチャすることを明示的に指定する必要があるため、self が必要
      guard self.lock.lock() else {
        Logger.debug(
          type: .peerChannel, message: "already disconnecting, skip re-answer over DataChannel")
        return
      }
      guard error == nil else {
        Logger.error(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed to create re-answer: error => (\(error!.localizedDescription)")
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "failed to create re-answer"),
          reason: .signalingFailure)
        return
      }

      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      let reAnswer = Signaling.reAnswer(SignalingReAnswer(sdp: answer!))

      var data: Data?
      do {
        data = try JSONEncoder().encode(reAnswer)
      } catch {
        Logger.error(
          type: .peerChannel,
          message: "failed to encode re-answer: error => (\(error.localizedDescription)")
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(
            reason: "failed to encode re-answer message to json"),
          reason: .signalingFailure)
        return
      }

      if let data {
        let ok = dataChannel.send(data)
        if !ok {
          Logger.error(
            type: .peerChannel,
            message: "failed to send re-answer message over DataChannel")
          self.lock.unlock()
          self.disconnect(
            error: SoraError.peerChannelError(
              reason: "failed to send re-answer message over DataChannel"),
            reason: .signalingFailure)
          return
        }
      }

      if self.configuration.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      // guard error == nil 直後のため安全
      // swiftlint:disable:next force_unwrapping
      self.internalHandlers.onUpdate?(answer!)

      self.lock.unlock()
    }
  }

  private func handleSignalingOverWebSocket(_ signaling: Signaling) {
    Logger.debug(
      type: .mediaStream,
      message: "handle signaling over WebSocket => \(signaling.typeName())")
    switch signaling {
    case .offer(let offer):
      signalingChannel.setConnectedUrl()

      clientId = offer.clientId
      bundleId = offer.bundleId
      connectionId = offer.connectionId
      if let dataChannels = offer.dataChannels {
        signalingChannel.dataChannelSignaling = true
        signalingOfferMessageDataChannels = dataChannels
      }

      // offer.simulcast が設定されている場合、WrapperVideoEncoderFactory.shared.simulcastEnabled を上書きする
      if let simulcast = offer.simulcast {
        WrapperVideoEncoderFactory.shared.simulcastEnabled = simulcast
      }

      createAndSendAnswer(offer: offer)
    // NOTE: シグナリング type: update は Sora 2022.1.0 で廃止された
    // SDK では過去のバージョンとの互換性のために残しているが、いずれは削除する予定
    case .update(let update):
      if configuration.isMultistream {
        createAndSendUpdateAnswer(forOffer: update.sdp)
      }
    case .reOffer(let reOffer):
      createAndSendReAnswer(forReOffer: reOffer.sdp)

    case .ping(let ping):
      let pong = SignalingPong()
      if ping.statisticsEnabled == true {
        nativeChannel?.statistics { [weak self] report in
          guard let self else {
            return
          }
          var json: [String: Any] = ["type": "pong"]
          let stats = Statistics(contentsOf: report)
          json["stats"] = stats.jsonObject
          do {
            let data = try JSONSerialization.data(
              withJSONObject: json, options: [.prettyPrinted])
            if let message = String(data: data, encoding: .utf8) {
              self.signalingChannel.send(text: message)
            } else {
              self.signalingChannel.send(message: .pong(pong))
            }
          } catch {
            self.signalingChannel.send(message: .pong(pong))
          }
        }
      } else {
        signalingChannel.send(message: .pong(pong))
      }
    case .switched(let switched):
      switchedToDataChannel = true
      signalingChannel.ignoreDisconnectWebSocket = switched.ignoreDisconnectWebSocket ?? false

      if let mediaChannel, let onDataChannel = mediaChannel.handlers.onDataChannel {
        onDataChannel(mediaChannel)
      }
    case .redirect(let redirect):
      signalingChannel.redirect(location: redirect.location)
    default:
      break
    }

    Logger.debug(type: .peerChannel, message: "call onReceiveSignaling")
    internalHandlers.onReceiveSignaling?(signaling)
  }

  func handleSignalingOverDataChannel(_ signaling: Signaling) {
    Logger.debug(
      type: .peerChannel,
      message: "handle signaling over DataChannel => \(signaling.typeName())")
    switch signaling {
    case .reOffer(let reOffer):
      createAndSendReAnswerOverDataChannel(forReOffer: reOffer.sdp)
    case .push, .notify:
      // 処理は不要
      break
    case .close(let close):
      // dataChannelSignalingClose に格納した値は basicDisconnect で利用される
      dataChannelSignalingClose = (code: close.code, reason: close.reason)
    default:
      Logger.error(
        type: .peerChannel, message: "unexpected signaling type => \(signaling.typeName())")
    }

    Logger.debug(type: .peerChannel, message: "call onReceiveSignaling")
    internalHandlers.onReceiveSignaling?(signaling)
  }

  /// DataChannel の signaling ラベル受信を契機に WebSocket 切断をスケジュールする
  func scheduleWebSocketDisconnectIfNeeded() {
    // DataChannel の delegate コールバックは WebRTC の内部スレッドから呼ばれる。
    // webSocketDisconnectScheduled は nonisolated(unsafe) であり、
    // 以下の条件チェックと flag 更新はアトミックではないが、
    // webSocketChannel.disconnect 二重実行しても問題ないため、
    // 重複スケジュールを防ぐのはベストエフォートで十分。
    if webSocketDisconnectScheduled { return }
    guard switchedToDataChannel, signalingChannel.ignoreDisconnectWebSocket else { return }
    guard state != .closed else { return }
    guard let webSocketChannel = signalingChannel.webSocketChannel else { return }

    webSocketDisconnectScheduled = true

    Logger.info(
      type: .peerChannel,
      message: "scheduling WebSocket disconnect after \(Self.switchedDisconnectDelay) seconds")

    // DataChannel 確立直後も WebSocket 経由の送信キューにメッセージが残っている可能性があるため、
    // 既存の遅延 (switchedDisconnectDelay) を維持する
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + Self.switchedDisconnectDelay
    ) { [weak self] in
      guard let self else { return }
      if self.state != .closed {
        Logger.info(
          type: .peerChannel,
          message: "disconnecting WebSocket after DataChannel signaling established")
        webSocketChannel.disconnect(error: nil)
      }
    }
  }

  /// DataChannel の RPC で受信したメッセージを処理する。
  func handleRPCMessage(_ data: Data) {
    guard let rpcChannel else {
      Logger.warn(type: .peerChannel, message: "rpcChannel is unavailable")
      return
    }
    rpcChannel.handleMessage(data)
  }

  private func finishConnecting() {
    Logger.debug(type: .peerChannel, message: "did connect")
    Logger.debug(
      type: .peerChannel,
      message: "media streams = \(streams.count)")
    Logger.debug(
      type: .peerChannel,
      message: "native senders = \(nativeChannel?.senders.count ?? 0)")
    Logger.debug(
      type: .peerChannel,
      message: "native receivers = \(nativeChannel?.receivers.count ?? 0)")

    if onConnect != nil {
      Logger.debug(type: .peerChannel, message: "call connect(handler:)")
      // nil チェック直後のため安全
      // swiftlint:disable:next force_unwrapping
      onConnect!(nil)
      onConnect = nil
    }
    lock.unlock()
  }

  private func basicDisconnect(error: Error?, reason: DisconnectReason) {
    Logger.debug(
      type: .peerChannel,
      message:
        "try disconnecting: error => \(String(describing: error != nil ? error?.localizedDescription : "nil")), reason => \(reason)"
    )
    if let error {
      Logger.error(
        type: .peerChannel,
        message: "error: \(error.localizedDescription)")
    }

    if let rpcChannel {
      rpcChannel.invalidate(
        reason: SoraError.rpcDataChannelClosed(reason: reason.description))
      self.rpcChannel = nil
    }

    sendDisconnectMessageIfNeeded(reason: reason, error: error)

    if configuration.isSender {
      terminateSenderStream()
    }

    // ダミー音声デバイスの停止。terminateSenderStream は送信側のカメラ停止のみを行い、
    // 音声デバイスの停止は行わないため、recvonly を含む全ロールで実行する。
    // nativeChannel?.close() より前に実行し、ADM スレッドが生存している状態で
    // terminateDevice の dispatchSync を実行する
    if configuration.dummyAudioEnabled,
      let dummyDevice = nativePeerChannelFactory.dummyAudioDevice
    {
      dummyDevice.terminateDevice()
    }

    for stream in streams {
      stream.terminate()
    }
    streams.removeAll()

    // 接続完了後の切断検出タイマーを破棄する。
    // close 後に遅延して届く .disconnected 通知でタイマーが再開始されても、
    // 発火時の state チェックで state == .closed になるため何も起きない
    // (pending のタイマーは世代を進めることで無効化される)
    cancelDisconnectTimer()
    // 接続完了フラグをリセットする。切断後に MediaChannel が再接続でこの
    // PeerChannel を再利用した場合、接続試行中の .disconnected でタイマーが
    // 開始されないようにするため (接続試行中は ConnectionTimer が処理する)
    connectedAtLeastOnce = false

    nativeChannel?.close()

    var error = error
    // DataChannel が正常にクローズされ (reason == .dataChannelClosed)、
    // かつ事前に Sora から "close" メッセージを受信していた場合 (dataChannelSignalingClose != nil)、
    // error を SoraError.dataChannelClosed にする
    if let dataChannelSignalingClose = dataChannelSignalingClose,
      case .dataChannelClosed = reason
    {
      error = SoraError.dataChannelClosed(
        statusCode: dataChannelSignalingClose.code, reason: dataChannelSignalingClose.reason
      )
    }

    // TODO(zztkm): signalingChannel.ignoreDisconnectWebSocket が true の場合はこの処理は不要かもしれない
    signalingChannel.disconnect(error: error, reason: reason)

    Logger.debug(type: .peerChannel, message: "call onDisconnect")
    internalHandlers.onDisconnect?(error, reason)

    if onConnect != nil {
      Logger.debug(type: .peerChannel, message: "call connect(handler:)")
      // nil チェック直後のため安全
      // swiftlint:disable:next force_unwrapping
      onConnect!(error)
      onConnect = nil
    }

    // disconnect したあとは基本的に PeerChannel を使い回さないはずだが、一応 nil にしておく
    dataChannelSignalingClose = nil
    webSocketDisconnectScheduled = false

    Logger.debug(type: .peerChannel, message: "did disconnect")
  }

  // https://sora-doc.shiguredo.jp/SORA_CLIENT
  private func sendDisconnectMessageIfNeeded(reason: DisconnectReason, error: Error?) {
    if state == .failed, reason != .peerConnectionStateDisconnected {
      // この関数に到達した時点で .failed なので、メッセージの送信は不要。
      // ただし .peerConnectionStateDisconnected は猶予タイマー満了による切断であり、
      // タイマー発火時に .disconnected であることを確認済みのため、その後に .failed へ
      // 遷移してもシグナリング WebSocket は生存している可能性がある。
      // サーバー側セッションの即時解放のために送信する
      return
    }

    // 毎回タイプすると長いので変数を定義
    let dataChannelSignaling = signalingChannel.dataChannelSignaling
    let ignoreDisconnectWebSocket = signalingChannel.ignoreDisconnectWebSocket

    switch reason {
    case .signalingFailure, .peerConnectionStateFailed:
      // 接続試行中の失敗や ICE が完全に失敗した場合は、シグナリング経路が
      // 生きている保証がないためメッセージを送らない
      break
    case .user, .noError:
      // reason: .user の場合、 error はユーザーから渡されているので考慮しない
      let noError = Signaling.disconnect(SignalingDisconnect(reason: "NO-ERROR"))
      if !dataChannelSignaling {
        // WebSocket シグナリング構成。WebSocket に送信する
        signalingChannel.send(message: noError)
      } else if switchedToDataChannel {
        // DataChannel へ切り替え済みの場合は DataChannel に送信する
        sendMessageOverDataChannel(message: noError)
      } else {
        // DataChannel へ切り替える前は WebSocket に送信する
        signalingChannel.send(message: noError)
      }
    case .peerConnectionStateDisconnected:
      // ネットワーク切断で DataChannel は同じ ICE (DTLS/SCTP) 上にあり死んでいるため、
      // 送信先はシグナリング WebSocket のみにする (生存していればサーバー側セッションの
      // 即時解放が可能。送らないとサーバー側セッションがタイムアウトまで残存し、
      // 即時再接続時に DUPLICATED-CHANNEL-ID レースが発生しやすくなる)
      let noError = Signaling.disconnect(SignalingDisconnect(reason: "NO-ERROR"))
      signalingChannel.send(message: noError)
    case .webSocket:
      if ignoreDisconnectWebSocket {
        break
      }

      if let soraError = error as? SoraError {
        Logger.debug(
          type: .peerChannel,
          message:
            "succeeded to down cast error to SoraError: \(soraError.localizedDescription)"
        )
        switch soraError {
        case .webSocketClosed:
          let wsOnClose = Signaling.disconnect(
            SignalingDisconnect(reason: "WEBSOCKET-ONCLOSE"))
          sendMessageOverDataChannel(message: wsOnClose)
        case .webSocketError:
          let wsOnError = Signaling.disconnect(
            SignalingDisconnect(reason: "WEBSOCKET-ONERROR"))
          sendMessageOverDataChannel(message: wsOnError)
        default:
          break
        }
      }
    case .dataChannelClosed:
      Logger.warn(type: .peerChannel, message: "DataChannel was closed")
    default:
      break
    }
  }

  private func sendMessageOverDataChannel(message: Signaling) {
    guard let dataChannel = dataChannels["signaling"] else {
      Logger.debug(
        type: .peerChannel, message: "DataChannel for label: signaling is unavailable")
      return
    }

    var data: Data?
    do {
      data = try JSONEncoder().encode(message)
    } catch {
      Logger.error(
        type: .peerChannel,
        message:
          "failed to encode \(message.typeName()) message to json: error => (\(error.localizedDescription)"
      )
    }

    if let data {
      let ok = dataChannel.send(data)
      if !ok {
        Logger.error(
          type: .peerChannel,
          message: "failed to send \(message.typeName()) message over DataChannel")
      }
    }
  }

  // MARK: - RTCPeerConnectionDelegate

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didChange stateChanged: RTCSignalingState
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "signaling state: \(stateChanged)")
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didAdd stream: RTCMediaStream
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "try add a stream (id: \(stream.streamId))")
    for cur in streams {
      if cur.streamId == stream.streamId {
        Logger.debug(
          type: .peerChannel,
          message: "stream already exists")
        return
      }
    }

    if configuration.isMultistream,
      stream.streamId == clientId
    {
      Logger.debug(
        type: .peerChannel,
        message: "stream already exists in multistream")
      return
    }

    Logger.debug(type: .peerChannel, message: "add a stream")
    stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max
    let stream = BasicMediaStream(
      peerChannel: self,
      nativeStream: stream)
    add(stream: stream)
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didRemove stream: RTCMediaStream
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "removed a media stream (id: \(stream.streamId))")
    remove(streamId: stream.streamId)
  }

  func peerConnectionShouldNegotiate(_ nativePeerConnection: RTCPeerConnection) {
    Logger.debug(type: .peerChannel, message: "required negatiation")
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didChange newState: RTCIceConnectionState
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "ICE connection state: \(newState)")
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "ICE gathering state: \(newState)")
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "peer connection state: \(String(describing: newState))")
    switch newState {
    case .failed:
      cancelDisconnectTimer()
      disconnect(
        error: SoraError.peerChannelError(reason: "peer connection state: failed"),
        reason: .peerConnectionStateFailed)
    case .connected:
      // RTCPeerConnectionState は connected -> disconnected -> connected などと遷移し得るが、
      // finishConnecting は複数回実行するとエラーになるため、connectedAtLeastOnce でガードする。
      // 遷移のパターンは以下のページの Figure 2 Non-normative ICE transport state transition diagram を参照
      // (図は RTCPeerConnectionState ではなく RTCIceTransportState のものなので注意)
      // https://www.w3.org/TR/webrtc/#dom-rtcicetransportstate
      if !connectedAtLeastOnce {
        finishConnecting()
        connectedAtLeastOnce = true
      }
      cancelDisconnectTimer()
    case .connecting:
      cancelDisconnectTimer()
    case .disconnected:
      scheduleDisconnectTimerIfNeeded()
    default:
      break
    }
  }

  /// 接続完了後に `RTCPeerConnectionState` が `.disconnected` のまま停滞した場合に、
  /// 猶予時間の経過後に切断するためのタイマーを開始する。
  ///
  /// 発火時に `RTCPeerConnectionState` を再確認し、 `.disconnected` のままの場合のみ
  /// 切断する。また、 `Lock.unlock` の遅延実行経路では接続が回復している場合は
  /// 切断をキャンセルする (いずれも発火・実行と `.connected` への回復の競合対策)。
  private func scheduleDisconnectTimerIfNeeded() {
    guard connectedAtLeastOnce else {
      return
    }
    guard !disconnectTimerScheduled else {
      return
    }
    disconnectTimerScheduled = true
    Logger.debug(
      type: .peerChannel,
      message: "scheduling disconnect timer after \(Self.disconnectedGracePeriod) seconds")
    let generation = disconnectTimerGeneration
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + Self.disconnectedGracePeriod
    ) { [weak self] in
      guard let self else {
        return
      }
      guard generation == self.disconnectTimerGeneration else {
        return
      }
      Logger.debug(
        type: .peerChannel,
        message: "disconnect timer fired (generation: \(generation))")
      self.disconnectTimerScheduled = false
      guard self.state == .disconnected else {
        return
      }
      self.disconnect(
        error: SoraError.peerChannelError(reason: "peer connection state: disconnected"),
        reason: .peerConnectionStateDisconnected)
    }
  }

  /// 猶予タイマーをキャンセルする。
  ///
  /// `.connecting` / `.connected` / `.failed` への遷移で呼ばれる。
  /// キャンセル後に再び `.disconnected` へ遷移した場合は再開始される。
  private func cancelDisconnectTimer() {
    // タイマーが開始されていない場合は何もしない (ログも出さない)
    guard disconnectTimerScheduled else {
      return
    }
    disconnectTimerScheduled = false
    disconnectTimerGeneration += 1
    Logger.debug(type: .peerChannel, message: "canceled disconnect timer")
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "generated ICE candidate \(candidate)")
    let candidate = ICECandidate(nativeICECandidate: candidate)
    add(iceCandidate: candidate)
    let message = Signaling.candidate(SignalingCandidate(candidate: candidate))
    signalingChannel.send(message: message)
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didRemove candidates: [RTCIceCandidate]
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "removed ICE candidate \(candidates)")
    let candidates = iceCandidates.filter {
      old in
      for candidate in candidates {
        let remove = ICECandidate(nativeICECandidate: candidate)
        if old == remove {
          return true
        }
      }
      return false
    }
    for candidate in candidates {
      remove(iceCandidate: candidate)
    }
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {
    let label = dataChannel.label
    Logger.debug(type: .peerChannel, message: "didOpen: label => \(label)")

    let dataChannelSetting: [String: Any]? =
      signalingOfferMessageDataChannels.filter {
        ($0["label"] as? String) == label
      }.first ?? nil
    let compress = dataChannelSetting?["compress"] as? Bool ?? false

    guard let mediaChannel else {
      Logger.warn(type: .peerChannel, message: "mediaChannel is unavailable")
      return
    }

    let dc = DataChannel(
      dataChannel: dataChannel, compress: compress, mediaChannel: mediaChannel,
      peerChannel: self)
    dataChannels[dataChannel.label] = dc

    if label == "rpc" {
      rpcChannel = RPCChannel(dataChannel: dc)
    }
  }
}

extension RTCRtpSender {
  func updateOfferEncodings(_ encodings: [SignalingOffer.Encoding]) {
    Logger.debug(
      type: .peerChannel, message: "update offer encodings for sender => \(senderId)")

    // parameters はアクセスのたびにコピーされてしまうので、すべての parameters をセットし直す
    let newParameters = parameters  // コピーされる
    for oldEncoding in newParameters.encodings {
      Logger.debug(
        type: .peerChannel, message: "update encoding => \(ObjectIdentifier(oldEncoding))")
      for encoding in encodings {
        guard oldEncoding.rid == encoding.rid else {
          continue
        }

        if let rid = encoding.rid {
          Logger.debug(type: .peerChannel, message: "rid => \(rid)")
          oldEncoding.rid = rid
        }

        Logger.debug(type: .peerChannel, message: "active => \(encoding.active)")
        oldEncoding.isActive = encoding.active
        Logger.debug(type: .peerChannel, message: "old active => \(oldEncoding.isActive)")

        if let value = encoding.maxFramerate {
          Logger.debug(type: .peerChannel, message: "maxFramerate:  \(value)")
          oldEncoding.maxFramerate = NSNumber(value: value)
        }

        if let value = encoding.maxBitrate {
          Logger.debug(type: .peerChannel, message: "maxBitrate: \(value)")
          oldEncoding.maxBitrateBps = NSNumber(value: value)
        }

        if let value = encoding.scaleResolutionDownBy {
          Logger.debug(type: .peerChannel, message: "scaleResolutionDownBy: \(value)")
          oldEncoding.scaleResolutionDownBy = NSNumber(value: value)
        }

        if let value = encoding.scaleResolutionDownTo {
          Logger.debug(
            type: .peerChannel,
            message: "scaleResolutionDownTo: \(value.maxWidth)x\(value.maxHeight)")
          oldEncoding.scaleResolutionDownTo = value
        }

        if let value = encoding.scalabilityMode {
          Logger.debug(type: .peerChannel, message: "scalabilityMode: \(value)")
          oldEncoding.scalabilityMode = value
        }

        if let value = encoding.networkPriority {
          Logger.debug(type: .peerChannel, message: "networkPriority: \(value)")
          oldEncoding.networkPriority = value
        }

        break
      }
    }

    parameters = newParameters
  }
}

// MARK: -

/// type: disconnect の reason を判断するのに必要な情報を保持します。
enum DisconnectReason: String {
  case user
  case signalingFailure
  case internalError
  case peerConnectionStateFailed
  case peerConnectionStateDisconnected
  case webSocket
  case dataChannelClosed
  case noError
  case unknown

  var description: String {
    rawValue
  }
}
