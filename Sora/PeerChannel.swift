import Foundation
import Security
import WebRTC

/// :nodoc:
extension RTCRtpParameters {
  override open var description: String {
    // RTCRtpParameters は他にもプロパティーを持つが、ここでは SDK で利用している値のみ出力する
    // encodings もここに追加したい
    //
    // degradationPreference が未設定 (nil) の場合の表現は formatter が持つため、ここでは
    // optional のまま渡す
    let degradationPreference = WebRTCEnumDescription.degradationPreference(
      rawValue: self.degradationPreference?.intValue)
    return "\(transactionId) \(degradationPreference)"
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

/// `createAnswer` の完了 handler を複数の非同期境界から参照するための、用途限定の内部ラッパーです。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する handler は `init` で確定した `let` であること
/// - 変更前から handler を渡していた WebRTC の callback を包み直すだけで、配送先・通知順序・
///   呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持するのは handler の closure だけで、`PeerChannel` / `DataChannel` /
///   `ConnectionTask` などの SDK 内部の参照型を新たに保持しないこと
///
/// 使用契約は「`createAnswer` の各 return 経路で高々 1 回呼ばれる」です。実行単位は `createAnswer`
/// の呼び出し 1 回で、そこで作られる box は 1 つです。これを `createAnswer` 本体の同期経路と、
/// `setRemoteDescription` / `answer(for:)` / `setLocalDescription` の 3 つの非同期完了 closure が
/// 共有します。成功経路は return する時点では box を呼ばず、handler の呼び出しを native の完了
/// block に委ねます。native の完了 block に委ねた経路を除き、return する経路では必ず 1 回呼びます。
/// native の完了が返らない場合は呼ばれず 0 回のままです。
/// `self` が解放済みの場合は `self` を参照できないため、`setRemoteDescription` 完了 closure の
/// `guard let self else` の else 節で handler を 1 回呼びます。この節は `self` が nil のときだけ通り、
/// `guard let self` を通過した後の呼び出しは `self` が non-nil のときだけ通るため、1 回の closure
/// 実行で handler が 2 回呼ばれることはありません (型では強制されません)。
/// `Sendable` にするのはこの入れ物だけで、handler と
/// その捕捉状態を `Sendable` にはしません。捕捉状態の所有と同期は、呼び出しスレッドを
/// 保証しない既存の挙動の下で利用者の責務です。実行スレッドの同一性・直列性も契約にしません。
private final class CreateAnswerHandlerBox: @unchecked Sendable {
  private let handler: (String?, (any Error)?) -> Void

  init(_ handler: @escaping (String?, (any Error)?) -> Void) {
    self.handler = handler
  }

  func callAsFunction(_ sdp: String?, _ error: (any Error)?) {
    handler(sdp, error)
  }
}

/// `PeerChannel` の transport 状態 (`nativeChannel` / `streams` / `offerEncodings`) を
/// 単一の NSLock で保護する storage。
///
/// これら 3 つは変更前は lock 保護のない `var` であり、WebRTC の callback と
/// `DispatchQueue` の block から読まれていた。読み書きを 1 つの排他へ移すことで、
/// `PeerChannel` の完了 closure が参照する状態アクセスをこの storage に閉じる。
///
/// `@unchecked Sendable` を認める根拠は、可変状態をすべてこの `lock` 配下でだけ
/// 読み書きすることである。保持する `RTCPeerConnection` / `MediaStream` /
/// `SignalingOffer.Encoding` のオブジェクト状態の不変性は主張しない。参照の取り出しと、
/// 取り出した参照に対する `connectionState` や `close()`、`terminate()` の呼び出しは
/// 別の区間で行う (`lock` を保持したまま libwebrtc を呼ばない)。
///
/// lock 順序は、`ConnectionStateOwner` の排他 / `connectHandlerLock` →
/// この storage の一方向だけを許す。この storage を保持したまま
/// `ConnectionStateOwner` の排他や `connectHandlerLock`、`webRTCConfigurationLock` を
/// 取らないこと (`connectHandlerLock` とこの storage は入れ子にしない)。
final class PeerChannelTransportStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var storedNativeChannel: RTCPeerConnection?
  private var storedStreams: [MediaStream] = []
  private var storedOfferEncodings: [SignalingOffer.Encoding]?

  /// 現在の `RTCPeerConnection` の参照を返す。参照の読み出しだけを排他し、
  /// 返した参照に対する呼び出しは呼び出し側が排他区間の外で行う。
  var native: RTCPeerConnection? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedNativeChannel
    }
    set {
      lock.lock()
      // 旧参照の解放 (libwebrtc の deinit) を lock 区間の外で行う。
      // lock 区間の中で解放すると、外部コードが区間内で走り得る。
      let previous = storedNativeChannel
      storedNativeChannel = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  /// 現在の `MediaStream` の配列の写しを返す。
  var streams: [MediaStream] {
    lock.lock()
    defer { lock.unlock() }
    return storedStreams
  }

  /// 現在の offer encodings を返す。
  var offerEncodings: [SignalingOffer.Encoding]? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedOfferEncodings
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedOfferEncodings = newValue
    }
  }

  /// `MediaStream` を追加する。読み出しと書き戻しの間に他のスレッドの更新が
  /// 入らないよう、1 回の `lock` 区間で行う。
  func append(stream: MediaStream) {
    lock.lock()
    defer { lock.unlock() }
    storedStreams.append(stream)
  }

  /// 指定した streamId の `MediaStream` をすべて取り除き、取り除いた要素を返す。
  ///
  /// 読み出しと削除を 1 回の `lock` 区間で行う。返した要素の解放は呼び出し側の
  /// lock 区間の外で行う。
  @discardableResult
  func remove(streamId: String) -> [MediaStream] {
    lock.lock()
    defer { lock.unlock() }
    var removed: [MediaStream] = []
    storedStreams.removeAll { stream in
      guard stream.streamId == streamId else {
        return false
      }
      removed.append(stream)
      return true
    }
    return removed
  }

  /// すべての `MediaStream` を取り除く。1 回の `lock` 区間で行い、
  /// 取り除いた要素の解放は lock 区間の外で行う。
  func removeAllStreams() {
    lock.lock()
    let removed = storedStreams
    storedStreams.removeAll()
    lock.unlock()
    withExtendedLifetime(removed) {}
  }
}

