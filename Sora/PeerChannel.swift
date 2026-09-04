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

  /// DataChannel の bufferedAmount 変更時に呼ばれるクロージャー
  var onDataChannelBufferedAmount: ((String, UInt64) -> Void)?

  /// 初期化します。
  public init() {}
}

/// カメラ停止待ちの間、PeerChannel と切断引数を保持する Sendable な内部コンテキスト
private final class PeerChannelDisconnectCompletionContext: @unchecked Sendable {
  let peerChannel: PeerChannel
  let error: Error?
  let reason: DisconnectReason

  init(peerChannel: PeerChannel, error: Error?, reason: DisconnectReason) {
    self.peerChannel = peerChannel
    self.error = error
    self.reason = reason
  }
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

    // connect() が初期ロックを取得してから signalingChannel.connect() の開始を
    // 確定するまでの区間を示す。区間中の切断要求は、開始処理側で受け取る。
    private var isStartingConnection: Bool = false

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
      } else if isStartingConnection {
        // signaling の開始可否を確定する前の切断要求は保存する。
        // startConnection が開始前に検出した場合は signaling を開始せずに切断する。
        shouldDisconnect = (true, error, reason)
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

    /// 接続開始用の初期ロックを取得し、signaling 開始前の区間へ入ります。
    @discardableResult
    func beginConnectionStart() -> Bool {
      nsLock.lock()
      guard !isDisconnecting, !isStartingConnection else {
        nsLock.unlock()
        return false
      }
      count += 1
      isStartingConnection = true
      nsLock.unlock()
      return true
    }

    /// signaling 開始と、その直前に到着した切断要求を直列化します。
    ///
    /// beginConnectionStart() の後に呼び出します。開始前に切断要求があれば
    /// operation を実行せず、開始中に切断要求があれば operation の復帰後に切断します。
    func startConnection(_ operation: () -> Void) {
      var shouldStart = false
      var disconnectParams: (Error?, DisconnectReason)?

      nsLock.lock()
      if !isDisconnecting {
        switch shouldDisconnect {
        case (true, let error, let reason):
          if shouldCancelDisconnectTimerBasedDisconnect(reason: reason) {
            shouldDisconnect = (false, nil, .unknown)
            shouldStart = true
          } else {
            count = 0
            isStartingConnection = false
            isDisconnecting = true
            shouldDisconnect = (false, nil, .unknown)
            disconnectParams = (error, reason)
          }
        default:
          shouldStart = true
        }
      }
      nsLock.unlock()

      if let (error, reason) = disconnectParams {
        context?.basicDisconnect(error: error, reason: reason)
        return
      }
      guard shouldStart else {
        return
      }

      operation()

      // operation の実行中にも切断要求が到着し得るため、開始区間を閉じる処理と
      // 保存済み要求の取り出しを同じ排他領域で行う。
      nsLock.lock()
      isStartingConnection = false
      if !isDisconnecting {
        switch shouldDisconnect {
        case (true, let error, let reason):
          if shouldCancelDisconnectTimerBasedDisconnect(reason: reason) {
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
        // waitDisconnect で受理した切断要求は、nativeChannel が先に .closed へ
        // 遷移していても後始末が必要である。二重実行は isDisconnecting が防ぐ。
        context?.basicDisconnect(error: error, reason: reason)
      }
    }

  }

  // MARK: - Properties

  var internalHandlers = PeerChannelInternalHandlers()
  let configuration: Configuration
  let signalingChannel: SignalingChannel
  let nativePeerChannelFactory: NativePeerChannelFactory
  /// SDK と公開 API のカメラ start / stop / restart をプロセス全体で直列化する coordinator
  private let cameraCaptureCoordinator: CameraVideoCaptureCoordinator
  /// redirect で streams を破棄した後も、カメラ停止完了まで保持する所有ストリーム
  private let cameraCaptureOwnership: CameraCaptureOwnership
  /// この接続でカメラと画面共有のどちらを送信するかを、非同期開始より前に予約する coordinator
  private let videoSourceCoordinator: VideoSourceCoordinator

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

  // DataChannel 通知の世代 (トークン)。リダイレクトのたびに +1 し、
  // 旧接続の DataChannel からの遅延通知を無視するために BasicDataChannelDelegate と照合する。
  // disconnectTimerGeneration と同じく nonisolated(unsafe) で扱う (ベストエフォート)。
  // BasicDataChannelDelegate から現在の世代を確認するため internal にしている。
  nonisolated(unsafe) var dataChannelGeneration: Int = 0

  // リダイレクト中フラグ。リダイレクトから新 offer 受信までの窓で、
  // 旧 RTCPeerConnection からの遅延 didOpen 通知を無視するために使用する。
  // この間 nativeChannel は旧 PC のままのため、PC アイデンティティの一致だけでは
  // 旧 PC の通知を防げない。disconnectTimerGeneration と同じく nonisolated(unsafe) で
  // 扱う (ベストエフォート)。Lock.unlock の遅延切断パスからも参照するため internal にしている。
  nonisolated(unsafe) var isRedirecting = false
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

  let lock: Lock

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
    mediaChannel: MediaChannel?,
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared,
    cameraCaptureOwnership: CameraCaptureOwnership = CameraCaptureOwnership(),
    videoSourceCoordinator: VideoSourceCoordinator = VideoSourceCoordinator()
  ) {
    self.signalingChannel = signalingChannel
    self.mediaChannel = mediaChannel
    self.configuration = configuration
    self.nativePeerChannelFactory = nativePeerChannelFactory
    self.cameraCaptureCoordinator = cameraCaptureCoordinator
    self.cameraCaptureOwnership = cameraCaptureOwnership
    self.videoSourceCoordinator = videoSourceCoordinator
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
    guard lock.beginConnectionStart() else {
      handler(SoraError.connectionCancelled)
      return
    }
    // 開始ロックの取得後に設定することで、切断処理との間で onConnect を競合させない。
    // この区間の切断要求は startConnection まで保存される。
    onConnect = handler

    // TODO(zztkm): WrapperVideoEncoderFactory は type: offer メッセージを受け取ったときに設定されるので、ここでの設定は不要かもしれない
    // サイマルキャストを利用する場合は、 RTCPeerConnection の生成前に WrapperVideoEncoderFactory を設定する必要がある
    WrapperVideoEncoderFactory.shared.simulcastEnabled = configuration.simulcastEnabled

    lock.startConnection {
      signalingChannel.connect { [weak self] error in
        guard let weakSelf = self else {
          return
        }

        // 切断後にリダイレクト先の WebSocket が接続成功した場合は connect メッセージを再送しない。
        // (リダイレクト窓 (isRedirecting) では再接続のため再送し、切断済み
        // (isRedirecting == false かつ state == .closed) では再送しない。
        // 再送するとサーバーが offer を返し、新 PC の生成・リークにつながる)
        guard weakSelf.isRedirecting || weakSelf.state != .closed else {
          return
        }

        if let sdp = weakSelf.sdp {
          weakSelf.sendConnectMessage(with: sdp, error: error, redirect: true)
        } else {
          weakSelf.sendConnectMessage(error: error)
        }
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
    Logger.debug(type: .peerChannel, message: "wait to disconnect")
    lock.waitDisconnect(error: error, reason: reason)
  }

  // MARK: - Private methods

  /// 接続完了 callback を 1 回だけ取り出して呼び出します。
  ///
  /// 接続成功 (finishConnecting)、接続失敗 (sendConnectMessage(error:))、
  /// 接続完了後の切断 (basicDisconnect) のどの経路から呼ばれても、
  /// callback は最初の呼び出しで取り出され、以降の呼び出しでは何も実行しない。
  /// (callback 内から同期的に disconnect() された場合でも、二重実行を防ぐための
  /// take-and-clear である。onConnect は呼び出し前に必ず nil へクリアされる)
  ///
  /// テストから呼び出すため internal としている。
  func invokeConnectHandler(_ error: Error?) {
    let connectHandler = onConnect
    onConnect = nil
    if let connectHandler {
      Logger.debug(type: .peerChannel, message: "call connect(handler:)")
      connectHandler(error)
    }
  }

  private func sendConnectMessage(error: Error?) {
    if let error {
      lock.unlock()
      Logger.error(
        type: .peerChannel,
        message: "failed connecting to signaling channel (\(error.localizedDescription))")
      invokeConnectHandler(error)
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
            // callback の引数 sdpError をそのまま終端処理へ渡す。
            // (外側の error を渡すと、関数冒頭の分岐を通過した時点で nil のため
            // エラーが伝播せず、nil の SDP で接続処理が進んでしまう)
            self.sendConnectMessage(with: nil, error: error)
            return
          }
          self.sdp = sdp
          Logger.debug(
            type: .peerChannel,
            message: "did create offer SDP")
          self.sendConnectMessage(with: sdp, error: nil)
        }
    } else {
      sendConnectMessage(with: nil, error: nil)
    }
  }

  private func sendConnectMessage(with sdp: String?, error: Error?, redirect: Bool? = nil) {
    if let error {
      Logger.error(
        type: .peerChannel,
        message: "failed connecting to signaling channel (\(error.localizedDescription))")
      // 元のエラーをそのまま利用者へ伝播させる。
      // (offer SDP 生成エラー等の原因を固定文字列に置き換えると、
      // 利用者が onConnect のエラーから原因を判別できなくなる)
      disconnect(error: error, reason: .signalingFailure)
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
      opusParams: configuration.audioCodec == .opus ? configuration.audioOpusParams : nil,
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
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
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
      if configuration.audioStereoOutputEnabled {
        // ステレオ再生では RemoteIO を利用するため、VPIO 専用の入力初期化を実行しない。
        Logger.debug(
          type: .peerChannel,
          message: "stereo playout enabled, skip initialize audio input")
      } else if configuration.audioDevice == nil {
        initializeAudioInput()
      } else {
        // AVAudioSession の設定はカスタム音声デバイス (DummyAudioDevice.initialize(with:)) が行うためスキップする
        Logger.debug(
          type: .peerChannel,
          message: "custom audio device enabled, skip initialize audio input")
      }
    } else if configuration.audioDevice != nil {
      // 音声トラック自体が生成されないためダミー音声も無効となる
      Logger.warn(
        type: .peerChannel,
        message: "custom audio device enabled but audioEnabled is false, audio is disabled")
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

    guard let reservation = videoSourceCoordinator.beginCamera(stream: stream) else {
      Logger.error(
        type: .peerChannel,
        message: "camera capture cannot start while screen capture is reserved")
      return
    }

    let cameraCaptureCoordinator = cameraCaptureCoordinator
    let cameraCaptureOwnership = cameraCaptureOwnership
    let videoSourceCoordinator = videoSourceCoordinator
    let formatBox = CameraCaptureFormatBox(format: format)
    let senderStream = SenderStreamBox(stream: stream)
    cameraCaptureCoordinator.enqueue {
      guard cameraCaptureCoordinator.isAvailable else {
        _ = videoSourceCoordinator.completeCamera(reservation, active: false)
        Logger.error(
          type: .peerChannel,
          message: "camera capture is quarantined after a cleanup failure")
        return
      }

      // 切断がキュー実行より先に確定した場合は、カメラへ作用しない。
      guard videoSourceCoordinator.isValid(reservation) else {
        return
      }

      if let current = await CameraVideoCapturer.currentForSDK() {
        guard videoSourceCoordinator.isValid(reservation) else {
          return
        }
        guard current.isRunning else {
          _ = videoSourceCoordinator.completeCamera(reservation, active: false)
          cameraCaptureCoordinator.quarantine(capturer: current)
          Logger.error(
            type: .peerChannel,
            message: "current CameraVideoCapturer is not running")
          return
        }
        if current.stream === senderStream.stream {
          if videoSourceCoordinator.completeCamera(reservation, active: true) {
            cameraCaptureOwnership.set(senderStream: senderStream.stream)
          }
          return
        }
        let previousStream = current.stream
        let stopError = await current.stopForSDK()
        if current.isRunning {
          _ = videoSourceCoordinator.completeCamera(reservation, active: false)
          cameraCaptureCoordinator.quarantine(capturer: current)
          Logger.error(
            type: .peerChannel,
            message:
              "CameraVideoCapturer.stop did not stop capture: \(stopError?.localizedDescription ?? "unknown error")"
          )
          return
        }
        cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturer: current)
        if let previousStream {
          cameraCaptureOwnership.clear(ifOwnedBy: previousStream)
          VideoSourceCoordinator.releaseCameraReservations(
            for: previousStream,
            excluding: reservation)
        }
        guard videoSourceCoordinator.isValid(reservation) else {
          return
        }
      }

      guard !capturer.isRunning else {
        _ = videoSourceCoordinator.completeCamera(reservation, active: false)
        cameraCaptureCoordinator.quarantine(capturer: capturer)
        Logger.error(
          type: .peerChannel,
          message: "CameraVideoCapturer is running without being current")
        return
      }

      if let error = await capturer.startForSDK(
        format: formatBox.format,
        frameRate: frameRate,
        senderStream: senderStream)
      {
        if capturer.isRunning {
          _ = videoSourceCoordinator.completeCamera(reservation, active: true)
          cameraCaptureCoordinator.quarantine(capturer: capturer)
        } else {
          _ = videoSourceCoordinator.completeCamera(reservation, active: false)
        }
        Logger.error(
          type: .peerChannel,
          message: "CameraVideoCapturer.start failed: \(error.localizedDescription)")
        return
      }

      // start の完了待ち中に切断された場合は、開始済みのカメラを同じ直列化区間で停止する。
      guard videoSourceCoordinator.completeCamera(reservation, active: true) else {
        let stopError = await capturer.stopForSDK()
        if capturer.isRunning {
          cameraCaptureCoordinator.quarantine(capturer: capturer)
          Logger.error(
            type: .peerChannel,
            message:
              "failed to stop CameraVideoCapturer after cancelled start: \(stopError?.localizedDescription ?? "unknown error")"
          )
          return
        }
        cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturer: capturer)
        return
      }
      cameraCaptureOwnership.set(senderStream: senderStream.stream)
      Logger.debug(
        type: .peerChannel,
        message: "set CameraVideoCapturer to sender stream")
    }
  }

  /// `initializeSenderStream()` にて生成されたリソースを開放するための、対になるメソッドです。
  private func terminateSenderStream() -> Task<Void, Never>? {
    guard configuration.videoEnabled, configuration.cameraSettings.isEnabled else {
      return nil
    }

    let cameraCaptureCoordinator = cameraCaptureCoordinator
    let cameraCaptureOwnership = cameraCaptureOwnership
    let videoSourceCoordinator = videoSourceCoordinator
    return cameraCaptureCoordinator.enqueue {
      guard let senderStream = cameraCaptureOwnership.currentSenderStream() else {
        videoSourceCoordinator.releaseCamera()
        return
      }
      guard let current = await CameraVideoCapturer.currentForSDK() else {
        cameraCaptureOwnership.clear(ifOwnedBy: senderStream)
        videoSourceCoordinator.releaseCamera()
        return
      }
      // 切断対象の送信ストリームを所有する capturer だけを停止する。
      // 別接続がすでに current を取得している場合は、そのカメラへ作用しない。
      guard
        CameraVideoCaptureCoordinator.isOwned(
          currentStream: current.stream,
          by: senderStream)
      else {
        cameraCaptureOwnership.clear(ifOwnedBy: senderStream)
        videoSourceCoordinator.releaseCamera()
        return
      }
      let stopError = await current.stopForSDK()
      if current.isRunning {
        cameraCaptureCoordinator.quarantine(capturer: current)
        Logger.error(
          type: .peerChannel,
          message:
            "failed to stop CameraVideoCapturer: \(stopError?.localizedDescription ?? "unknown error")"
        )
        return
      }
      cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturer: current)
      cameraCaptureOwnership.clear(ifOwnedBy: senderStream)
      videoSourceCoordinator.releaseCamera()
    }
  }

  private func createAnswer(
    isSender: Bool,
    offer: String,
    constraints: RTCMediaConstraints,
    initialOffer: Bool = false,
    mid: [String: String]? = nil,
    generation: Int,
    handler: @escaping (String?, Error?) -> Void
  ) {
    guard let nativeChannel else {
      // handler を呼ばずに return すると、呼び出し元が lock を解放できない (ロック残留)。
      // 明示的な接続失敗として handler を必ず 1 回呼ぶ。
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
      handler(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
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

      // リダイレクト等で接続が切り替わった場合は、以後の SDP パイプライン
      // (initializeSenderStream / updateSenderOfferEncodings / answer / setLocalDescription)
      // を実行せずに破棄する。
      // (チェーンの各ステップは self.nativeChannel を再読取するため、世代照合が
      // 最終クロージャのみだと、旧 offer の SDP・mid・encodings が新 PC に適用される)
      guard generation == self.dataChannelGeneration else {
        handler(nil, nil)
        return
      }

      guard let nativeChannel = self.nativeChannel else {
        // handler を呼ばずに return すると呼び出し元が lock を解放できないため、エラーを渡す
        Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
        handler(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
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

        // リダイレクト等で接続が切り替わった場合は、以後の SDP パイプライン
        // (setLocalDescription) を実行せずに破棄する。
        // (answer 作成中にリダイレクトが発生した場合、以下の再読取で新 PC を取得し、
        // 旧 offer の answer が新 PC に適用されるのを防ぐ)
        guard generation == self.dataChannelGeneration else {
          handler(nil, nil)
          return
        }

        guard let nativeChannel = self.nativeChannel else {
          // handler を呼ばずに return すると呼び出し元が lock を解放できないため、エラーを渡す
          Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
          handler(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
          return
        }

        Logger.debug(type: .peerChannel, message: "did create answer")

        guard let answer else {
          handler(nil, SoraError.peerChannelError(reason: "answer should not be nil"))
          return
        }

        let localAnswer: RTCSessionDescription
        do {
          let sdp =
            self.configuration.audioStereoOutputEnabled
            ? try StereoAudioSDP.enableStereo(in: answer.sdp) : answer.sdp
          localAnswer = RTCSessionDescription(type: answer.type, sdp: sdp)
        } catch {
          handler(nil, error)
          return
        }

        Logger.debug(type: .peerChannel, message: "try setting local description")
        nativeChannel.setLocalDescription(localAnswer) { error in
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
            message: "\(localAnswer.sdpDescription)")
          Logger.debug(
            type: .peerChannel,
            message: "did create answer")
          handler(localAnswer.sdp, nil)
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

    // 受信時点の世代を記録し、非同期処理の完了時に現在の世代と照合する。
    // (リダイレクトで接続が切り替わった場合に、旧接続の answer が新接続に送信されるのを防ぐ)
    let generation = dataChannelGeneration

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
    // リダイレクト中フラグを解除する (新 PC が生成された時点で解除)。
    // リダイレクト窓で state == .closed のため発火をスキップした WebSocket 切断タイマーの
    // フラグもリセットし、新接続でも WebSocket 切断をスケジュールできるようにする
    // (リセットしないと、新接続の signaling ラベル受信後に WebSocket が切断されず
    // サーバーセッションが残留する)
    isRedirecting = false
    webSocketDisconnectScheduled = false
    nativeChannel.setConfiguration(webRTCConfiguration.nativeValue)

    createAnswer(
      isSender: configuration.isSender,
      offer: offer.sdp,
      constraints: webRTCConfiguration.nativeConstraints,
      initialOffer: true,
      mid: offer.mid,
      generation: generation
    ) { sdp, error in
      // リダイレクト等で接続が切り替わった場合は、旧接続の answer を破棄する。
      // (setRemoteDescription 等の非同期処理の完了前にリダイレクトが実行された場合に、
      // 旧 offer の answer が新接続に送信されるのを防ぐ)
      guard generation == self.dataChannelGeneration else {
        Logger.debug(type: .peerChannel, message: "generation changed, skip create answer")
        self.lock.unlock()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create answer (\(error.localizedDescription))")
        self.lock.unlock()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let sdp else {
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let answer = SignalingAnswer(sdp: sdp)
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
    // 受信時点の世代を記録し、非同期処理の完了時に現在の世代と照合する。
    // (リダイレクトで接続が切り替わった場合に、旧接続の update-answer が新接続に
    // 送信されるのを防ぐ。type: update は Sora 2022.1.0 で廃止されたメッセージだが、
    // 他の answer 処理との一貫性のため同様にガードする)
    let generation = dataChannelGeneration
    createAnswer(
      isSender: false,
      offer: offer,
      constraints: webRTCConfiguration.nativeConstraints,
      generation: generation
    ) { answer, error in
      // リダイレクト等で接続が切り替わった場合は、旧接続の update-answer を破棄する。
      guard generation == self.dataChannelGeneration else {
        self.lock.unlock()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create update-answer (\(error.localizedDescription)")
        self.lock.unlock()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created update-answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let message = Signaling.update(SignalingUpdate(sdp: answer))
      self.signalingChannel.send(message: message)

      if self.configuration.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      self.internalHandlers.onUpdate?(answer)

      self.lock.unlock()
    }
  }

  private func createAndSendReAnswer(forReOffer reOffer: String) {
    Logger.debug(type: .peerChannel, message: "create and send re-answer")

    // 受信時点の世代を記録し、非同期処理の完了時に現在の世代と照合する。
    // (リダイレクトで接続が切り替わった場合に、旧接続の re-answer が新接続に
    // 適用されたり、リダイレクトを中断したりするのを防ぐ)
    let generation = dataChannelGeneration

    createAnswer(
      isSender: false,
      offer: reOffer,
      constraints: webRTCConfiguration.nativeConstraints,
      generation: generation
    ) { answer, error in
      // 2025.1.1 までは lock() 呼び出しをこのクロージャーの外 = createAnswer の直前で行っていたが、
      // この場合、 SDP 再ハンドシェイク時に SDP を local description に設定する際に EXC_BAD_ACCESS (不正なメモリアクセス) が発生し、
      // アプリがクラッシュしてしまうことがあったが、lock() の呼び出しをクロージャー内にすることで、不正なメモリアクセスを防ぐことができるように
      // なったため、ここに移動させた (createAndSendReAnswerOverDataChannel も同様の理由で lock() の位置を移動)
      guard self.lock.lock() else {
        Logger.debug(type: .peerChannel, message: "already disconnecting, skip re-answer")
        return
      }
      // リダイレクト等で接続が切り替わった場合は、旧接続の re-answer を破棄する。
      // (setRemoteDescription 等の非同期処理の完了前にリダイレクトが実行された場合に、
      // 旧 offer の answer が新接続に適用されるのを防ぐ)
      guard generation == self.dataChannelGeneration else {
        Logger.debug(type: .peerChannel, message: "generation changed, skip re-answer")
        self.lock.unlock()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create re-answer (\(error.localizedDescription)")
        self.lock.unlock()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created re-answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let message = Signaling.reAnswer(SignalingReAnswer(sdp: answer))
      self.signalingChannel.send(message: message)

      if self.configuration.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      self.internalHandlers.onUpdate?(answer)

      self.lock.unlock()
    }
  }

  private func createAndSendReAnswerOverDataChannel(forReOffer reOffer: String) {
    Logger.debug(type: .peerChannel, message: "create and send re-answer over DataChannel")

    guard let dataChannel = dataChannels["signaling"] else {
      Logger.debug(type: .peerChannel, message: "DataChannel for label: signaling is unavailable")
      return
    }

    // 受信時点の世代を記録し、非同期処理の完了時に現在の世代と照合する。
    // (リダイレクトで接続が切り替わった場合に、旧接続の re-answer が新接続に
    // 適用されたり、旧 signaling DataChannel への送信失敗でリダイレクトを中断したり
    // するのを防ぐ)
    let generation = dataChannelGeneration

    createAnswer(
      isSender: false,
      offer: reOffer,
      constraints: webRTCConfiguration.nativeConstraints,
      generation: generation
    ) { answer, error in
      // NOTE: PeerChannel のインスタンスをキャプチャすることを明示的に指定する必要があるため、self が必要
      guard self.lock.lock() else {
        Logger.debug(
          type: .peerChannel, message: "already disconnecting, skip re-answer over DataChannel")
        return
      }
      // リダイレクト等で接続が切り替わった場合は、旧接続の re-answer を破棄する。
      // (setRemoteDescription 等の非同期処理の完了前にリダイレクトが実行された場合に、
      // 旧 offer の answer が新接続に適用されるのを防ぐ)
      guard generation == self.dataChannelGeneration else {
        Logger.debug(
          type: .peerChannel, message: "generation changed, skip re-answer over DataChannel")
        self.lock.unlock()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create re-answer: error => (\(error.localizedDescription)")
        self.lock.unlock()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.lock.unlock()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created re-answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let reAnswer = Signaling.reAnswer(SignalingReAnswer(sdp: answer))

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
      self.internalHandlers.onUpdate?(answer)

      self.lock.unlock()
    }
  }

  private func handleSignalingOverWebSocket(_ signaling: Signaling) {
    Logger.debug(
      type: .mediaStream,
      message: "handle signaling over WebSocket => \(signaling.typeName())")
    switch signaling {
    case .offer(let offer):
      // 切断後にキューから遅れて配送された offer は、接続識別子の更新や
      // RTCPeerConnection の生成を行う前に破棄する。
      guard lock.lock() else {
        Logger.debug(type: .peerChannel, message: "already disconnecting, skip offer")
        return
      }
      signalingChannel.setConnectedUrl()

      clientId = offer.clientId
      bundleId = offer.bundleId
      connectionId = offer.connectionId
      if let dataChannels = offer.dataChannels {
        signalingChannel.dataChannelSignaling = true
        signalingOfferMessageDataChannels = dataChannels
      }
      // リダイレクト等で offer が再送された場合に備えて
      // DataChannel の OPEN 追跡状態をリセットする。
      // data_channels の有無に関わらずリセットする
      // (data_channels なしの offer で前接続の追跡状態が残留すると、
      // 新接続の onDataChannelOpened / onDataChannel が抑止されるため)
      mediaChannel?.resetDataChannelNotificationState(
        messagingLabels: MediaChannel.messagingLabels(from: offer.dataChannels ?? []))

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
      Logger.debug(
        type: .peerChannel,
        message: "switched: switchedToDataChannel => true (generation => \(dataChannelGeneration))")
    case .redirect(let redirect):
      // リダイレクト時の旧接続からの遅延通知の遮断方針:
      // - DataChannel delegate (dataChannelDidChangeState / didReceiveMessageWith):
      //   生成時点の世代と現在の世代の照合で無視
      // - PC delegate (didOpen / didChange): isCurrentPeerConnection
      //   (リダイレクト窓は isRedirecting、新 PC 生成後は PC アイデンティティ)
      // - 切断 (disconnect / Lock.unlock): isRedirecting 中は切断処理を続行
      // - WS 接続 (SignalingChannel): 切断後は state == .disconnected で受け入れ拒否
      //
      // 旧 PC を明示的にクローズする (遅延 OPEN 通知による OPEN 追跡状態の汚染防止と
      // リソースリーク解消)。先に世代を進めてから close() し、close に伴う
      // 旧 DataChannel の .closed 通知を無視させる。
      // 旧接続で開始された切断検出の猶予タイマーも無効化する
      // (旧接続の .disconnected を契機に開始されたタイマーがリダイレクト後も発火し、
      // 新接続を誤切断するのを防ぐ。また、disconnectTimerScheduled が true のまま
      // 残留すると新接続のタイマー開始が抑止される)
      dataChannelGeneration += 1
      // 旧 transport の論理的な無効化。redirect 受理済みのため、
      // 以後 sendMessage / RPC / stats が旧 DataChannel / 旧 PeerConnection を参照しない。
      // 送信経路と RPC は dataChannelGeneration と rpcChannel の nil で旧接続を判別する。
      Logger.debug(
        type: .peerChannel,
        message: "redirect: invalidating old transport (generation => \(dataChannelGeneration))")
      switchedToDataChannel = false
      // 旧 DataChannel の参照を解放し、旧 DataChannel への送信を防ぐ。
      // (take-and-clear 相当。dataChannels は新しい offer 受信時に再構築される)
      dataChannels.removeAll()
      if let rpcChannel {
        rpcChannel.invalidate(
          reason: SoraError.rpcDataChannelClosed(reason: "redirect"))
        self.rpcChannel = nil
        Logger.debug(type: .peerChannel, message: "redirect: invalidated rpcChannel")
      }
      // 旧 MediaStream を終端して解放する。
      // (旧 PeerConnection が送出する映像・音声フレームが新しい接続へ混入するのを防ぐ)
      for stream in streams {
        stream.terminate()
      }
      if !streams.isEmpty {
        Logger.debug(
          type: .peerChannel,
          message: "redirect: terminated \(streams.count) streams")
      }
      streams.removeAll()
      isRedirecting = true
      cancelDisconnectTimer()
      nativeChannel?.close()
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

    // (callback 内から同期的に disconnect() されても二重実行されない)
    invokeConnectHandler(nil)
    lock.unlock()
  }

  private func basicDisconnect(error: Error?, reason: DisconnectReason) {
    // 切断によりリダイレクトを中止する。
    // (リダイレクト窓で切断が実行された場合、以降は通常の切断状態に戻す)
    isRedirecting = false

    // カメラ開始の非同期完了より先に切断を確定し、遅延した開始を自己停止させる。
    // MediaChannel を経由しない internal テストや利用経路でも同じ不変条件を維持する。
    videoSourceCoordinator.revoke()

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

    let cameraCleanupTask = configuration.isSender ? terminateSenderStream() : nil

    // カスタム音声デバイス (ダミー音声等) の停止。terminateSenderStream は送信側のカメラ停止のみを行い、
    // 音声デバイスの停止は行わないため、recvonly を含む全ロールで実行する。
    // nativeChannel?.close() より前に実行し、ADM スレッドが生存している状態で
    // terminateDevice の dispatchSync を実行する
    if let audioDevice = nativePeerChannelFactory.audioDevice {
      audioDevice.terminateDevice()
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

    // 利用者が公開 native を先に close した場合も、残りの cleanup は必ず行う。
    // すでに closed の PeerConnection に対する二度目の close だけを省略する。
    if nativeChannel?.connectionState != .closed {
      nativeChannel?.close()
    }
    // 実際の PeerConnection を閉じた後、利用者の切断 callback より前に要求を解放する。
    // Lock が切断を遅延した場合も、AudioUnit の利用中に解放されない。
    nativePeerChannelFactory.releaseAudioSessionRequirement()

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

    guard let cameraCleanupTask else {
      finishBasicDisconnect(error: error, reason: reason)
      return
    }

    // 公開切断 callback より前に、この接続が所有する通常カメラの停止完了を待つ。
    // context が PeerChannel を保持するため、非同期 cleanup 中に解放されない。
    let context = PeerChannelDisconnectCompletionContext(
      peerChannel: self,
      error: error,
      reason: reason)
    Task { @Sendable in
      await cameraCleanupTask.value
      context.peerChannel.finishBasicDisconnect(
        error: context.error,
        reason: context.reason)
    }
  }

  /// 非同期カメラ cleanup の完了後に、切断通知と接続ハンドラーを終端します。
  private func finishBasicDisconnect(error: Error?, reason: DisconnectReason) {
    Logger.debug(type: .peerChannel, message: "call onDisconnect")
    internalHandlers.onDisconnect?(error, reason)

    // (接続失敗 callback 内から切断処理へ再入しても二重実行されない)
    invokeConnectHandler(error)

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

  /// 通知元の RTCPeerConnection が現在の接続のものであるかを判定する。
  /// リダイレクトから新 PC 生成までの窓では nativeChannel が旧 PC のままのため、
  /// PC アイデンティティの一致だけでは旧 PC の遅延通知を防げない。
  /// そのため、リダイレクト中は isRedirecting、新 PC 生成後は PC アイデンティティで判定する。
  /// (本ヘルパーは PC delegate (didOpen / didChange / didGenerateCandidate) 専用。
  /// DataChannel delegate は世代照合 (generation == dataChannelGeneration) で別途ガードするため、
  /// DataChannel 側の通知にこのヘルパーを使わないこと)
  private func isCurrentPeerConnection(_ nativePeerConnection: RTCPeerConnection) -> Bool {
    !isRedirecting && nativePeerConnection === nativeChannel
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    // リダイレクト中または旧 RTCPeerConnection からの状態通知は無視する。
    // 旧 PC を close() した後に届く遅延 .failed / .disconnected 通知が、
    // 新接続の状態として処理されるとリダイレクトが失敗扱いになるため。
    guard isCurrentPeerConnection(peerConnection) else {
      return
    }
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
    case .closed:
      // 公開 native が SDK より先に close された場合も、stream、signaling、
      // AudioSession lease を残さない。SDK 自身の close による再入は Lock が防ぐ。
      disconnect(error: nil, reason: .noError)
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
    // リダイレクト中または旧 RTCPeerConnection からの ICE candidate は無視する。
    // 旧 PC を close() した後に届く遅延 candidate が新接続のシグナリングに
    // 送信されるのを防ぐ。
    guard isCurrentPeerConnection(nativePeerConnection) else {
      return
    }
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
    // リダイレクト中または旧 RTCPeerConnection からの didOpen 通知は無視する。
    // 旧 PC を close() した後に届く遅延 didOpen 通知が新接続の状態を汚染するため。
    guard isCurrentPeerConnection(nativePeerConnection) else {
      return
    }

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
      peerChannel: self, generation: dataChannelGeneration)
    dataChannels[dataChannel.label] = dc

    // rpc ラベルは防御的通知より先に rpcChannel を設定する。
    // (onDataChannelOpened の発火時点で rpc 呼び出しが可能であることを保証するため)
    if label == "rpc" {
      rpcChannel = RPCChannel(dataChannel: dc)
      Logger.debug(
        type: .peerChannel,
        message: "didOpen: created rpcChannel (generation => \(dataChannelGeneration))")
    }

    // libwebrtc の RTCDataChannelDelegate は登録時に現在の state を即時通知しないため、
    // 登録時点で既に OPEN の場合に通知が失われる。そのため防御的に通知する。
    // dataChannels への登録後に通知することで、通知を受けた側が sendMessage を利用できる。
    // MediaChannel 側の openedDataChannelLabels で重複通知は防止される。
    if dataChannel.readyState == .open {
      internalHandlers.onOpenDataChannel?(dataChannel.label)
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