/// `PeerChannel` の完了 closure が `PeerChannel` のメソッドを呼ぶための、
/// 用途限定の参照保持 box。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことである。
/// - 可変状態を持たず、保持する参照は `init` でのみ代入する `weak var value` だけであること
///   (`weak` は runtime が参照の load / store を原子的に扱い、代入後に値を書き換えない)
/// - 変更前から `PeerChannel` を捕捉していた WebRTC の callback と `DispatchQueue` の
///   block を包み直すだけで、配送先・通知順序・呼び出し回数を変えず、別系統の境界へ
///   新たに渡さないこと
/// - 保持する `PeerChannel` に対して closure が行う状態アクセスが、既存または本変更で
///   確立した排他 (`ConnectionStateOwner` の直列 queue、`connectHandlerLock`、
///   `ConnectionSnapshotStorage` / `PeerChannelTransportStorage` の NSLock) と
///   `init` で確定した不変値 (`signalingChannel` / `snapshot` などの `let`) に閉じること
///
/// この `@unchecked Sendable` は「この box を使う経路で closure が行う状態アクセスが
/// 安全である」という限定した主張であり、`PeerChannel` 全体が thread-safe であることも、
/// `PeerChannel` に `Sendable` 準拠を追加することも主張しない。
/// 参照する状態の所有と同期が `PeerChannel` 側の責務であることは変更前と同じである。
///
/// `value` を弱参照にするのは、変更前の `[weak self]` と同じく「`PeerChannel` が解放済みなら
/// 何もしない」挙動を維持するためである。強参照にすると、WebRTC が完了 closure を保持し、
/// その closure が box を、box が `PeerChannel` を保持する経路で `PeerChannel` が
/// 解放されなくなる。
///
/// box は `PeerChannel` 以外の参照を保持しない。`transportStorage` を box に持たせると、
/// `box → transportStorage → RTCPeerConnection → 保留中の完了 block → box` の循環ができ、
/// この循環は完了 block が 1 回実行されるまで続く。完了 block は WebRTC 側が保持するため、
/// `PeerChannel` を解放しても `RTCPeerConnection` の生存が完了まで延びる点が
/// 変更前の `[weak self]` との差になる。closure からは `self.transportStorage` で読めるため、
/// box には持たせない。
private final class WeakPeerChannelBox: @unchecked Sendable {
  /// 捕捉対象の `PeerChannel`。解放済みの場合は nil になる。
  weak var value: PeerChannel?

  init(value: PeerChannel) {
    self.value = value
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

  // MARK: - Properties

  var internalHandlers = PeerChannelInternalHandlers()

  /// 接続開始時に写し取った利用者の設定
  ///
  /// 利用者所有の可変値を参照しないための値で、offer 受信でも更新されない。
  /// 接続所有の WebRTC 設定は `webRTCConfiguration` (`currentWebRTCConfiguration()`) を使う。
  let snapshot: ConnectionConfigurationSnapshot
  let signalingChannel: SignalingChannel
  let nativePeerChannelFactory: NativePeerChannelFactory
  /// SDK と公開 API のカメラ start / stop / restart をプロセス全体で直列化する coordinator
  private let cameraCaptureCoordinator: CameraVideoCaptureCoordinator
  /// redirect で streams を破棄した後も、カメラ停止完了まで保持する所有ストリーム
  private let cameraCaptureOwnership: CameraCaptureOwnership
  /// この接続でカメラと画面共有のどちらを送信するかを、非同期開始より前に予約する coordinator
  private let videoSourceCoordinator: VideoSourceCoordinator

  /// 現在の `MediaStream` の配列
  ///
  /// 追加・削除は `transportStorage` の操作経由で行うため、getter だけを公開する。
  var streams: [MediaStream] {
    transportStorage.streams
  }
  private(set) var iceCandidates: [ICECandidate] = []

  var dataChannels: [String: DataChannel] = [:]
  var switchedToDataChannel: Bool = false
  var signalingOfferMessageDataChannels: [[String: Any]] = []
  var rpcChannel: RPCChannel?

  weak var mediaChannel: MediaChannel?

  // MARK: - 接続状態フラグ

  // PeerChannel の接続状態フラグ 5 つと接続ライフサイクルの排他が扱う接続試行状態
  // (進行中の非同期処理数 / 切断開始フラグ / 接続開始区間フラグ / 遅延する切断要求)、
  // および音声入力の初期化済みフラグは、
  // 単一所有者である ConnectionStateOwner が同じ直列 queue で管理する。
  // これにより nonisolated(unsafe) によるベストエフォートの同期と、
  // 接続状態とは別に存在していた lock を廃止する。
  // (MediaChannel の接続ライフサイクルは connectionLifecycleLock (NSLock ベースの直列化)
  // が担うため、ここで扱うのは PeerChannel 自身の状態のみである)

  /// 接続状態フラグの単一所有者
  private let connectionStateOwner: ConnectionStateOwner

  /// 接続状態フラグの snapshot を保持する storage
  private let connectionStateSnapshotStorage = ConnectionSnapshotStorage()

  /// `nativeChannel` / `streams` / `offerEncodings` を保護する storage
  ///
  /// internal にしているのは、`MediaChannel.getStats` の完了 closure が `MediaChannel` を
  /// 捕捉せずに現在の `nativeChannel` の同一性を判定するため、この storage の参照を
  /// `MediaChannelGetStatsContext` へ渡す必要があるためである。
  let transportStorage = PeerChannelTransportStorage()

  /// 接続状態のイベントを投げる
  private func handleConnectionEvent(_ event: ConnectionEvent) {
    connectionStateOwner.handle(event)
  }

  /// 現在の transport 世代
  var dataChannelGeneration: Int {
    connectionStateSnapshotStorage.current().transportEpoch
  }

  /// redirect 中フラグ
  var isRedirecting: Bool {
    connectionStateSnapshotStorage.current().isRedirecting
  }

  /// WebSocket の切断スケジュール済みフラグ
  var webSocketDisconnectScheduled: Bool {
    connectionStateSnapshotStorage.current().webSocketDisconnectScheduled
  }

  /// 猶予タイマーの開始済みフラグ
  var disconnectTimerScheduled: Bool {
    connectionStateSnapshotStorage.current().disconnectTimerScheduled
  }

  /// 猶予タイマーの世代
  var disconnectTimerGeneration: Int {
    connectionStateSnapshotStorage.current().disconnectTimerGeneration
  }

  var state: PeerChannelConnectionState {
    // 接続試行中の判定は、ここで 1 度だけ読んだ onConnect の有無で行う。
    // 分岐ごとに読み直すと、読み出しの間に接続が終端した場合に判定がぶれる。
    // (onConnect は connectHandlerLock、nativeChannel は transportStorage の排他で
    //  読み、両者を入れ子にしない)
    let hasConnectHandler = onConnect != nil
    // nativeChannel の参照は storage から 1 度だけ取り出す。connectionState の読みは
    // storage の lock を解放してから行う。
    if let nativeChannel = transportStorage.native {
      let state = PeerChannelConnectionState(nativeChannel.connectionState)
      // connect() 開始後から finishConnecting() / basicDisconnect() までは onConnect が保持される。
      // そのため、 RTCPeerConnection を生成済みでも connectionState が .new の間は
      // 接続試行中として扱う。
      if hasConnectHandler, state == .new {
        return .connecting
      }
      return state
    }

    if hasConnectHandler {
      // offer.configuration を受け取るまで RTCPeerConnection を生成しないため、
      // nativeChannel が未生成でも、onConnect が保持されていれば接続試行中として扱う。
      return .connecting
    }

    return PeerChannelConnectionState(RTCPeerConnectionState.new)
  }

  /// 現在の `RTCPeerConnection`。
  ///
  /// 読み書きは `transportStorage` の `NSLock` で排他する。参照の取り出しと、
  /// 取り出した参照に対する `connectionState` などの呼び出しは別の区間で行う。
  var nativeChannel: RTCPeerConnection? {
    get {
      transportStorage.native
    }
    set {
      transportStorage.native = newValue
    }
  }

  /// 接続所有の WebRTC 設定
  ///
  /// 利用者由来 snapshot を初期値とし、offer 受信時にサーバー値で更新します。
  /// `snapshot.webRTCConfiguration` (利用者由来で、offer 受信でも更新されない) と
  /// 取り違えないこと。読み書きは webRTCConfigurationLock 配下で行います。
  private var webRTCConfiguration: WebRTCConfigurationSnapshot

  /// webRTCConfiguration の読み書きを保護する lock
  ///
  /// lock は値を読み書きする短い区間だけ保持し、libwebrtc の非同期 callback や
  /// await、利用者 handler の呼び出しをまたいで保持しません。
  private let webRTCConfigurationLock = NSLock()

  /// 接続所有の WebRTC 設定の現在値を返します。
  func currentWebRTCConfiguration() -> WebRTCConfigurationSnapshot {
    webRTCConfigurationLock.lock()
    defer { webRTCConfigurationLock.unlock() }
    return webRTCConfiguration
  }

  /// 接続所有の WebRTC 設定を更新します。
  func updateWebRTCConfiguration(_ configuration: WebRTCConfigurationSnapshot) {
    webRTCConfigurationLock.lock()
    defer { webRTCConfigurationLock.unlock() }
    webRTCConfiguration = configuration
  }

  var clientId: String?
  var bundleId: String?
  var connectionId: String?

  /// 接続完了 callback の読み書きを保護する lock
  ///
  /// `onConnect` の保護に接続状態 owner の排他を再利用しない。`state` は
  /// 接続状態 owner の排他を保持したまま `ConnectionStateOwner` の判定 closure から
  /// 呼ばれ、そこから `onConnect` を読む。この経路は `requestDisconnect` /
  /// `prepareSignalingStart` / `finishSignalingStart` / `endAsyncOperation` から到達する。
  /// 接続状態 owner の排他は同じ直列 queue へ再入できないため、これを再利用すると
  /// deadlock する。
  ///
  /// lock 順序は「接続状態 owner の排他 → `connectHandlerLock`」の一方向とする。
  /// `connectHandlerLock` を保持したまま接続状態 owner の排他を取る経路を作らないこと。
  private let connectHandlerLock = NSLock()

  /// 接続完了 callback の実体
  ///
  /// 読み書きはすべて `connectHandlerLock` で行う。外部からは `onConnect` を経由する。
  private var storedOnConnect: ((Error?) -> Void)?

  /// 接続完了 callback
  ///
  /// 接続の開始 (`connect`)、終端 (`invokeConnectHandler` の取り出しとクリア)、
  /// 接続試行中の判定 (`state` / `ConnectionStateOwner.requestDisconnect`) のすべてが
  /// `connectHandlerLock` を通る。利用者 callback 自身の呼び出しは排他区間の外で行う。
  var onConnect: ((Error?) -> Void)? {
    get {
      connectHandlerLock.lock()
      defer { connectHandlerLock.unlock() }
      return storedOnConnect
    }
    set {
      connectHandlerLock.lock()
      // 旧値は lock を解放してから解放する。lock 区間の中で旧 closure を解放すると、
      // closure が捕捉しているオブジェクトの deinit (= 外部コード) が区間内で走り得る。
      let previous = storedOnConnect
      storedOnConnect = newValue
      connectHandlerLock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  // `isAudioInputInitialized` は `ConnectionStateOwner` が単一所有する。読みは
  // `connectionStateOwner.isAudioInputInitialized()`、書きは `.audioInputInitialized`
  // イベントで行う。`offerEncodings` は `transportStorage` が保護する。

  private var connectedAtLeastOnce: Bool = false

  /// DataChannel シグナリングで type: close メッセージを受信したときにメッセージ内容を保存するための変数
  private var dataChannelSignalingClose: (code: Int, reason: String)?

  // type: redirect のために SDP を保存しておく
  // 値が設定されている場合2回目の type: connect メッセージ送信とみなし、 redirect 中であると判断する
  private var sdp: String?

  // MARK: - Public methods

  init(
    snapshot: ConnectionConfigurationSnapshot, signalingChannel: SignalingChannel,
    nativePeerChannelFactory: NativePeerChannelFactory,
    mediaChannel: MediaChannel?,
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared,
    cameraCaptureOwnership: CameraCaptureOwnership = CameraCaptureOwnership(),
    videoSourceCoordinator: VideoSourceCoordinator = VideoSourceCoordinator()
  ) {
    self.signalingChannel = signalingChannel
    self.mediaChannel = mediaChannel
    self.snapshot = snapshot
    self.nativePeerChannelFactory = nativePeerChannelFactory
    self.cameraCaptureCoordinator = cameraCaptureCoordinator
    self.cameraCaptureOwnership = cameraCaptureOwnership
    self.videoSourceCoordinator = videoSourceCoordinator
    webRTCConfiguration = snapshot.webRTCConfiguration

    connectionStateOwner = ConnectionStateOwner(
      snapshotStorage: connectionStateSnapshotStorage)
    super.init()

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
    // ここで取得する接続開始の初期ロックは、接続が終端するまで
    // endAsyncOperation() (finishConnecting() または sendConnectMessage(error:)) で解放される。
    // 解放されない限り切断要求は遅延されたままになる。
    guard beginConnectionStart() else {
      handler(SoraError.connectionCancelled)
      return
    }
    // 開始ロックの取得後に設定することで、切断処理との間で onConnect の有無を確定させる。
    // この区間の切断要求は startConnection まで保存される。
    // (この時点で接続状態 owner の排他は解放済みであり、代入自体は connectHandlerLock で保護される)
    onConnect = handler

    // TODO(zztkm): WrapperVideoEncoderFactory は type: offer メッセージを受け取ったときに設定されるので、ここでの設定は不要かもしれない
    // サイマルキャストを利用する場合は、 RTCPeerConnection の生成前に WrapperVideoEncoderFactory を設定する必要がある
    WrapperVideoEncoderFactory.shared.simulcastEnabled = snapshot.simulcastEnabled

    startConnection {
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
    transportStorage.append(stream: stream)
    Logger.debug(type: .peerChannel, message: "call onAddStream")
    internalHandlers.onAddStream?(stream)
  }

  func remove(streamId: String) {
    // 読み出しと削除は storage の 1 回の lock 区間で行い、通知には取り除いた要素を使う。
    let removed = transportStorage.remove(streamId: streamId)
    guard let stream = removed.first else {
      return
    }
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
    if let pending = connectionStateOwner.requestDisconnect(
      error: error,
      reason: reason,
      shouldCancelDisconnectTimerBasedDisconnect: shouldCancelDisconnectTimerBasedDisconnect,
      isConnectHandlerHeld: { self.onConnect != nil }
    ) {
      basicDisconnect(error: pending.error, reason: pending.reason)
    }
  }

  // MARK: - 接続ライフサイクルの排他

  /// 接続開始の初期ロックを取得します。
  ///
  /// `connect()` が最初に取得し、`finishConnecting()` または
  /// `sendConnectMessage(error:)` まで保持します。取得できた場合のみ
  /// `startConnection(_:)` へ進めます。
  ///
  /// テストから呼び出すため internal としている。
  @discardableResult
  func beginConnectionStart() -> Bool {
    connectionStateOwner.beginConnectionStart()
  }

  /// signaling の開始を、開始の前後に到着した切断要求と直列化します。
  ///
  /// 開始前に保存された切断要求がある場合は signaling を開始せずに切断します。
  /// 開始中に到着した切断要求は `operation` の復帰後に実行します。
  ///
  /// テストから呼び出すため internal としている。
  func startConnection(_ operation: () -> Void) {
    switch connectionStateOwner.prepareSignalingStart(
      shouldCancelDisconnectTimerBasedDisconnect: shouldCancelDisconnectTimerBasedDisconnect)
    {
    case .ignored:
      return
    case .disconnect(let pending):
      basicDisconnect(error: pending.error, reason: pending.reason)
      return
    case .start:
      break
    }

    operation()

    // operation の実行中にも切断要求が到着し得るため、開始区間を閉じる処理と
    // 保存済み要求の取り出しを同じ排他領域で行う。
    if let pending = connectionStateOwner.finishSignalingStart(
      shouldCancelDisconnectTimerBasedDisconnect: shouldCancelDisconnectTimerBasedDisconnect)
    {
      basicDisconnect(error: pending.error, reason: pending.reason)
    }
  }

  /// 進行中の非同期処理の開始を登録します。
  ///
  /// 切断処理が開始済みの場合は false を返し、呼び出し側は処理を開始しません。
  ///
  /// テストから呼び出すため internal としている。
  @discardableResult
  func beginAsyncOperation() -> Bool {
    connectionStateOwner.beginAsyncOperation()
  }

  /// 進行中の非同期処理の終了を登録し、保存された切断要求があれば実行します。
  ///
  /// テストから呼び出すため internal としている。
  func endAsyncOperation() {
    if let pending = connectionStateOwner.endAsyncOperation(
      shouldCancelDisconnectTimerBasedDisconnect: shouldCancelDisconnectTimerBasedDisconnect)
    {
      // 切断要求は、 nativeChannel が先に .closed へ遷移していても後始末が必要である。
      // 二重実行は接続状態 owner の isDisconnecting が防ぐ。
      basicDisconnect(error: pending.error, reason: pending.reason)
    }
  }

  /// 猶予タイマー由来の切断要求が、接続の回復により無効化されるかを返します。
  ///
  /// タイマー発火時点の確認から切断実行までの間に接続が回復している場合、
  /// 切断すると一時的な切断の回復を阻害するためキャンセルします。
  /// `.disconnected` のままなら切断を継続します。 `.failed` は終端状態であり
  /// 回復し得ないためキャンセルしません。他の reason はユーザーの意図または
  /// 確定した切断なので、この再確認の対象外とします。
  private func shouldCancelDisconnectTimerBasedDisconnect(reason: DisconnectReason) -> Bool {
    reason == .peerConnectionStateDisconnected
      && state != .disconnected
      && state != .failed
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
  /// 利用者 callback は排他区間の外で呼ぶ。callback 内から同期的に disconnect() されると
  /// `ConnectionStateOwner.requestDisconnect` が `state` 経由で `connectHandlerLock` を取るため、
  /// 保持したまま呼ぶとデッドロックする。
  ///
  /// テストから呼び出すため internal としている。
  func invokeConnectHandler(_ error: Error?) {
    let connectHandler = takeConnectHandler()
    if let connectHandler {
      Logger.debug(type: .peerChannel, message: "call connect(handler:)")
      connectHandler(error)
    }
  }

  /// 保持中の接続完了 callback を取り出し、同じ排他区間で nil へクリアします。
  ///
  /// 取り出しとクリアを分けると、並行する `invokeConnectHandler` が同じ callback を
  /// 2 回取り出し得る。1 回の lock 区間で行うことで 1 回保証を成立させる。
  /// 呼び出し元は取り出した callback を排他区間の外で実行すること。
  private func takeConnectHandler() -> ((Error?) -> Void)? {
    connectHandlerLock.lock()
    defer { connectHandlerLock.unlock() }
    let connectHandler = storedOnConnect
    storedOnConnect = nil
    return connectHandler
  }

  private func sendConnectMessage(error: Error?) {
    if let error {
      endAsyncOperation()
      Logger.error(
        type: .peerChannel,
        message: "failed connecting to signaling channel (\(error.localizedDescription))")
      invokeConnectHandler(error)
      return
    }

    if snapshot.isSender {
      Logger.debug(type: .peerChannel, message: "try creating offer SDP")
      let offerConfiguration = currentWebRTCConfiguration()
      nativePeerChannelFactory
        .createClientOfferSDP(
          webRTCConfiguration: offerConfiguration
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
    switch snapshot.role {
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

    let simulcast = snapshot.simulcastEnabled
    return SignalingConnect(
      role: role,
      channelId: snapshot.channelId,
      clientId: snapshot.clientId,
      bundleId: snapshot.bundleId,
      metadata: snapshot.signalingConnectMetadata,
      notifyMetadata: snapshot.signalingConnectNotifyMetadata,
      sdp: sdp,
      multistreamEnabled: snapshot.multistreamEnabled,
      videoEnabled: snapshot.videoEnabled,
      videoCodec: snapshot.videoCodec,
      videoBitRate: snapshot.videoBitRate,
      audioEnabled: snapshot.audioEnabled,
      audioCodec: snapshot.audioCodec,
      audioBitRate: snapshot.audioBitRate,
      opusParams: snapshot.audioOpusParams,
      spotlightEnabled: snapshot.isSpotlightEnabled ? .enabled : .disabled,
      spotlightNumber: snapshot.spotlightNumber,
      spotlightFocusRid: snapshot.spotlightFocusRid,
      spotlightUnfocusRid: snapshot.spotlightUnfocusRid,
      simulcastEnabled: simulcast,
      simulcastRid: snapshot.simulcastRid,
      simulcastRequestRid: snapshot.simulcastRequestRid,
      soraClient: soraClient,
      webRTCVersion: webRTCVersion,
      environment: DeviceInfo.current.description,
      dataChannelSignaling: snapshot.dataChannelSignaling,
      ignoreDisconnectWebSocket: snapshot.ignoreDisconnectWebSocket,
      audioStreamingLanguageCode: snapshot.audioStreamingLanguageCode,
      redirect: redirect,
      forwardingFilter: snapshot.forwardingFilter?.forwardingFilter(),
      forwardingFilters: snapshot.forwardingFilters?.map { $0.forwardingFilter() },
      vp9Params: snapshot.videoVp9Params,
      av1Params: snapshot.videoAv1Params,
      h264Params: snapshot.videoH264Params,
      h265Params: snapshot.videoH265Params,
      dataChannelSettings: snapshot.dataChannelSettings
    )
  }

  private func initializeSenderStream(mid: [String: String]? = nil) {
    // nativeChannel の参照は storage から 1 度だけ取り出し、以降はこのローカルを使う。
    // (storage の lock を保持したまま transceivers などの libwebrtc を呼ばない)
    guard let nativeChannel = transportStorage.native else {
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
      return
    }

    Logger.debug(
      type: .peerChannel,
      message: "initialize sender stream")

    // constraints と degradationPreference は接続所有の設定から読む。
    // 利用者由来の snapshot.webRTCConfiguration は offer 受信で更新されないため、
    // 2 系統に分けると offer 由来の値が増えたときにずれる。
    let connectionWebRTCConfiguration = currentWebRTCConfiguration()

    let nativeStream =
      nativePeerChannelFactory
      .createNativeSenderStream(
        streamId: snapshot.publisherStreamId,
        videoTrackId:
          snapshot.videoEnabled ? snapshot.publisherVideoTrackId : nil,
        audioTrackId:
          snapshot.audioEnabled ? snapshot.publisherAudioTrackId : nil,
        constraints: connectionWebRTCConfiguration.constraints)
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

        if let degradationPreference = connectionWebRTCConfiguration
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
    if snapshot.audioEnabled {
      if !snapshot.usesCustomAudioDevice {
        initializeAudioInput()
      } else {
        // AVAudioSession の設定はカスタム音声デバイス (DummyAudioDevice.initialize(with:)) が行うためスキップする
        Logger.debug(
          type: .peerChannel,
          message: "custom audio device enabled, skip initialize audio input")
      }
    } else if snapshot.usesCustomAudioDevice {
      // 音声トラック自体が生成されないためダミー音声も無効となる
      Logger.warn(
        type: .peerChannel,
        message: "custom audio device enabled but audioEnabled is false, audio is disabled")
    }

    // カメラの初期化
    if snapshot.videoEnabled, snapshot.cameraSettings.isEnabled,
      snapshot.initialCameraEnabled
    {
      initializeCameraVideoCapture(stream: stream)
    }

    add(stream: stream)
    Logger.debug(
      type: .peerChannel,
      message: "create publisher stream (id: \(snapshot.publisherStreamId))")
  }

  private func initializeAudioInput() {
    // 初期化済みフラグは ConnectionStateOwner が単一所有する。読みは owner の同期 API を
    // 使う (この関数は owner の排他区間から呼ばれないため、同期 wait で再入しない)。
    if connectionStateOwner.isAudioInputInitialized() {
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
      let initialMicrophoneMute = !snapshot.initialMicrophoneEnabled
      if !session.setInitialMicrophoneMute(initialMicrophoneMute) {
        Logger.warn(type: .peerChannel, message: "failed to setInitialMicrophoneMute")
      }

      // 完了 closure は WebRTC 側のスレッドから呼ばれる。捕捉するのは
      // ConnectionStateOwner (@unchecked Sendable) だけで、PeerChannel 自身は捕捉しない。
      //
      // owner を弱参照で捕捉する。強参照にすると、RTCAudioSession が完了 closure を保持し、
      // その closure が owner を、owner が PeerChannel を保持する経路で PeerChannel が
      // 解放されなくなる。弱参照にすると、PeerChannel の解放後に完了 closure が走った場合は
      // フラグを立てない。これは変更前の [weak self] と同じ挙動である。
      let connectionStateOwner = self.connectionStateOwner
      session.initializeInput { [weak connectionStateOwner] error in
        if let error {
          Logger.debug(
            type: .peerChannel,
            message: "failed to initialize audio input => \(error.localizedDescription)"
          )
          return
        }
        // 書きは owner の直列 queue 上の event で行う。完了 closure の実行スレッドに
        // 関わらず、この同期 wait が直列 queue の実行を待つ。
        connectionStateOwner?.handle(.audioInputInitialized)
        Logger.debug(
          type: .peerChannel,
          message:
            "audio input is initialized => category \(RTCAudioSession.sharedInstance().category)"
        )
      }
    }
  }

  private func initializeCameraVideoCapture(stream: MediaStream) {
    let position = snapshot.cameraSettings.position

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
        width: snapshot.cameraSettings.resolution.width,
        height: snapshot.cameraSettings.resolution.height,
        for: capturer.device,
        frameRate: snapshot.cameraSettings.frameRate)
    else {
      Logger.error(
        type: .peerChannel,
        message:
          "CameraVideoCapturer.suitableFormat failed: suitable format rate is not found")
      return
    }

    guard
      let frameRate = CameraVideoCapturer.maxFrameRate(
        snapshot.cameraSettings.frameRate, for: format)
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

      if let current = CameraVideoCapturer.current {
        guard videoSourceCoordinator.isValid(reservation) else {
          return
        }
        guard current.isRunning else {
          _ = videoSourceCoordinator.completeCamera(reservation, active: false)
          cameraCaptureCoordinator.quarantine(capturerID: current.id)
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
          cameraCaptureCoordinator.quarantine(capturerID: current.id)
          Logger.error(
            type: .peerChannel,
            message:
              "CameraVideoCapturer.stop did not stop capture: \(stopError?.localizedDescription ?? "unknown error")"
          )
          return
        }
        cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturerID: current.id)
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
        cameraCaptureCoordinator.quarantine(capturerID: capturer.id)
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
          cameraCaptureCoordinator.quarantine(capturerID: capturer.id)
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
          cameraCaptureCoordinator.quarantine(capturerID: capturer.id)
          Logger.error(
            type: .peerChannel,
            message:
              "failed to stop CameraVideoCapturer after cancelled start: \(stopError?.localizedDescription ?? "unknown error")"
          )
          return
        }
        cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturerID: capturer.id)
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
    guard snapshot.videoEnabled, snapshot.cameraSettings.isEnabled else {
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
      guard let current = CameraVideoCapturer.current else {
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
        cameraCaptureCoordinator.quarantine(capturerID: current.id)
        Logger.error(
          type: .peerChannel,
          message:
            "failed to stop CameraVideoCapturer: \(stopError?.localizedDescription ?? "unknown error")"
        )
        return
      }
      cameraCaptureCoordinator.clearQuarantineAfterSuccessfulStop(capturerID: current.id)
      cameraCaptureOwnership.clear(ifOwnedBy: senderStream)
      videoSourceCoordinator.releaseCamera()
    }
  }

  private func createAnswer(
    isSender: Bool,
    offer: String,
    // `RTCMediaConstraints` は `Sendable` ではないため、値の写しができる
    // `MediaConstraints` (`Sendable`) を引数に取り、非同期境界の内側で native 値へ変換する。
    constraints: MediaConstraints,
    initialOffer: Bool = false,
    mid: [String: String]? = nil,
    generation: Int,
    handler: @escaping (String?, (any Error)?) -> Void
  ) {
    let handlerBox = CreateAnswerHandlerBox(handler)
    // 完了 closure が捕捉するのはこの box だけである。box は PeerChannel を弱参照で保持し、
    // PeerChannel が解放された場合は value が nil になって handler の 1 回保証の経路へ入る
    // (変更前の [weak self] と同じ挙動)。transportStorage は box を経由せず self から読む。
    let box = WeakPeerChannelBox(value: self)

    guard let nativeChannel = transportStorage.native else {
      // handler を呼ばずに return すると、呼び出し元が接続ライフサイクルの排他を
      // 解放できない (解放漏れ)。
      // 明示的な接続失敗として handler を必ず 1 回呼ぶ。
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
      handlerBox(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
      return
    }

    Logger.debug(type: .peerChannel, message: "try create answer")
    Logger.debug(type: .peerChannel, message: offer)

    Logger.debug(type: .peerChannel, message: "try setting remote description")
    let offer = RTCSessionDescription(type: .offer, sdp: offer)
    // `RTCSessionDescription` は `Sendable` ではないが、この closure が使うのは
    // `sdpDescription` だけである。 setRemoteDescription の closure に入る前に
    // String へ写し、捕捉対象を `Sendable` な値に置き換える。
    let offerDescription = offer.sdpDescription
    nativeChannel.setRemoteDescription(offer) { [box] error in
      guard let self = box.value else {
        // `self` が解放済みでも handler を 1 回呼んで return する。handler の完了で
        // 接続ライフサイクルの排他を解放する呼び出し元では、呼ばれないと解放漏れになる。
        // 現状この節は到達しない (完了 block は handlerBox → handler → `self` の順に強参照し、
        // `nativeChannel` も `PeerChannel` の transportStorage が保持するため、
        // `PeerChannel` が解放されると `RTCPeerConnection` への強参照も失われて callback が
        // 届かない) が、「到達状況に関わらず handler を必ず 1 回呼ぶ」不変条件を満たすために呼ぶ。
        Logger.error(type: .peerChannel, message: "peerChannel is unavailable")
        handlerBox(nil, SoraError.peerChannelError(reason: "PeerChannel is unavailable"))
        return
      }
      guard error == nil else {
        Logger.debug(
          type: .peerChannel,
          // guard の else 節で非 nil が保証されるため安全
          // swiftlint:disable:next force_unwrapping
          message: "failed setting remote description: (\(error!.localizedDescription)")
        handlerBox(nil, error)
        return
      }

      // リダイレクト等で接続が切り替わった場合は、以後の SDP パイプライン
      // (initializeSenderStream / updateSenderOfferEncodings / answer / setLocalDescription)
      // を実行せずに破棄する。
      // (チェーンの各ステップは transportStorage の nativeChannel を再読取するため、世代照合が
      // 最終クロージャのみだと、旧 offer の SDP・mid・encodings が新 PC に適用される)
      guard generation == self.dataChannelGeneration else {
        handlerBox(nil, nil)
        return
      }

      // 世代照合でリダイレクトが無いことを確認した後にだけ storage を再読するため、
      // 「常に現在の RTCPeerConnection を使う」性質は変更前と同じである。
      guard let nativeChannel = self.transportStorage.native else {
        // handler を呼ばずに return すると呼び出し元が接続ライフサイクルの排他を
        // 解放できないため、エラーを渡す
        Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
        handlerBox(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
        return
      }

      Logger.debug(type: .peerChannel, message: "did set remote description")
      Logger.debug(type: .peerChannel, message: "\(offerDescription)")

      if isSender {
        if initialOffer {
          self.initializeSenderStream(mid: mid)
        }
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "try creating native answer")
      nativeChannel.answer(for: constraints.nativeValue) { [box] answer, error in
        guard error == nil else {
          Logger.debug(
            type: .peerChannel,
            // guard の else 節で非 nil が保証されるため安全
            // swiftlint:disable:next force_unwrapping
            message: "failed creating native answer (\(error!.localizedDescription)")
          handlerBox(nil, error)
          return
        }

        guard let self = box.value else {
          // 外側の closure と同じく、`self` が解放済みでも handler を 1 回呼んで return する。
          // この節も現状は到達しない (handlerBox が handler を強参照し、handler が
          // `PeerChannel` を強参照するため) が、1 回保証の不変条件を満たすために呼ぶ。
          Logger.error(type: .peerChannel, message: "peerChannel is unavailable")
          handlerBox(nil, SoraError.peerChannelError(reason: "PeerChannel is unavailable"))
          return
        }

        // リダイレクト等で接続が切り替わった場合は、以後の SDP パイプライン
        // (setLocalDescription) を実行せずに破棄する。
        // (answer 作成中にリダイレクトが発生した場合、以下の再読取で新 PC を取得し、
        // 旧 offer の answer が新 PC に適用されるのを防ぐ)
        guard generation == self.dataChannelGeneration else {
          handlerBox(nil, nil)
          return
        }

        // 世代照合でリダイレクトが無いことを確認した後にだけ storage を再読する。
        guard let nativeChannel = self.transportStorage.native else {
          // handler を呼ばずに return すると呼び出し元が接続ライフサイクルの排他を
          // 解放できないため、エラーを渡す
          Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
          handlerBox(nil, SoraError.peerChannelError(reason: "nativeChannel should not be nil"))
          return
        }

        Logger.debug(type: .peerChannel, message: "did create answer")

        guard let answer else {
          handlerBox(nil, SoraError.peerChannelError(reason: "answer should not be nil"))
          return
        }

        let localAnswer: RTCSessionDescription
        do {
          let sdp =
            self.snapshot.requiresStereoAudioSDP
            ? try StereoAudioSDP.enableStereo(in: answer.sdp) : answer.sdp
          localAnswer = RTCSessionDescription(type: answer.type, sdp: sdp)
        } catch {
          handlerBox(nil, error)
          return
        }

        // `RTCSessionDescription` は `Sendable` ではないため、 setLocalDescription の closure が
        // 使う `sdp` と `sdpDescription` の両方を closure に入る前に String へ写す。
        // 片方だけでは capture が残る。
        let localAnswerSDP = localAnswer.sdp
        let localAnswerSDPDescription = localAnswer.sdpDescription

        Logger.debug(type: .peerChannel, message: "try setting local description")
        nativeChannel.setLocalDescription(localAnswer) { error in
          guard error == nil else {
            Logger.debug(
              type: .peerChannel,
              message: "failed setting local description")
            handlerBox(nil, error)
            return
          }
          Logger.debug(
            type: .peerChannel,
            message: "did set local description")
          Logger.debug(
            type: .peerChannel,
            message: "\(localAnswerSDPDescription)")
          Logger.debug(
            type: .peerChannel,
            message: "did create answer")
          handlerBox(localAnswerSDP, nil)
        }
      }
    }
  }

  private func updateSenderOfferEncodings() {
    // nativeChannel と offerEncodings は transportStorage から 1 度ずつ取り出す。
    // 取り出した後の libwebrtc 呼び出しは storage の lock を解放してから行う。
    guard let nativeChannel = transportStorage.native else {
      Logger.debug(type: .peerChannel, message: "nativeChannel should not be nil")
      return
    }

    guard let oldEncodings = transportStorage.offerEncodings else {
      return
    }

    Logger.debug(type: .peerChannel, message: "update sender offer encodings")
    for sender in nativeChannel.senders {
      sender.updateOfferEncodings(oldEncodings)
    }
  }

  private func createAndSendAnswer(offer: SignalingOffer) {
    Logger.debug(type: .peerChannel, message: "try sending answer")
    transportStorage.offerEncodings = offer.encodings

    // 受信時点の世代を記録し、非同期処理の完了時に現在の世代と照合する。
    // (リダイレクトで接続が切り替わった場合に、旧接続の answer が新接続に送信されるのを防ぐ)
    let generation = dataChannelGeneration

    var updatedConfiguration = currentWebRTCConfiguration()
    if let config = offer.configuration {
      Logger.debug(type: .peerChannel, message: "update configuration")
      Logger.debug(
        type: .peerChannel, message: "ICE server infos => \(config.iceServerInfos)")
      Logger.debug(
        type: .peerChannel, message: "ICE transport policy => \(config.iceTransportPolicy)")
      updatedConfiguration = updatedConfiguration.replacing(
        iceServerInfos: config.iceServerInfos.map(ICEServerSnapshot.init),
        iceTransportPolicy: config.iceTransportPolicy)
    }

    // isInsecure は offer.configuration の有無にかかわらず毎回 Configuration.insecure で
    // 置き換える。
    updatedConfiguration = updatedConfiguration.replacing(isInsecure: snapshot.insecure)
    updateWebRTCConfiguration(updatedConfiguration)
    if snapshot.insecure {
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
      caCertificates = try snapshot.parsedCACertificates()
    } catch {
      endAsyncOperation()
      disconnect(
        error: error,
        reason: .signalingFailure)
      return
    }

    // 上で更新した値をそのまま使う。lock は読み出しごとに解放されるため、
    // currentWebRTCConfiguration() を再読すると同一の値を参照する保証がコード上に無い。
    transportStorage.native =
      nativePeerChannelFactory
      .createNativePeerChannel(
        webRTCConfiguration: updatedConfiguration,
        proxy: snapshot.proxy,
        caCertificates: caCertificates,
        delegate: self)
    guard let nativeChannel = transportStorage.native else {
      // connect() で取得した初期ロックをここで解放しないと、
      // disconnect が defer されたままになってしまう。
      endAsyncOperation()
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
    handleConnectionEvent(.redirectConnectStarted)
    nativeChannel.setConfiguration(updatedConfiguration.nativeValue)

    createAnswer(
      isSender: snapshot.isSender,
      offer: offer.sdp,
      constraints: updatedConfiguration.constraints,
      initialOffer: true,
      mid: offer.mid,
      generation: generation
    ) { sdp, error in
      // リダイレクト等で接続が切り替わった場合は、旧接続の answer を破棄する。
      // (setRemoteDescription 等の非同期処理の完了前にリダイレクトが実行された場合に、
      // 旧 offer の answer が新接続に送信されるのを防ぐ)
      guard generation == self.dataChannelGeneration else {
        Logger.debug(type: .peerChannel, message: "generation changed, skip create answer")
        self.endAsyncOperation()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create answer (\(error.localizedDescription))")
        self.endAsyncOperation()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let sdp else {
        self.endAsyncOperation()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let answer = SignalingAnswer(sdp: sdp)
      self.signalingChannel.send(message: Signaling.answer(answer))
      self.endAsyncOperation()
      Logger.debug(type: .peerChannel, message: "did send answer")
    }
  }

  private func createAndSendUpdateAnswer(forOffer offer: String) {
    Logger.debug(type: .peerChannel, message: "create and send update-answer")
    guard beginAsyncOperation() else {
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
      constraints: currentWebRTCConfiguration().constraints,
      generation: generation
    ) { answer, error in
      // リダイレクト等で接続が切り替わった場合は、旧接続の update-answer を破棄する。
      guard generation == self.dataChannelGeneration else {
        self.endAsyncOperation()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create update-answer (\(error.localizedDescription)")
        self.endAsyncOperation()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.endAsyncOperation()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created update-answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let message = Signaling.update(SignalingUpdate(sdp: answer))
      self.signalingChannel.send(message: message)

      if self.snapshot.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      self.internalHandlers.onUpdate?(answer)

      self.endAsyncOperation()
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
      constraints: currentWebRTCConfiguration().constraints,
      generation: generation
    ) { answer, error in
      // 2025.1.1 までは beginAsyncOperation() の呼び出しをこのクロージャーの外 = createAnswer の直前で行っていたが、
      // この場合、 SDP 再ハンドシェイク時に SDP を local description に設定する際に EXC_BAD_ACCESS (不正なメモリアクセス) が発生し、
      // アプリがクラッシュしてしまうことがあったが、beginAsyncOperation() の呼び出しをクロージャー内にすることで、不正なメモリアクセスを防ぐことができるように
      // なったため、ここに移動させた (createAndSendReAnswerOverDataChannel も同様の理由で呼び出し位置を移動)
      guard self.beginAsyncOperation() else {
        Logger.debug(type: .peerChannel, message: "already disconnecting, skip re-answer")
        return
      }
      // リダイレクト等で接続が切り替わった場合は、旧接続の re-answer を破棄する。
      // (setRemoteDescription 等の非同期処理の完了前にリダイレクトが実行された場合に、
      // 旧 offer の answer が新接続に適用されるのを防ぐ)
      guard generation == self.dataChannelGeneration else {
        Logger.debug(type: .peerChannel, message: "generation changed, skip re-answer")
        self.endAsyncOperation()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create re-answer (\(error.localizedDescription)")
        self.endAsyncOperation()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.endAsyncOperation()
        self.disconnect(
          error: SoraError.peerChannelError(reason: "created re-answer SDP is unavailable"),
          reason: .signalingFailure)
        return
      }

      let message = Signaling.reAnswer(SignalingReAnswer(sdp: answer))
      self.signalingChannel.send(message: message)

      if self.snapshot.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      self.internalHandlers.onUpdate?(answer)

      self.endAsyncOperation()
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
      constraints: currentWebRTCConfiguration().constraints,
      generation: generation
    ) { answer, error in
      // NOTE: PeerChannel のインスタンスをキャプチャすることを明示的に指定する必要があるため、self が必要
      guard self.beginAsyncOperation() else {
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
        self.endAsyncOperation()
        return
      }
      if let error {
        Logger.error(
          type: .peerChannel,
          message: "failed to create re-answer: error => (\(error.localizedDescription)")
        self.endAsyncOperation()
        self.disconnect(error: error, reason: .signalingFailure)
        return
      }
      guard let answer else {
        self.endAsyncOperation()
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
        self.endAsyncOperation()
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
          self.endAsyncOperation()
          self.disconnect(
            error: SoraError.peerChannelError(
              reason: "failed to send re-answer message over DataChannel"),
            reason: .signalingFailure)
          return
        }
      }

      if self.snapshot.isSender {
        self.updateSenderOfferEncodings()
      }

      Logger.debug(type: .peerChannel, message: "call onUpdate")
      self.internalHandlers.onUpdate?(answer)

      self.endAsyncOperation()
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
      guard beginAsyncOperation() else {
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
      if snapshot.isMultistream {
        createAndSendUpdateAnswer(forOffer: update.sdp)
      }
    case .reOffer(let reOffer):
      createAndSendReAnswer(forReOffer: reOffer.sdp)

    case .ping(let ping):
      let pong = SignalingPong()
      if ping.statisticsEnabled == true {
        // 完了 closure は box だけを捕捉し、PeerChannel 自身は捕捉しない。
        // `signalingChannel` は再代入されない `let` であり、その状態の読み書きは
        // `SignalingChannel` の `SignalingStateOwner` の直列 queue が所有する。
        // `signalingChannel.internalHandlers` は `PeerChannel.init` と
        // `MediaChannel.connect` で接続開始前に設定され、この closure は読まない。
        // 世代や state を読まないため、接続状態 owner の排他には依存しない。
        let box = WeakPeerChannelBox(value: self)
        let nativeChannel = transportStorage.native
        nativeChannel?.statistics { [box] report in
          guard let self = box.value else {
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
      // - 切断 (disconnect / endAsyncOperation): isRedirecting 中は切断処理を続行
      // - WS 接続 (SignalingChannel): 切断後は state == .disconnected で受け入れ拒否
      //
      // 旧 PC を明示的にクローズする (遅延 OPEN 通知による OPEN 追跡状態の汚染防止と
      // リソースリーク解消)。先に世代を進めてから close() し、close に伴う
      // 旧 DataChannel の .closed 通知を無視させる。
      // 旧接続で開始された切断検出の猶予タイマーも無効化する
      // (旧接続の .disconnected を契機に開始されたタイマーがリダイレクト後も発火し、
      // 新接続を誤切断するのを防ぐ。また、disconnectTimerScheduled が true のまま
      // 残留すると新接続のタイマー開始が抑止される)
      handleConnectionEvent(.redirectReceived)
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
      // (旧 PeerConnection が送出する映像・音声フレームが新しい接続へ混入するのを防ぐ。
      //  terminate() が何を止めるかは切断経路のコメントを参照)
      // storage から配列を 1 度だけ取り出し、空判定・件数ログ・終端に同じ写しを使う。
      let streamsToTerminate = transportStorage.streams
      for stream in streamsToTerminate {
        stream.terminate()
      }
      if !streamsToTerminate.isEmpty {
        Logger.debug(
          type: .peerChannel,
          message: "redirect: terminated \(streamsToTerminate.count) streams")
      }
      transportStorage.removeAllStreams()
      cancelDisconnectTimer()
      // 参照の取り出しと close() を分ける (storage の lock を保持したまま close() しない)。
      let nativeChannel = transportStorage.native
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
    if webSocketDisconnectScheduled { return }
    guard switchedToDataChannel, signalingChannel.ignoreDisconnectWebSocket else { return }
    guard state != .closed else { return }
    guard let webSocketChannelIdentifier = signalingChannel.webSocketChannelIdentifier else {
      return
    }

    handleConnectionEvent(.webSocketDisconnectScheduled)

    Logger.info(
      type: .peerChannel,
      message: "scheduling WebSocket disconnect after \(Self.switchedDisconnectDelay) seconds")

    // DataChannel 確立直後も WebSocket 経由の送信キューにメッセージが残っている可能性があるため、
    // 既存の遅延 (switchedDisconnectDelay) を維持する
    //
    // 完了 block は box だけを捕捉する。判定に使う `state` の代わりに storage の
    // nativeChannel を使うが、`state != .closed` と `nativeChannel?.connectionState != .closed`
    // は等価である。`state` は `nativeChannel?.connectionState` を
    // PeerChannelConnectionState へ写した値で、唯一の上書き (`onConnect` を保持していて
    // `.new` のとき `.connecting` を返す) は `.closed` を対象にしない。`nativeChannel == nil`
    // のときも `state` は `.new` か `.connecting` で `.closed` にならず、
    // `nil` は `.closed` ではないため一致する。
    let box = WeakPeerChannelBox(value: self)
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + Self.switchedDisconnectDelay
    ) { [box] in
      guard let self = box.value else { return }
      let nativeChannel = self.transportStorage.native
      if nativeChannel?.connectionState != .closed {
        Logger.info(
          type: .peerChannel,
          message: "disconnecting WebSocket after DataChannel signaling established")
        self.signalingChannel.disconnectWebSocket(identifier: webSocketChannelIdentifier)
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
    endAsyncOperation()
  }

  private func basicDisconnect(error: Error?, reason: DisconnectReason) {
    // 切断によりリダイレクトを中止する。
    // (リダイレクト窓で切断が実行された場合、以降は通常の切断状態に戻す)
    // isRedirecting / webSocketDisconnectScheduled はここでリセットされる。
    // リセット後、切断処理中に DataChannel delegate から WebSocket 切断が
    // 再スケジュールされ得るが、発火時の state != .closed ガードと、閉じた
    // チャネルへの二重切断が無害であることから問題はない。
    handleConnectionEvent(.disconnectCompleted)

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

    let cameraCleanupTask = snapshot.isSender ? terminateSenderStream() : nil

    // カスタム音声デバイス (ダミー音声等) の停止。terminateSenderStream は送信側のカメラ停止のみを行い、
    // 音声デバイスの停止は行わないため、recvonly を含む全ロールで実行する。
    // nativeChannel?.close() より前に実行し、ADM スレッドが生存している状態で
    // terminateDevice の dispatchSync を実行する
    if let audioDevice = nativePeerChannelFactory.audioDevice {
      audioDevice.terminateDevice()
    }

    // stream の owner を無効化する。以降に到着したフレームは VideoFilter と RTCVideoSource へ
    // 渡らず、 renderer の frame / size / switch も配送されない。 renderer の onDisconnect は
    // main queue へ非同期に配送される。
    // storage から配列を 1 度だけ取り出し、同じ写しを終端とクリアに使う。
    let streamsToTerminate = transportStorage.streams
    for stream in streamsToTerminate {
      stream.terminate()
    }
    transportStorage.removeAllStreams()

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
    // 参照の取り出しと connectionState の読み、 close() は storage の lock を
    // 解放してから行う。
    let nativeChannel = transportStorage.native
    if nativeChannel?.connectionState != .closed {
      nativeChannel?.close()
    }
    // 実際の PeerConnection を閉じた後、利用者の切断 callback より前に要求を解放する。
    // 接続ライフサイクルの排他が切断を遅延した場合も、AudioUnit の利用中に解放されない。
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
      message: "signaling state: \(WebRTCEnumDescription.signalingState(stateChanged))")
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

    if snapshot.isMultistream,
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
      message: "ICE connection state: \(WebRTCEnumDescription.iceConnectionState(newState))")
  }

  func peerConnection(
    _ nativePeerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {
    Logger.debug(
      type: .peerChannel,
      message: "ICE gathering state: \(WebRTCEnumDescription.iceGatheringState(newState))")
  }

  /// 通知元の RTCPeerConnection が現在の接続のものであるかを判定する。
  /// リダイレクトから新 PC 生成までの窓では nativeChannel が旧 PC のままのため、
  /// PC アイデンティティの一致だけでは旧 PC の遅延通知を防げない。
  /// そのため、リダイレクト中は isRedirecting、新 PC 生成後は PC アイデンティティで判定する。
  /// (本ヘルパーは PC delegate (didOpen / didChange / didGenerateCandidate) 専用。
  /// DataChannel delegate は世代照合 (generation == dataChannelGeneration) で別途ガードするため、
  /// DataChannel 側の通知にこのヘルパーを使わないこと)
  private func isCurrentPeerConnection(_ nativePeerConnection: RTCPeerConnection) -> Bool {
    // isRedirecting は snapshot storage、nativeChannel は transportStorage の排他で読み、
    // 両者を入れ子にしない。
    !isRedirecting && nativePeerConnection === transportStorage.native
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
      // AudioSession lease を残さない。SDK 自身の close による再入は接続ライフサイクルの排他が防ぐ。
      disconnect(error: nil, reason: .noError)
    default:
      break
    }
  }

  /// 接続完了後に `RTCPeerConnectionState` が `.disconnected` のまま停滞した場合に、
  /// 猶予時間の経過後に切断するためのタイマーを開始する。
  ///
  /// 発火時に `RTCPeerConnectionState` を再確認し、 `.disconnected` のままの場合のみ
  /// 切断する。また、 `ConnectionStateOwner.endAsyncOperation` の遅延実行経路では接続が回復している場合は
  /// 切断をキャンセルする (いずれも発火・実行と `.connected` への回復の競合対策)。
  private func scheduleDisconnectTimerIfNeeded() {
    guard connectedAtLeastOnce else {
      return
    }
    guard !disconnectTimerScheduled else {
      return
    }
    handleConnectionEvent(.disconnectTimerScheduled)
    Logger.debug(
      type: .peerChannel,
      message: "scheduling disconnect timer after \(Self.disconnectedGracePeriod) seconds")
    let generation = disconnectTimerGeneration
    // 完了 block は box だけを捕捉する。`disconnectTimerGeneration` は snapshot storage、
    // `handleConnectionEvent` は ConnectionStateOwner、`disconnect(error:reason:)` は
    // ConnectionStateOwner.requestDisconnect の経路であり、
    // `nativeChannel` は transportStorage の排他で読む。
    //
    // `state == .disconnected` の代わりに storage の `nativeChannel?.connectionState` を使う。
    // 両者は等価である。`state` は `onConnect` の有無で `.new` を `.connecting` へ
    // 上書きするが、`.disconnected` はこの上書きの対象外である。また `nativeChannel == nil`
    // のとき `state` は `.new` / `.connecting` のどちらかで `.disconnected` にならないため、
    // `nativeChannel?.connectionState == nil` (`.disconnected` 以外) と一致する。
    let box = WeakPeerChannelBox(value: self)
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + Self.disconnectedGracePeriod
    ) { [box] in
      guard let self = box.value else {
        return
      }
      guard generation == self.disconnectTimerGeneration else {
        return
      }
      Logger.debug(
        type: .peerChannel,
        message: "disconnect timer fired (generation: \(generation))")
      self.handleConnectionEvent(.disconnectTimerFired)
      let nativeChannel = self.transportStorage.native
      guard nativeChannel?.connectionState == .disconnected else {
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
    handleConnectionEvent(.disconnectTimerCancelled)
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
          Logger.debug(
            type: .peerChannel,
            message: "networkPriority: \(WebRTCEnumDescription.priority(value))")
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
