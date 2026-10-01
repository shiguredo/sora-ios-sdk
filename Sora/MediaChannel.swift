import Foundation
import WebRTC

/// SoraCloseEvent は、Sora の接続が切断された際のイベント情報を表します。
///
/// 接続が正常に切断された場合は、`.ok(code, reason)` ケースが使用され、
/// 異常な切断やエラー発生時は、`.error(Error)` ケースが使用されます。
public enum SoraCloseEvent: Sendable {
  /// 正常な接続切断を示します。
  /// - Parameters:
  ///   - code: 接続切断時に返されるコード。例えば、WebSocket の標準切断コード（例: 1000 等）など。
  ///   - reason: 接続が正常に切断された理由の説明文字列。
  case ok(code: Int, reason: String)
  /// 異常な切断またはエラーが発生して切断した場合に利用されるケースです。
  /// - Parameter error: エラー情報。
  case error(Error)
}

/// メディアチャネルのイベントハンドラです。
public final class MediaChannelHandlers {
  /// 接続成功時に呼ばれるクロージャー
  public var onConnect: ((Error?) -> Void)?

  /// 接続解除時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message:
      "onDisconnect: ((SoraCloseEvent) -> Void)? に移行してください。onDisconnectLegacy: ((Error?) -> Void)? は、2027 年中に削除予定です。"
  )
  public var onDisconnectLegacy: ((Error?) -> Void)?

  /// 接続解除時に呼ばれるクロージャー
  public var onDisconnect: ((SoraCloseEvent) -> Void)?

  /// ストリームが追加されたときに呼ばれるクロージャー
  public var onAddStream: ((MediaStream) -> Void)?

  /// ストリームが除去されたときに呼ばれるクロージャー
  public var onRemoveStream: ((MediaStream) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー。
  /// 引数の `String` には、受信したシグナリングメッセージの JSON 文字列が渡されます。
  public var onReceiveSignalingJSON: ((String) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message: "JSON 文字列を受け取る onReceiveSignalingJSON へ移行してください。"
  )
  public var onReceiveSignaling: ((Signaling) -> Void)?

  /// メッセージング用 DataChannel がすべてクライアント側で OPEN になったタイミングで呼ばれるクロージャー。
  /// メッセージング用ラベル（offer の `data_channels` の `#` 始まり）が存在しない場合は発火しない。
  /// この時点ではまだ `type: switched` を受信していない場合があり、
  /// その場合 `sendMessage` は "DataChannel is not open yet" エラーを返す。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannel: ((MediaChannel) -> Void)?

  /// DataChannel がクライアント側で OPEN になったタイミングで、ラベルごとに 1 回呼ばれるクロージャー。
  /// クライアント側で OPEN になったすべての DataChannel（`#` 始まりのラベルに限定しない）が対象。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannelOpened: ((MediaChannel, String) -> Void)?

  /// DataChannel のメッセージ受信時に呼ばれるクロージャー
  public var onDataChannelMessage: ((MediaChannel, String, Data) -> Void)?

  /// 初期化します。
  public init() {}
}

// MARK: -

/// MediaChannel 固有の切断準備と PeerChannel の完了通知を合流させる状態機械です。
/// 呼び出し側は MediaChannel の lifecycle lock を保持した状態で操作します。
struct MediaChannelDisconnectPreparation {
  enum State: Equatable {
    case notStarted
    case running
    case finished
  }

  enum ReceiveResult: Equatable {
    case prepare
    case deferred
    case ready
  }

  struct Completion {
    let connectionTask: ConnectionTask
    let error: Error?
    let reason: DisconnectReason
  }

  private(set) var state: State = .notStarted
  private var pendingCompletion: Completion?

  /// 切断準備を開始できる場合だけ状態を `running` へ進めます。
  mutating func begin() -> Bool {
    guard state == .notStarted else {
      return false
    }
    state = .running
    return true
  }

  /// PeerChannel の完了通知を受け取り、呼び出し側が次に行う処理を返します。
  mutating func receive(_ completion: Completion) -> ReceiveResult {
    switch state {
    case .notStarted:
      state = .running
      pendingCompletion = completion
      return .prepare
    case .running:
      if pendingCompletion == nil {
        pendingCompletion = completion
      }
      return .deferred
    case .finished:
      return .ready
    }
  }

  /// 切断準備を完了し、準備中に保留された完了通知を返します。
  mutating func complete() -> Completion? {
    guard state == .running else {
      return nil
    }
    state = .finished
    let completion = pendingCompletion
    pendingCompletion = nil
    return completion
  }
}

// MARK: -

/// 接続試行の予約から接続タイマー開始までを管理する状態機械です。
/// 呼び出し側は MediaChannel の lifecycle lock を保持した状態で操作します。
struct MediaChannelConnectionTimerAuthorization {
  enum State: Equatable {
    case idle
    case authorized
    case started
    case terminated
  }

  private(set) var state: State = .idle

  /// 接続試行を予約し、後続のタイマー開始を認可します。
  mutating func authorizeConnection() {
    precondition(state == .idle)
    state = .authorized
  }

  /// 認可された接続試行に対して、タイマー開始を 1 回だけ許可します。
  mutating func beginTimer() -> Bool {
    guard state == .authorized else {
      return false
    }
    state = .started
    return true
  }

  /// 接続成功または切断開始により、遅延したタイマー開始を恒久的に拒否します。
  mutating func terminate() {
    state = .terminated
  }
}

// MARK: -

/// `MediaChannel` を弱参照で並行処理境界へ渡すための、用途限定の内部ラッパーです。
/// `MediaChannel` 自体を Sendable とせず、終端処理と接続開始だけを lifecycle lock 配下へ戻します。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する参照は `init` でのみ代入する `weak var value` だけであること
///   (`weak` は runtime が参照の load / store を原子的に扱い、代入後に値を書き換えない)
/// - 変更前から `MediaChannel` を捕捉していた非同期 cleanup の完了通知と
///   `DispatchQueue.global().async` の block を包み直すだけで、配送先・実行順序・
///   呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持する `MediaChannel` に対して closure が呼ぶメソッドが到達する状態アクセスが、
///   既存の排他 (`connectionLifecycleLock`、`MediaChannelStateStorage` /
///   `PeerChannelTransportStorage` の `NSLock`) と `init` で確定した不変値に閉じること
///
/// この `@unchecked Sendable` は「この box を使う経路で closure が行う状態アクセスが
/// 安全である」という限定した主張であり、`MediaChannel` 全体が thread-safe であることも、
/// `MediaChannel` に `Sendable` 準拠を追加することも主張しません。
/// 参照する状態の所有と同期が `MediaChannel` 側の責務であることは変更前と同じです。
///
/// `value` を弱参照にするのは、変更前の `[weak self]` と同じく「`MediaChannel` が解放済みなら
/// 何もしない」挙動を維持するためです。強参照にすると、`Task` や `DispatchQueue` が
/// 完了 closure を保持し、その closure が box を、box が `MediaChannel` を保持する経路で
/// `MediaChannel` が解放されなくなります。
private final class WeakMediaChannelBox: @unchecked Sendable {
  weak var value: MediaChannel?

  init(_ value: MediaChannel) {
    self.value = value
  }
}

// MARK: -

/// `MediaChannel.connect` の非同期 hop が接続試行の `ConnectionTask` を参照するための、
/// 用途限定の参照保持 box です。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する `ConnectionTask` の参照は `init` で確定した `let` であること。
///   box は参照を保持して block へ渡すだけで、状態を読み書きしないこと
/// - 変更前から `ConnectionTask` を捕捉していた `DispatchQueue.global().async` の block を
///   包み直すだけで、配送先・実行順序・呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持する `ConnectionTask` に対して block が行う状態アクセスが、`ConnectionTask` の
///   `stateLock` (`NSLock`) に閉じること。`ConnectionTask` の可変状態は `_internalState` と
///   `_peerChannel` の 2 つだけで、`state` / `attach(peerChannel:)` / `markCanceled()` /
///   `tryComplete()` / `complete()` / `cancel()` のすべてが `stateLock` を取る。
///   `cancel()` は lock を解放してから `disconnect` を呼び、lock を保持したまま
///   利用者 handler や libwebrtc を呼ばない
///
/// この `@unchecked Sendable` は「この box を使う経路で closure が行う状態アクセスが
/// 安全である」という限定した主張であり、`ConnectionTask` 全体が thread-safe であることは
/// 主張しません。`ConnectionTask` に `Sendable` 準拠を追加することも主張しません。
///
/// 強参照で保持するのは、変更前に block が `ConnectionTask` を強参照で捕捉していたためです。
/// 戻り値の `ConnectionTask` を利用者が即座に手放しても、block が実行されるまでは
/// この box が生存させます。
private final class MediaChannelConnectionTaskBox: @unchecked Sendable {
  let value: ConnectionTask

  init(_ value: ConnectionTask) {
    self.value = value
  }
}

// MARK: -

/// `MediaChannel.state` の写しを `NSLock` で保護して保持する storage です。
///
/// `MediaChannel.state` は公開 API の表現 (`public private(set) var` の stored property) を
/// 変えられないため stored property のまま維持します。この storage は、`getStats` の完了
/// closure が `MediaChannel` 自身を捕捉せずに現在の接続状態を読むための経路です。
/// 状態の書き込みは `MediaChannel` の `connectionLifecycleLock` 配下でだけ行い、
/// この storage への写しも同じ区間で更新します。したがって lock 順序は
/// `connectionLifecycleLock` → この storage の一方向だけです。
///
/// `@unchecked Sendable` を認める根拠は、可変状態 (`state`) の読み書きをすべて
/// この `lock` 配下で行うことです。保持する `ConnectionState` は値型であり、
/// 参照型を保持しません。`getStats` の完了 closure へは `MediaChannelGetStatsContext` が
/// 強参照で渡し、この storage 自身の生存はその box の生存にも従います。
private final class MediaChannelStateStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var storedState: ConnectionState = .disconnected

  /// 現在の接続状態の写し。読み出しと書き込みの両方を `lock` で排他する。
  var state: ConnectionState {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedState
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedState = newValue
    }
  }
}

// MARK: -

/// libwebrtc の統計情報取得 handler、その取得対象の `RTCPeerConnection`、接続状態と
/// `nativeChannel` を読むための storage を並行処理境界へ渡すための、用途限定の内部ラッパーです。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する handler / `RTCPeerConnection` / `MediaChannelStateStorage` の
///   参照は `init` で確定した `let`、`PeerChannelTransportStorage` は `init` でのみ代入する
///   `weak var` であること (`weak` は runtime が参照の load / store を原子的に扱い、
///   代入後に値を書き換えない)。`RTCPeerConnection` は class であるため、ここで主張するのは
///   参照が再代入されないことだけで、オブジェクトの状態の不変性ではない。box は参照を保持して
///   callback へ渡すだけで、状態を読み書きしないこと
/// - 変更前から handler と `RTCPeerConnection` を渡していた `RTCPeerConnection.statistics` の
///   完了 block をそのまま包み直すだけで、配送先・通知順序・呼び出し回数を変えず、
///   別系統の境界へ新たに渡さないこと
/// - 保持する参照型に対する closure の状態アクセスが、既存または本変更で確立した排他に
///   閉じること。`MediaChannelStateStorage` は自身の `NSLock` が `state` の読み書きを保護し、
///   storage への書き込みは `MediaChannel` の `connectionLifecycleLock` 配下でだけ行う
///   (`connectionLifecycleLock` → storage の一方向)。`PeerChannelTransportStorage` も
///   自身の `NSLock` が `nativeChannel` / `streams` / `offerEncodings` の読み書きを保護する。
///   どちらの lock も保持したまま libwebrtc や利用者 handler を呼ばないこと
///
/// この `@unchecked Sendable` は「この box を使う経路で closure が行う状態アクセスが
/// 安全である」という限定した主張であり、`MediaChannel` / `PeerChannel` 全体が thread-safe で
/// あることも、両者に `Sendable` 準拠を追加することも主張しません。参照する状態の所有と
/// 同期が各クラス側の責務であることは変更前と同じです。
///
/// 保持する `RTCPeerConnection` は、変更前に完了 block が capture していた参照と同一です。
/// この参照を保持すると、redirect で `RTCPeerConnection` が入れ替わった後も、旧オブジェクトの
/// 解放が statistics callback の完了まで遅れます。変更前も完了 block が同じ参照を capture して
/// いたため callback の完了までは生存しており、入れ替え後の同一性判定
/// (`currentPeerConnection === context.peerConnection`) に必要な参照の同一性を保つため、
/// この遅延を許容します。同一性判定は従来どおり「redirect で旧 `RTCPeerConnection` が
/// 入れ替わったことの検出」だけに使い、この callback の実行スレッドと配送は変更前と同じです。
///
/// `transportStorage` を弱参照で保持するのは、変更前の `[weak self]` と同じく
/// `MediaChannel` (と `PeerChannel`) が解放済みなら `MediaChannel is unavailable` を返して
/// 1 回で終端するためです。強参照にすると、`MediaChannel` の解放後も
/// `PeerChannelTransportStorage` が `RTCPeerConnection` の参照を保持し続け、解放済みの
/// チャンネルの統計を成功として返してしまいます。
///
/// 生成は `MediaChannel.getStats` の 1 箇所だけで、1 つの block へ 1 回だけ渡して 1 回だけ実行する
/// 使用契約です (型では強制されません)。`Sendable` にするのはこの入れ物だけで、handler と
/// その捕捉状態を `Sendable` にはしません。捕捉状態の所有と同期は、呼び出しスレッドを
/// 保証しない既存の挙動の下で利用者の責務です。実行スレッドの同一性・直列性も契約にしません。
private final class MediaChannelGetStatsContext: @unchecked Sendable {
  let handler: (Result<Statistics, any Error>) -> Void
  let peerConnection: RTCPeerConnection

  /// 現在の接続状態を読む storage。
  ///
  /// `MediaChannel.state` の写しを `MediaChannel` の `connectionLifecycleLock` 配下で更新し、
  /// この storage 自身の `NSLock` で保護して読む。closure は `MediaChannel` を捕捉せず、
  /// この storage 経由で読む。
  let stateStorage: MediaChannelStateStorage

  /// 現在の `nativeChannel` を読む `PeerChannel` の storage。
  ///
  /// 弱参照にするのは、`PeerChannel` が解放済みであることを検出して handler を 1 回だけ
  /// 失敗で終端するためである。`PeerChannel` は `MediaChannel` が単一所有するため、
  /// この参照が nil であることは `MediaChannel` が解放済みであることと同じである。
  weak var transportStorage: PeerChannelTransportStorage?

  init(
    handler: @escaping (Result<Statistics, any Error>) -> Void,
    peerConnection: RTCPeerConnection,
    stateStorage: MediaChannelStateStorage,
    transportStorage: PeerChannelTransportStorage
  ) {
    self.handler = handler
    self.peerConnection = peerConnection
    self.stateStorage = stateStorage
    self.transportStorage = transportStorage
  }
}

// MARK: -

/// 一度接続を行ったメディアチャネルは再利用できません。
/// 同じ設定で接続を行いたい場合は、新しい接続を行う必要があります。
///
/// ## 接続が解除されるタイミング
///
/// メディアチャネルの接続が解除される条件を以下に示します。
/// いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル
/// (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます。
///
/// - シグナリングチャネル (`SignalingChannel`) の接続が解除される。
/// - WebSocket チャネル (`WebSocketChannel`) の接続が解除される。
/// - ピアチャネル (`PeerChannel`) の接続が解除される。
/// - サーバーから受信したシグナリング `ping` に対して `pong` を返さない。
///   これはピアチャネルの役目です。
public final class MediaChannel {
  // MARK: - イベントハンドラ

  /// イベントハンドラ
  public var handlers = MediaChannelHandlers()

  /// 内部処理で使われるイベントハンドラ
  var internalHandlers = MediaChannelHandlers()

  // MARK: - 接続情報

  /// クライアントの設定
  ///
  /// 公開互換のために利用者が渡した値を返し続けます。接続開始後の非同期区間
  /// (非同期 hop の後、WebRTC callback、`ConnectionTimer`) はこの値の参照型フィールド
  /// (metadata / notify metadata / codec 別 params / `dataChannels` / `forwardingFilter` /
  /// `forwardingFilters` / `webRTCConfiguration`、および snapshot に含めない handler bag と
  /// `audioDevice`) を読みません。値型フィールドは接続開始時の値のままなので、公開 getter、
  /// `description`、公開 mute API、`senderStream` / `receiverStreams` はこの値を読みます。
  public let configuration: Configuration

  /// 最初に type: connect メッセージを送信した URL (デバッグ用)
  ///
  /// Sora から type: redirect メッセージを受信した場合、 contactUrl と connectedUrl には異なる値がセットされます
  /// type: redirect メッセージを受信しなかった場合、 contactUrl と connectedUrl には同じ値がセットされます
  public var contactUrl: URL? {
    signalingChannel.contactUrl
  }

  /// 接続中の URL
  public var connectedUrl: URL? {
    signalingChannel.connectedUrl
  }

  /// メディアチャンネルの内部で利用している RTCPeerConnection
  public var native: RTCPeerConnection? {
    peerChannel.nativeChannel
  }

  /// クライアント ID 。接続後にセットされます。
  public var clientId: String? {
    peerChannel.clientId
  }

  /// バンドル ID 。接続後にセットされます。
  public var bundleId: String? {
    peerChannel.bundleId
  }

  /// 接続 ID 。接続後にセットされます。
  public var connectionId: String? {
    peerChannel.connectionId
  }

  /// 接続状態
  ///
  /// 遷移ログは排他区間の外で出すため (`didSet` では lock を保持したまま Logger を呼び得る)、
  /// `connectionLifecycleLock` を保持して遷移させる箇所では、遷移の直後 (lock の解放後) に
  /// 呼び出し元が `logStateChange(from:)` を呼ぶ。
  ///
  /// 公開 API の表現を変えられないため stored property のまま維持する。非同期の完了 closure が
  /// `MediaChannel` を捕捉せずに現在の接続状態を読む経路は `stateStorage` であり、遷移は
  /// `setState(_:)` に集約して両者を同じ区間で更新する。
  ///
  /// `state` に `didSet` を付けて `stateStorage` の写しを追随させる方式は採らない。
  /// 観測器を持つ stored property は、暗黙の getter から `Transparent` が外れて
  /// `swift-api-digester` の dump が変わり、commit 済みの公開 API baseline と一致しなくなる
  /// (`VideoView.backgroundView` が同じ形である)。`state` を直接代入する経路を足す場合は
  /// `setState(_:)` を経由すること。
  public private(set) var state: ConnectionState = .disconnected

  /// ``state`` の写しを lock 付きで保持する storage
  ///
  /// `getStats` の完了 closure は `MediaChannel` を捕捉できないため、現在の接続状態を
  /// この storage 経由で読む。書き込みは `setState(_:)` にだけ置き、`connectionLifecycleLock` を
  /// 保持した区間で `state` と同じ値へ更新する。これにより lock 順序は
  /// `connectionLifecycleLock` → この storage の一方向に揃う。
  private let stateStorage = MediaChannelStateStorage()

  /// 接続状態を遷移させ、完了 closure が読む storage へ写しを残します。
  ///
  /// 呼び出し側は `connectionLifecycleLock` を保持した状態で呼びます。`state` への直接代入を
  /// 残すと storage の写しが古くなるため、接続状態の遷移はこの 1 箇所に集約します。
  private func setState(_ next: ConnectionState) {
    state = next
    stateStorage.state = next
  }

  /// 接続中 (`state == .connected`) であれば ``true``
  public var isAvailable: Bool { state == .connected }

  // 排他区間の外で状態遷移ログを出す。
  //
  // A (遷移前) / B (遷移後) は connectionLifecycleLock を保持して確定させた値を渡す
  // (unlock 後に state を読み直すと、別スレッドの遷移を記録してしまう)。
  private func logStateChange(from previous: ConnectionState, to next: ConnectionState) {
    Logger.trace(
      type: .mediaChannel,
      message: "changed state from \(previous) to \(next)")
  }

  // 排他区間の外で ConnectionTask の完了ログを出す。
  private func logConnectionTaskCompleted(_ completed: Bool) {
    if completed {
      Logger.debug(type: .mediaChannel, message: "connection task completed")
    }
  }

  /// 接続開始時刻。
  /// 接続中にのみ取得可能です。
  public private(set) var connectionStartTime: Date?

  /// 接続時間 (秒) 。
  /// 接続中にのみ取得可能です。
  public var connectionTime: Int? {
    if let start = connectionStartTime {
      return Int(Date().timeIntervalSince(start))
    } else {
      return nil
    }
  }

  // MARK: 接続中のチャネルの情報

  /// 同チャネルに接続中のクライアントの数。
  /// サーバーから通知を受信可能であり、かつ接続中にのみ取得可能です。
  public private(set) var connectionCount: Int?

  /// 同チャネルに接続中のクライアントのうち、パブリッシャーの数。
  /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
  public private(set) var publisherCount: Int?

  /// 同チャネルに接続中のクライアントの数のうち、サブスクライバーの数。
  /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
  public private(set) var subscriberCount: Int?

  // MARK: 接続チャネル

  /// シグナリングチャネル
  let signalingChannel: SignalingChannel

  /// ピアチャネル
  var peerChannel: PeerChannel {
    // init で必ず初期化されるため安全
    // swiftlint:disable:next force_unwrapping
    _peerChannel!
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _peerChannel: PeerChannel?

  // MARK: - DataChannel の OPEN 追跡

  /// OPEN になった DataChannel のラベル集合。
  /// `onDataChannelOpened` の発火済みラベル (重複通知の防止用) を兼ねる。
  /// メッセージング用ラベル（`#` 始まり）も必ずここに含まれるため、
  /// `onDataChannel` の一括通知判定 (全メッセージング用ラベルが OPEN になったか) にも利用する。
  private var openedDataChannelLabels: Set<String> = []

  /// メッセージング用ラベル（offer の `data_channels` の `#` 始まり）の集合。
  /// offer 受信時 (resetDataChannelNotificationState 経由) に更新される。
  /// リダイレクト等で offer が再送された場合は常に最新の offer を基準に判定できる。
  private var messagingLabels: Set<String> = []

  /// `onDataChannel` の一括通知済みフラグ
  private var onDataChannelNotified = false

  /// DataChannel の OPEN 追跡状態を保護するロック。
  /// 状態の更新は libwebrtc の delegate スレッド (DataChannel の状態通知) と
  /// WebSocket 受信スレッド (offer 受信時のリセット) から並行して行われるため、
  /// NSLock で排他する。ハンドラ呼び出しはロックの外で行うこと。
  private let dataChannelOpenLock = NSLock()

  /// ストリームのリスト
  public var streams: [MediaStream] {
    peerChannel.streams
  }
  /// 最初のストリーム。
  /// マルチストリームでは、必ずしも最初のストリームが 送信ストリームとは限りません。
  /// 送信ストリームが必要であれば `senderStream` を使用してください。
  public var mainStream: MediaStream? {
    streams.first
  }

  /// 送信に使われるストリーム。
  /// ストリーム ID が `configuration.publisherStreamId` に等しいストリームを返します。
  public var senderStream: MediaStream? {
    streams.first { stream in
      stream.streamId == configuration.publisherStreamId
    }
  }

  /// 受信ストリームのリスト。
  /// ストリーム ID が `configuration.publisherStreamId` と異なるストリームを返します。
  public var receiverStreams: [MediaStream] {
    streams.filter { stream in
      stream.streamId != configuration.publisherStreamId
    }
  }

  private var connectionTimer: ConnectionTimer {
    // init で必ず初期化されるため安全
    // swiftlint:disable:next force_unwrapping
    _connectionTimer!
  }

  /// 接続タイマーの終端状態を回帰テストから確認するための内部アクセサーです。
  var isConnectionTimerRunning: Bool {
    connectionTimer.isRunning
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _connectionTimer: ConnectionTimer?

  private let nativePeerChannelFactory: NativePeerChannelFactory

  /// 接続開始、接続成功、切断開始、切断完了の競合を直列化します。
  /// 利用者のハンドラーは、このロックを保持した状態では呼び出しません。
  private let connectionLifecycleLock = NSLock()

  /// 現在の接続試行に対応する ConnectionTask です。
  private var currentConnectionTask: ConnectionTask?

  /// 一度開始した MediaChannel の再利用を拒否するためのフラグです。
  private var hasStartedConnection = false

  /// 接続試行の予約後に遅れて到着するタイマー開始を、切断終端後は拒否します。
  private var connectionTimerAuthorization = MediaChannelConnectionTimerAuthorization()

  /// 切断開始時点が接続試行中だったかを保持します。
  /// PeerChannel の実切断完了時に接続結果ハンドラーを発火するかの判定に使います。
  private var disconnectStartedWhileConnecting = false

  private var disconnectPreparation = MediaChannelDisconnectPreparation()

  /// PeerChannel から重複して切断完了が通知されても、公開通知を 1 回に抑えます。
  private var disconnectFinished = false

  // 映像ハードミュートの同時呼び出しを直列化するための Actor です
  // MediaChannel 間の排他実行を保証するため static にしています
  static let videoHardMuteActor = VideoHardMuteActor()

  /// この MediaChannel が所有する映像ハードミュート状態を識別します。
  private let videoHardMuteLease: VideoHardMuteLease

  /// カメラと画面共有の開始予約を接続単位で排他する状態です。
  private let videoSourceCoordinator: VideoSourceCoordinator

  /// カメラ状態の確認を process-wide のカメラ操作と直列化します。
  private let cameraCaptureCoordinator: CameraVideoCaptureCoordinator

  /// 接続後に開始したカメラも、PeerChannel の切断処理へ停止対象を引き継ぎます。
  private let cameraCaptureOwnership: CameraCaptureOwnership

  // ReplayKit を利用した画面キャプチャ制御です
  // インスタンスが必要な場合は getOrCreateScreenCaptureController 経由で取得します
  // 生成後は MediaChannel のライフサイクルで保持します。
  // stopScreenCapture / internalDisconnect から非同期停止を呼ぶため、
  // 参照を途中で解放せずに同一インスタンスへ停止要求を集約します。
  private var screenCaptureController: ScreenCaptureController?
  // screenCaptureController の生成・参照取得を排他し、
  // startScreenCapture の並行呼び出し時でも単一インスタンスを保証するためのロックです。
  private let screenCaptureControllerLock = NSLock()

  // MARK: - インスタンスの生成

  /// 初期化します。
  ///
  /// 利用者が渡した `Configuration` から snapshot を生成します。テストなどで
  /// snapshot を直接渡す場合は designated init を使います。
  /// - parameter configuration: クライアントの設定
  convenience init(
    configuration: Configuration,
    audioSessionCoordinator: AudioSessionCoordinator = .shared,
    videoHardMuteLease: VideoHardMuteLease = VideoHardMuteLease(),
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared,
    cameraCaptureOwnership: CameraCaptureOwnership = CameraCaptureOwnership(),
    videoSourceCoordinator: VideoSourceCoordinator = VideoSourceCoordinator()
  ) throws {
    try self.init(
      snapshot: ConnectionConfigurationSnapshot(configuration: configuration),
      configuration: configuration,
      audioDevice: configuration.audioDevice,
      mediaChannelHandlers: configuration.mediaChannelHandlers,
      webSocketChannelHandlers: configuration.webSocketChannelHandlers,
      audioSessionCoordinator: audioSessionCoordinator,
      videoHardMuteLease: videoHardMuteLease,
      cameraCaptureCoordinator: cameraCaptureCoordinator,
      cameraCaptureOwnership: cameraCaptureOwnership,
      videoSourceCoordinator: videoSourceCoordinator)
  }

  /// 初期化します。
  ///
  /// - parameter snapshot: 接続開始時に写し取った設定
  /// - parameter configuration: 公開互換のために保持する利用者の設定
  /// - parameter audioDevice: カスタム音声デバイス (snapshot には含めない)
  /// - parameter mediaChannelHandlers: メディアチャネルのハンドラ
  /// - parameter webSocketChannelHandlers: WebSocket チャネルのハンドラ
  init(
    snapshot: ConnectionConfigurationSnapshot,
    configuration: Configuration,
    audioDevice: RTCAudioDevice?,
    mediaChannelHandlers: MediaChannelHandlers,
    webSocketChannelHandlers: WebSocketChannelHandlers,
    audioSessionCoordinator: AudioSessionCoordinator = .shared,
    videoHardMuteLease: VideoHardMuteLease = VideoHardMuteLease(),
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared,
    cameraCaptureOwnership: CameraCaptureOwnership = CameraCaptureOwnership(),
    videoSourceCoordinator: VideoSourceCoordinator = VideoSourceCoordinator()
  ) throws {
    // snapshot の usesCustomAudioDevice は接続開始時に audioDevice != nil から確定する。
    // 両者を確定させる経路は init(configuration:) だけなので、不一致は SDK 内部の不具合。
    precondition(snapshot.usesCustomAudioDevice == (audioDevice != nil))

    try Self.validate(snapshot: snapshot)

    let audioSessionUsage: AudioSessionUsage =
      if snapshot.usesCustomAudioDevice {
        .custom
      } else if !snapshot.audioEnabled {
        .none
      } else if snapshot.audioStereoOutputEnabled {
        .stereoRemoteIO(requiresPlayAndRecord: snapshot.isSender)
      } else {
        .voiceProcessing(requiresPlayAndRecord: snapshot.isSender)
      }

    self.configuration = configuration
    self.videoHardMuteLease = videoHardMuteLease
    self.videoSourceCoordinator = videoSourceCoordinator
    self.cameraCaptureCoordinator = cameraCaptureCoordinator
    self.cameraCaptureOwnership = cameraCaptureOwnership
    self.nativePeerChannelFactory = try NativePeerChannelFactory(
      bypassVoiceProcessing: snapshot.bypassVoiceProcessing,
      audioDevice: audioDevice,
      audioSessionUsage: audioSessionUsage,
      audioSessionCoordinator: audioSessionCoordinator)
    signalingChannel = SignalingChannel.init(
      snapshot: snapshot,
      webSocketChannelHandlers: webSocketChannelHandlers)
    _peerChannel = PeerChannel.init(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativePeerChannelFactory,
      mediaChannel: self,
      cameraCaptureCoordinator: cameraCaptureCoordinator,
      cameraCaptureOwnership: cameraCaptureOwnership,
      videoSourceCoordinator: videoSourceCoordinator)
    handlers = mediaChannelHandlers

    _connectionTimer = ConnectionTimer(
      monitors: [
        .signalingChannel(signalingChannel),
        // 同一 init 内で初期化済みのため安全
        // swiftlint:disable:next force_unwrapping
        .peerChannel(_peerChannel!),
      ],
      timeout: snapshot.connectionTimeout)
  }

  deinit {
    videoSourceCoordinator.revoke()
    // 明示切断を経由せずに最終参照が解放された場合も、通常切断と同じ所有リソースを破棄する。
    // 各処理は冪等なため、通常切断後の deinit から重複して呼ばれても安全である。
    prepareForDisconnect(error: nil)

    // Sora と利用者の双方が参照を解放した場合も、接続中の PeerChannel を明示的に閉じる。
    // 実処理が進行中なら PeerChannel の接続ライフサイクルの排他が安全な時点まで切断を遅延する。
    _peerChannel?.disconnect(error: nil, reason: .user)
  }

  /// ADM を生成する前に、ステレオ音声出力の組み合わせ制約を検証します。
  static func validate(snapshot: ConnectionConfigurationSnapshot) throws {
    guard snapshot.audioStereoOutputEnabled else {
      return
    }
    guard snapshot.audioEnabled else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled requires audioEnabled to be true")
    }
    guard snapshot.audioCodec != .pcmu else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled does not support PCMU")
    }
    guard !snapshot.usesCustomAudioDevice else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled cannot be used with a custom audio device")
    }
  }

  // MARK: - RPC

  /// RPC メソッドを型安全に呼び出します
  ///
  /// このメソッドを使用して、Sora サーバーで定義された RPC メソッドを非同期で実行できます。
  /// - Parameters:
  ///   - method: 呼び出す RPC メソッドの型 (例: `RequestSimulcastRid.self`)
  ///   - params: メソッドに渡すパラメータ。型安全に検証されます
  ///   - isNotificationRequest: `true` の場合、送信後に Sora からのレスポンスを待ちません。デフォルトは `false`
  ///   - timeout: レスポンスを待つ最大時間（秒）。デフォルトは 5.0 秒
  ///
  /// - Returns: メソッドの実行結果。isNotificationRequest が true の場合は nil を返します
  ///
  /// actor 境界や `Task` の `@Sendable` closure へ結果を渡す場合は、
  /// `sendableRPC(method:params:isNotificationRequest:timeout:)` を使用してください。
  ///
  /// - Throws: 以下のエラーが発生することがあります
  ///   - `SoraError.rpcUnavailable`: RPC チャネルが利用不可
  ///   - `SoraError.rpcEncodingError`: パラメータのエンコーディングに失敗した
  ///   - `SoraError.rpcDecodingError`: レスポンスのデコーディングに失敗した
  ///   - `SoraError.rpcDataChannelClosed`: RPC の送受信に利用する DataChannel が切断された
  ///   - `SoraError.rpcTimeout`: レスポンスがタイムアウト時間内に返されなかった
  ///   - `SoraError.rpcServerError`: Sora からエラーレスポンスがあった (詳細は `RPCErrorDetail`、追加情報は `JSONValue?` の `data`)
  ///   - `CancellationError`: タスクがキャンセルされた
  ///
  /// # 使用例
  /// ```swift
  /// do {
  ///   let response = try await mediaChannel.rpc(
  ///     method: RequestSimulcastRid.self,
  ///     params: RequestSimulcastRidParams(rid: "r0")
  ///   )
  ///
  ///   if let result = response?.result {
  ///     print("Channel ID: \(result.channelId)")
  ///   }
  /// } catch {
  ///   print("RPC call failed: \(error)")
  /// }
  /// ```
  public func rpc<M: RPCMethodProtocol>(
    method: M.Type,
    params: M.Params,
    isNotificationRequest: Bool = false,
    timeout: TimeInterval = 5.0
  ) async throws -> RPCResponse<M.Result>? {
    let response = try await performRPC(
      methodName: method.name,
      params: params,
      isNotificationRequest: isNotificationRequest,
      timeout: timeout)
    guard let response else {
      return nil
    }
    return try decodeRPCResponse(response, as: M.Result.self)
  }

  /// `rpc(method:params:isNotificationRequest:timeout:)` と同じ挙動で、Swift 6 言語モードの検査に対応した RPC メソッドを型安全に呼び出します
  ///
  /// 引数の意味、戻り値の意味 (notification では `nil` が返ること)、返るエラー、タスクキャンセルと
  /// response / timeout / DataChannel 切断が競合した場合の pending の終端は `rpc` と共通です
  /// (引数とエラーの詳細は `rpc(method:params:isNotificationRequest:timeout:)` を参照してください)。
  /// 違うのは、`SendableRPCMethodProtocol` に準拠したメソッドだけを呼べる点と、戻り値が
  /// `SendableRPCResponse<M.Result>?` になる点です。params と result が `Sendable` であるため、
  /// 戻り値は actor 境界や `Task` の `@Sendable` closure を越えて受け渡せます。
  ///
  /// 新旧両方の protocol へ準拠した型でも、`rpc` の戻り値は `RPCResponse<M.Result>?` のままです
  /// (別名の API のため overload の解決先が変わりません)。
  ///
  /// # 使用例
  /// ```swift
  /// do {
  ///   let response = try await mediaChannel.sendableRPC(
  ///     method: RequestSimulcastRid.self,
  ///     params: RequestSimulcastRidParams(rid: "r0")
  ///   )
  ///
  ///   if let result = response?.result {
  ///     print("Channel ID: \(result.channelId)")
  ///   }
  /// } catch {
  ///   print("RPC call failed: \(error)")
  /// }
  /// ```
  public func sendableRPC<M: SendableRPCMethodProtocol>(
    method: M.Type,
    params: M.Params,
    isNotificationRequest: Bool = false,
    timeout: TimeInterval = 5.0
  ) async throws -> SendableRPCResponse<M.Result>? {
    let response = try await performRPC(
      methodName: method.name,
      params: params,
      isNotificationRequest: isNotificationRequest,
      timeout: timeout)
    guard let response else {
      return nil
    }
    return try decodeSendableRPCResponse(response, as: M.Result.self)
  }

  /// `rpc` と `sendableRPC` で共通の RPC 送受信を行う。
  ///
  /// pending の終端は `RPCChannel` に委ね、タスクキャンセルは `CancelledRPCIDStore` へ登録した
  /// RPC ID を `RPCChannel.cancel(identifier:)` へ渡して行う。新しい終端機構は追加しない。
  private func performRPC(
    methodName: String,
    params: Encodable,
    isNotificationRequest: Bool,
    timeout: TimeInterval
  ) async throws -> RPCRawResponse? {
    // タスクキャンセル時に rpcChannel へ通知するための RPC ID を保持する。
    // (withTaskCancellationHandler の onCancel は別スレッドから呼ばれるため、
    // ロックで保護して共有する)
    let cancelledRPCID = CancelledRPCIDStore()
    let rpcChannel = self.peerChannel.rpcChannel
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<RPCRawResponse?, Error>) in
          guard let rpcChannel else {
            continuation.resume(
              throwing: SoraError.rpcUnavailable(reason: "rpc channel is not available"))
            return
          }
          let id = rpcChannel.call(
            methodName: methodName,
            params: params,
            isNotificationRequest: isNotificationRequest,
            timeout: timeout
          ) { result in
            switch result {
            case .success(let response):
              continuation.resume(returning: response)
            case .failure(let error):
              continuation.resume(throwing: error)
            }
          }
          // call が失敗 (nil を返す) した場合は完了済みのため何もしない
          guard let id else {
            return
          }
          // キャンセル済みのタスクによって登録された RPC は即時にキャンセルする。
          // (onCancel が id の確定前に実行された場合も、ここで検出できる)
          cancelledRPCID.set(id)
          if Task.isCancelled {
            rpcChannel.cancel(identifier: id)
          }
        }
      },
      onCancel: {
        // キャンセルされた場合は、対応する RPC をキャンセルして pending を終端する
        // (RPCChannel が解放済みの場合は invalidate() で全 pending が終端済み)
        if let id = cancelledRPCID.get() {
          rpcChannel?.cancel(identifier: id)
        }
      })
  }

  /// `Data` として受け取った result を decode して `RPCResponse` を組み立てる。
  private func decodeRPCResponse<T: Decodable>(
    _ response: RPCRawResponse,
    as type: T.Type
  ) throws -> RPCResponse<T> {
    RPCResponse<T>(id: response.id, result: try decodeRPCResult(response.result, as: T.self))
  }

  /// `Data` として受け取った result を decode して `SendableRPCResponse` を組み立てる。
  ///
  /// response が運ぶ JSON の result は `RPCChannel.handleMessage` の同期区間で
  /// immutable な `Data` へ変換済みである。ここでは executor 境界を越えた先で decode する。
  /// `SendableRPCResponse` 自身は `Result: Sendable` だけを要求するが、decode には
  /// `M.Result: Decodable` (`RPCMethodProtocol` の制約) が必要になる。
  private func decodeSendableRPCResponse<T: Decodable & Sendable>(
    _ response: RPCRawResponse,
    as type: T.Type
  ) throws -> SendableRPCResponse<T> {
    SendableRPCResponse<T>(
      id: response.id, result: try decodeRPCResult(response.result, as: T.self))
  }

  /// `Data` の JSON を `Decodable` な型へ decode する。
  ///
  /// 失敗は decode 層の error をそのまま返さず、`SoraError.rpcDecodingError` へ写して
  /// 呼び出し元へ返す (decode 層の error 型を公開 API の契約に含めないため)。
  private func decodeRPCResult<T: Decodable>(_ result: Data, as type: T.Type) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: result)
    } catch {
      throw SoraError.rpcDecodingError(reason: error.localizedDescription)
    }
  }

  // MARK: - 接続

  private var _handler: ((_ error: Error?) -> Void)?

  /// サーバーに接続します。
  ///
  /// - parameter webRTCConfiguration: WebRTC の設定。接続処理はこの引数を使わず、
  ///   接続開始時の snapshot から設定を読む (公開引数の扱いは別途整理する)
  /// - parameter handler: 接続試行後に呼ばれるクロージャー
  /// - parameter error: (接続失敗時) エラー
  func connect(
    webRTCConfiguration: WebRTCConfiguration,
    onPrepared: (() -> Void)? = nil,
    handler: @escaping (_ error: Error?) -> Void
  ) -> ConnectionTask {
    let task = ConnectionTask()
    let peerChannel = self.peerChannel
    connectionLifecycleLock.lock()
    guard state == .disconnected, !hasStartedConnection else {
      connectionLifecycleLock.unlock()
      handler(
        SoraError.connectionBusy(
          reason:
            "MediaChannel is already connected"))
      logConnectionTaskCompleted(task.complete())
      return task
    }

    // 非同期処理を開始する前に接続試行を予約する。これにより、連続した connect と
    // 戻り値に対する即時 cancel のどちらも一意な接続試行へ結び付く。
    _handler = handler
    currentConnectionTask = task
    hasStartedConnection = true
    connectionTimerAuthorization.authorizeConnection()
    disconnectStartedWhileConnecting = false
    disconnectPreparation = MediaChannelDisconnectPreparation()
    disconnectFinished = false

    // ConnectionTask を返す前に切断完了ハンドラーを登録する。戻り値に対する即時 cancel や
    // MediaChannel.disconnect が、非同期 basicConnect の開始前に完了しても通知を失わない。
    signalingChannel.internalHandlers.onDisconnect = {
      [weak self, weak peerChannel] error, reason in
      if let self {
        self.beginDisconnect(error: error, reason: reason)
      } else {
        peerChannel?.disconnect(error: error, reason: reason)
      }
    }
    peerChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
      // MediaChannel が先に解放されても ConnectionTask は必ず終端させる。
      guard let self else {
        // 完了ログは排他区間の外で出す (この経路は lock を保持していない)。
        if task.complete() {
          Logger.debug(type: .mediaChannel, message: "connection task completed")
        }
        return
      }
      self.finishDisconnect(connectionTask: task, error: error, reason: reason)
    }

    // `.connecting` を公開する前に切断完了ハンドラーを登録する。
    // これにより、別スレッドの disconnect が通知登録の隙間へ入ることを防ぐ。
    let connectingChange = (from: state, to: ConnectionState.connecting)
    setState(.connecting)
    connectionStartTime = nil
    connectionLifecycleLock.unlock()

    // 状態遷移ログは connectionLifecycleLock の外で出す。
    logStateChange(from: connectingChange.from, to: connectingChange.to)

    // 接続開始を予約して `.connecting` を公開した後に、Sora の管理対象へ登録する。
    // onAddMediaChannel から同期的に disconnect されても、後続の basicConnect は
    // 接続試行が終端済みであることを確認してシグナリングを開始しない。
    onPrepared?()

    // 非同期 hop へ渡すのは、MediaChannel を弱参照する box と ConnectionTask を保持する
    // 用途限定の box だけにする。MediaChannel / ConnectionTask を直接捕捉すると
    // DispatchQueue の block が @Sendable として取り込むため診断が出る。
    // 呼び出す basicConnect も、参照する状態の所有と同期は接続ライフサイクルの排他に閉じる。
    let weakSelf = WeakMediaChannelBox(self)
    let taskBox = MediaChannelConnectionTaskBox(task)
    DispatchQueue.global().async { [weakSelf, taskBox] in
      // basicConnect は接続設定を snapshot から読む。webRTCConfiguration は既存テストの
      // 呼び出し互換のために受け取るだけで、接続処理では使わない。
      weakSelf.value?.basicConnect(connectionTask: taskBox.value)
    }
    return task
  }

  private func basicConnect(connectionTask: ConnectionTask) {
    Logger.debug(type: .mediaChannel, message: "try connecting")

    let peerChannel = self.peerChannel

    // 接続開始前にキャンセル要求を受領していた場合は、接続処理を開始しない。
    // attach は peerChannel の設定とキャンセル要求の確認を同じ排他領域で行う。
    guard connectionTask.attach(peerChannel: peerChannel) else {
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      connectionTask.markCanceled()
      // 通常の接続失敗と同じく切断フローで後始末する。
      // これにより接続エラー通知と mediaChannel の
      // remove (Sora.connect が設定した internalHandlers.onDisconnectLegacy) が行われる
      beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }

    peerChannel.internalHandlers.onAddStream = { [weak self] stream in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "added a stream")
      Logger.debug(type: .mediaChannel, message: "call onAddStream")
      weakSelf.internalHandlers.onAddStream?(stream)
      weakSelf.handlers.onAddStream?(stream)
    }

    peerChannel.internalHandlers.onRemoveStream = { [weak self] stream in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "removed a stream")
      Logger.debug(type: .mediaChannel, message: "call onRemoveStream")
      weakSelf.internalHandlers.onRemoveStream?(stream)
      weakSelf.handlers.onRemoveStream?(stream)
    }

    peerChannel.internalHandlers.onOpenDataChannel = { [weak self] label in
      guard let weakSelf = self else {
        return
      }

      // 状態の更新と発火判定はロックで排他し、ハンドラ呼び出しはロックの外で行う
      // (ユーザーコードがロックを保持したまま実行されないようにする)。
      weakSelf.dataChannelOpenLock.lock()
      // onDataChannelOpened はラベルごとに 1 回だけ発火する
      let isFirstOpen = weakSelf.openedDataChannelLabels.insert(label).inserted
      var shouldNotifyBatch = false
      // メッセージング用ラベル（# 始まり）の DataChannel がすべて OPEN になった時点で
      // onDataChannel を一括通知する
      if label.hasPrefix("#") {
        shouldNotifyBatch = weakSelf.shouldNotifyDataChannelAvailableLocked()
      }
      weakSelf.dataChannelOpenLock.unlock()

      if isFirstOpen {
        Logger.debug(type: .mediaChannel, message: "call onDataChannelOpened")
        weakSelf.handlers.onDataChannelOpened?(weakSelf, label)
      }
      if shouldNotifyBatch {
        Logger.debug(type: .mediaChannel, message: "call onDataChannel")
        weakSelf.handlers.onDataChannel?(weakSelf)
      }
    }

    peerChannel.internalHandlers.onReceiveSignalingJSON = { [weak self] json in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "receive signaling json")
      Logger.debug(type: .mediaChannel, message: "call onReceiveSignalingJSON")
      weakSelf.internalHandlers.onReceiveSignalingJSON?(json)
      weakSelf.handlers.onReceiveSignalingJSON?(json)
    }

    peerChannel.internalHandlers.onReceiveSignaling = { [weak self] message in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "receive signaling")
      switch message {
      case .notify(let message):
        // connectionCount, channelRecvonlyConnections, channelSendonlyConnections, channelSendrecvConnections
        // 全てに値が入っていた時のみプロパティを更新する
        if let connectionCount = message.connectionCount,
          let sendonlyConnections = message.channelSendonlyConnections,
          let recvonlyConnections = message.channelRecvonlyConnections,
          let sendrecvConnections = message.channelSendrecvConnections
        {
          weakSelf.publisherCount = sendonlyConnections + sendrecvConnections
          weakSelf.subscriberCount = recvonlyConnections + sendrecvConnections
          weakSelf.connectionCount = connectionCount
        } else {
        }
      default:
        break
      }

      Logger.debug(type: .mediaChannel, message: "call onReceiveSignaling")
      weakSelf.internalHandlers.onReceiveSignaling?(message)
      weakSelf.handlers.onReceiveSignaling?(message)
    }

    // タイマーの開始と接続試行の有効性確認を、切断状態の遷移と同じロックで直列化する。
    // これにより、切断完了後に遅れてタイマーを再始動する競合を防ぐ。
    connectionLifecycleLock.lock()
    guard state == .connecting, currentConnectionTask === connectionTask,
      connectionTask.state == .connecting,
      connectionTimerAuthorization.beginTimer()
    else {
      connectionLifecycleLock.unlock()
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      if connectionTask.state == .canceled {
        connectionTask.markCanceled()
        beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      }
      return
    }

    connectionStartTime = Date()
    let timeout = connectionTimer.run {
      Logger.error(type: .mediaChannel, message: "connection timeout")
      self.beginDisconnect(error: SoraError.connectionTimeout, reason: .signalingFailure)
    }
    connectionLifecycleLock.unlock()

    // Timer 開始ログは connectionLifecycleLock の外で出す (run() が返した有効な timeout を使う)。
    Logger.debug(type: .connectionTimer, message: "run (timeout: \(timeout) seconds)")

    peerChannel.connect { [weak self] error in
      guard let self else {
        return
      }

      // 成否にかかわらず PeerChannel の終端通知を受けた時点でタイマーを止める。
      self.connectionTimer.stop()
      if let error {
        Logger.error(type: .mediaChannel, message: "failed to connect")
        self.beginDisconnect(error: error, reason: .signalingFailure)
        return
      }

      self.finishConnect(connectionTask: connectionTask)
    }
  }

  /// PeerChannel の接続成功を、cancel や切断開始と競合しないよう確定します。
  private func finishConnect(connectionTask: ConnectionTask) {
    var connectHandler: ((Error?) -> Void)?
    var shouldCancel = false
    var completedConnectionTask = false
    var connectedChange: (from: ConnectionState, to: ConnectionState)?

    connectionLifecycleLock.lock()
    if state == .connecting, currentConnectionTask === connectionTask {
      if connectionTask.tryComplete() {
        connectionTimerAuthorization.terminate()
        connectedChange = (from: state, to: ConnectionState.connected)
        setState(.connected)
        completedConnectionTask = true
        connectHandler = _handler
        _handler = nil
        currentConnectionTask = nil
      } else {
        // ConnectionTask.cancel() が先に終端状態を確定している。
        shouldCancel = true
      }
    }
    connectionLifecycleLock.unlock()

    // 完了ログ → 遷移ログの順で、排他区間の外で出す (変更前の同一スレッドでの出力順序を維持する)。
    logConnectionTaskCompleted(completedConnectionTask)
    if let connectedChange {
      logStateChange(from: connectedChange.from, to: connectedChange.to)
    }

    connectionTimer.stop()

    if shouldCancel {
      connectionTask.markCanceled()
      beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }
    guard let connectHandler else {
      return
    }

    Logger.debug(type: .mediaChannel, message: "did connect")
    connectHandler(nil)
    Logger.debug(type: .mediaChannel, message: "call onConnect")
    internalHandlers.onConnect?(nil)
    handlers.onConnect?(nil)
  }

  /// 接続を解除します。
  ///
  /// - parameter error: 接続解除の原因となったエラー
  public func disconnect(error: Error?) {
    // reason に .user を指定しているので、 disconnect は SDK 内部では利用しない
    beginDisconnect(error: error, reason: .user)
  }

  func internalDisconnect(error: Error?, reason: DisconnectReason) {
    beginDisconnect(error: error, reason: reason)
  }

  /// 切断開始を 1 回だけ確定し、PeerChannel へ切断を要求します。
  ///
  /// 公開ハンドラーと `.disconnected` への遷移は、PeerChannel が native close と
  /// AudioSession lease の解放を終えた後の `finishDisconnect` で実行します。
  private func beginDisconnect(error: Error?, reason: DisconnectReason) {
    var shouldPrepare = false
    var completedConnectionTask = false
    var disconnectingChange: (from: ConnectionState, to: ConnectionState)?

    connectionLifecycleLock.lock()
    switch state {
    case .connecting, .connected:
      disconnectStartedWhileConnecting = state == .connecting
      connectionTimerAuthorization.terminate()
      if disconnectStartedWhileConnecting {
        // 接続試行をここで seal し、遅延切断中の cancel が切断理由を上書きしないようにする。
        completedConnectionTask = currentConnectionTask?.complete() ?? false
      }
      disconnectingChange = (from: state, to: ConnectionState.disconnecting)
      setState(.disconnecting)
      if disconnectPreparation.begin() {
        shouldPrepare = true
      }
    case .disconnecting, .disconnected:
      break
    }
    connectionLifecycleLock.unlock()

    // 完了ログ → 遷移ログの順で、排他区間の外で出す (変更前の同一スレッドでの出力順序を維持する)。
    logConnectionTaskCompleted(completedConnectionTask)
    if let disconnectingChange {
      logStateChange(from: disconnectingChange.from, to: disconnectingChange.to)
    }

    guard shouldPrepare else {
      return
    }

    startDisconnectPreparation(error: error)
    peerChannel.disconnect(error: error, reason: reason)
  }

  /// PeerChannel の実切断完了後に状態と公開ハンドラーを 1 回だけ終端します。
  private func finishDisconnect(
    connectionTask: ConnectionTask,
    error: Error?,
    reason: DisconnectReason
  ) {
    var shouldPrepare = false
    var shouldNotifyConnect = false
    var connectHandler: ((Error?) -> Void)?
    var disconnectingChange: (from: ConnectionState, to: ConnectionState)?
    var disconnectedChange: (from: ConnectionState, to: ConnectionState)?

    connectionLifecycleLock.lock()
    guard !disconnectFinished else {
      connectionLifecycleLock.unlock()
      logConnectionTaskCompleted(connectionTask.complete())
      return
    }

    // ConnectionTask.cancel() は PeerChannel を直接切断するため、MediaChannel 側で
    // beginDisconnect を経由せずに完了通知へ到達する場合がある。
    if state == .connecting || state == .connected {
      disconnectStartedWhileConnecting = state == .connecting
      connectionTimerAuthorization.terminate()
      disconnectingChange = (from: state, to: ConnectionState.disconnecting)
      setState(.disconnecting)
    }
    guard state == .disconnecting else {
      connectionLifecycleLock.unlock()
      logConnectionTaskCompleted(connectionTask.complete())
      return
    }

    let completion = MediaChannelDisconnectPreparation.Completion(
      connectionTask: connectionTask,
      error: error,
      reason: reason)
    switch disconnectPreparation.receive(completion) {
    case .prepare:
      shouldPrepare = true
    case .deferred:
      // PeerChannel の cleanup は完了済みでも、MediaChannel 固有の準備が終わるまでは
      // `.disconnected` と公開 callback を通知しない。
      // この経路は `beginDisconnect` が準備を開始済みの場合だけ成立するため、`.disconnecting` の
      // 遷移ログは `beginDisconnect` が既に出している (ここで出すものは無い)。
      connectionLifecycleLock.unlock()
      return
    case .ready:
      break
    }

    if shouldPrepare {
      connectionLifecycleLock.unlock()
      if let disconnectingChange {
        logStateChange(from: disconnectingChange.from, to: disconnectingChange.to)
      }
      startDisconnectPreparation(error: error)
      return
    }

    disconnectFinished = true
    shouldNotifyConnect = disconnectStartedWhileConnecting
    if shouldNotifyConnect {
      connectHandler = _handler
    }
    _handler = nil
    currentConnectionTask = nil
    disconnectedChange = (from: state, to: ConnectionState.disconnected)
    setState(.disconnected)
    connectionLifecycleLock.unlock()

    // 遷移ログ → 完了ログの順で、排他区間の外で出す (変更前の同一スレッドでの出力順序を維持する)。
    if let disconnectingChange {
      logStateChange(from: disconnectingChange.from, to: disconnectingChange.to)
    }
    if let disconnectedChange {
      logStateChange(from: disconnectedChange.from, to: disconnectedChange.to)
    }

    // 利用者ハンドラーから観測した時点で ConnectionTask が必ず終端しているようにする。
    logConnectionTaskCompleted(connectionTask.complete())

    if shouldNotifyConnect {
      // 正常切断でも接続自体は未成立なので、接続結果は取消として通知します。
      let connectionError = error ?? SoraError.connectionCancelled
      connectHandler?(connectionError)
      Logger.debug(type: .mediaChannel, message: "call onConnect")
      internalHandlers.onConnect?(connectionError)
      handlers.onConnect?(connectionError)
    }

    Logger.debug(type: .mediaChannel, message: "did disconnect")
    Logger.debug(type: .mediaChannel, message: "call onDisconnect")
    internalHandlers.onDisconnectLegacy?(error)
    handlers.onDisconnectLegacy?(error)
    handlers.onDisconnect?(makeDisconnectEvent(error: error))
  }

  /// 切断準備を完了状態へ進め、準備中に保留された PeerChannel の完了通知を処理します。
  private func completeDisconnectPreparation() {
    let completion: MediaChannelDisconnectPreparation.Completion?

    connectionLifecycleLock.lock()
    completion = disconnectPreparation.complete()
    connectionLifecycleLock.unlock()

    if let completion {
      finishDisconnect(
        connectionTask: completion.connectionTask,
        error: completion.error,
        reason: completion.reason)
    }
  }

  /// MediaChannel 固有の cleanup が完了した後に、切断準備を完了状態へ進めます。
  private func startDisconnectPreparation(error: Error?) {
    let cleanupTask = prepareForDisconnect(error: error)
    let weakSelf = WeakMediaChannelBox(self)
    Task { @Sendable in
      await cleanupTask.value
      weakSelf.value?.completeDisconnectPreparation()
    }
  }

  /// MediaChannel が所有するタイマー、画面キャプチャ、ハードミュート状態を停止します。
  /// 戻り値の Task は、画面共有停止と映像ハードミュート lease の破棄完了を表します。
  @discardableResult
  private func prepareForDisconnect(error: Error?) -> Task<Void, Never> {
    // 進行中のハードミュート解除がカメラ開始後に必ず取消を検知できるよう、
    // Actor の cleanup Task を生成する前に lease を同期的に無効化する。
    videoHardMuteLease.revoke()
    // 非同期のカメラ / 画面共有開始が遅れて完了しても、新しい送信元として確定させない。
    videoSourceCoordinator.revoke()

    // 接続の終了時に画面キャプチャを停止します。
    // 論理停止は同期的に確定し、ReplayKit の停止完了を公開 callback より前に待ちます。
    // スクリーンキャプチャ未使用時はインスタンス未生成のため何もしません。
    let screenCaptureController = currentScreenCaptureController()
    let screenStopReservation = videoSourceCoordinator.beginScreenStop()
    let screenCaptureStopTask = screenCaptureController?.stopCaptureForDisconnect()
    let videoSourceCoordinator = videoSourceCoordinator

    // 接続切断時に、この接続が保存したハードミュートの capturer を破棄します。
    // (別接続がこの接続の capturer を取得しないようにするため)
    let hardMuteLease = videoHardMuteLease
    let hardMuteCleanupTask = Task { @Sendable in
      await Self.videoHardMuteActor.release(lease: hardMuteLease)
    }
    let cleanupTask = Task { @Sendable in
      await screenCaptureStopTask?.value
      if let screenStopReservation {
        videoSourceCoordinator.finishScreenStop(
          screenStopReservation,
          stopped: screenCaptureController?.isCaptureActive() != true)
      }
      await hardMuteCleanupTask.value
    }

    Logger.debug(type: .mediaChannel, message: "try disconnecting")
    if let error {
      Logger.error(
        type: .mediaChannel,
        message: "error: \(error.localizedDescription)")
    }
    connectionTimer.stop()
    return cleanupTask
  }

  /// 切断エラーを公開 SoraCloseEvent へ変換します。
  private func makeDisconnectEvent(error: Error?) -> SoraCloseEvent {
    guard let error else {
      return SoraCloseEvent.ok(code: 1000, reason: "NO-ERROR")
    }
    if let soraError = error as? SoraError {
      switch soraError {
      case .webSocketClosed(let code, let reason):
        // 基本的に reason が nil になるケースはないが、nil の場合は空文字列とする。
        return SoraCloseEvent.ok(code: code.intValue(), reason: reason ?? "")
      case .dataChannelClosed(let code, let reason):
        return SoraCloseEvent.ok(code: code, reason: reason)
      default:
        return SoraCloseEvent.error(error)
      }
    }
    return SoraCloseEvent.error(error)
  }

  /// libwebrtc の統計情報を取得します。
  /// 非同期取得中に切断された場合でも安全になるよう、コールバック内で
  /// チャンネルの生存確認、state == .connected の再確認、peerChannel.nativeChannel が
  /// 同一インスタンスかどうか、をチェックしています。
  ///
  /// - parameter handler: 統計情報取得後に呼ばれるクロージャー
  public func getStats(handler: @escaping (Result<Statistics, Error>) -> Void) {
    guard state == .connected else {
      let message = "MediaChannel is not connected (state: \(state))"
      Logger.debug(type: .mediaChannel, message: message)
      handler(.failure(SoraError.peerChannelError(reason: message)))
      return
    }

    guard let peerConnection = peerChannel.nativeChannel else {
      let message =
        "RTCPeerConnection is unavailable (state: \(state), nativeChannel: nil)"
      Logger.debug(type: .mediaChannel, message: message)
      handler(.failure(SoraError.peerChannelError(reason: message)))
      return
    }

    // peerConnection.statistics クロージャは libwebrtc 側のスレッドから遅れて呼ばれ、変更前は
    // 内部で MediaChannel を捕捉していた。self を強参照すると、MediaChannel が切断・解放された
    // あとでもクロージャが解放されず、deinit が遅れたり循環参照が発生する恐れがある。
    //
    // handler は公開 API のため `@Sendable` にできず、peerConnection は `Sendable` ではない。
    // MediaChannel の state と peerChannel.nativeChannel も完了 closure から直接読めないため、
    // これらを不変の参照保持 box (MediaChannelGetStatsContext) へ移し、クロージャには
    // box (Sendable) だけを capture させる。
    //
    // state は MediaChannelStateStorage (NSLock) 経由で読み、nativeChannel の同一性判定は
    // PeerChannelTransportStorage (NSLock) の参照で行う。transportStorage を弱参照で持つことで、
    // 変更前の [weak self] と同じく解放済みのチャンネルへは 1 回だけ失敗を返して終端する。
    let context = MediaChannelGetStatsContext(
      handler: handler,
      peerConnection: peerConnection,
      stateStorage: stateStorage,
      transportStorage: peerChannel.transportStorage)
    peerConnection.statistics { [context] report in
      // PeerChannel (と MediaChannel) が解放済みである。変更前の [weak self] と同じ経路で、
      // 統計を返さず 1 回だけ失敗を返す。
      guard let transportStorage = context.transportStorage else {
        context.handler(.failure(SoraError.peerChannelError(reason: "MediaChannel is unavailable")))
        return
      }

      // 切断で state が遷移した後は、nativeChannel の参照が残っていても旧接続の統計を
      // 成功として返さない。state は storage の lock 配下で読み、lock は保持しない。
      let state = context.stateStorage.state
      guard state == .connected else {
        let message = "MediaChannel is not connected (state: \(state))"
        Logger.debug(type: .mediaChannel, message: message)
        context.handler(.failure(SoraError.peerChannelError(reason: message)))
        return
      }

      // 参照の取り出しは storage の lock 配下で行い、同一性判定 (`===`) は lock の外で行う。
      guard let currentPeerConnection = transportStorage.native,
        currentPeerConnection === context.peerConnection
      else {
        let message =
          "RTCPeerConnection is unavailable (state: \(state), nativeChannel changed)"
        Logger.debug(type: .mediaChannel, message: message)
        context.handler(.failure(SoraError.peerChannelError(reason: message)))
        return
      }

      context.handler(.success(Statistics(contentsOf: report)))
    }
  }

  /// DataChannel を利用してメッセージを送信します
  public func sendMessage(label: String, data: Data) -> Error? {
    guard peerChannel.switchedToDataChannel else {
      // redirect 中は旧 DataChannel への送信を防ぐため false にしている。
      // 利用者には「まだ指定した DataChannel に接続されていない」として通知する。
      if peerChannel.isRedirecting {
        Logger.debug(
          type: .mediaChannel,
          message: "sendMessage: rejected (redirecting): label => \(label)")
      }
      return SoraError.messagingError(reason: "DataChannel is not open yet")
    }

    guard label.starts(with: "#") else {
      return SoraError.messagingError(reason: "label should start with #")
    }

    guard let dc = peerChannel.dataChannels[label] else {
      return SoraError.messagingError(reason: "no DataChannel found: label => \(label)")
    }

    let readyState = dc.readyState
    guard readyState == .open else {
      return SoraError.messagingError(
        reason:
          "readyState of the DataChannel is not open: label => \(label), readyState => \(WebRTCEnumDescription.dataChannelState(readyState))"
      )
    }

    let result = dc.send(data)

    return result
      ? nil : SoraError.messagingError(reason: "failed to send message: label => \(label)")
  }

  /// メッセージング用ラベル（offer の `data_channels` から抽出した `#` 始まりのラベル）が
  /// すべてクライアント側で OPEN になった場合に `onDataChannel` を発火すべきかを判定します。
  /// 状態を持たない純粋関数であり、単体テストの対象です。
  ///
  /// - Parameters:
  ///   - messagingLabels: offer の `data_channels` から抽出した `#` 始まりのラベル集合
  ///   - openedLabels: クライアント側で OPEN になった DataChannel のラベル集合
  ///     (メッセージング用ラベルは必ず含まれる)
  ///   - notified: 一括通知済みかどうか (`true` の場合は二重発火を防ぐため発火しない)
  /// - Returns: `onDataChannel` を発火すべきか
  static func shouldNotifyDataChannelAvailable(
    messagingLabels: Set<String>,
    openedLabels: Set<String>,
    notified: Bool
  ) -> Bool {
    // 一括通知済みの場合は発火しない (二重発火の防止)
    guard !notified else {
      return false
    }

    // メッセージング用ラベルが存在しない場合は発火しない
    guard !messagingLabels.isEmpty else {
      return false
    }

    // すべてのメッセージング用ラベルが OPEN になった場合のみ発火する
    guard messagingLabels.isSubset(of: openedLabels) else {
      return false
    }

    return true
  }

  /// offer の `data_channels` からメッセージング用ラベル（`#` 始まり）の集合を抽出します。
  /// 状態を持たない純粋関数であり、単体テストの対象です。
  ///
  /// - Parameter dataChannels: offer の `data_channels` の値
  /// - Returns: メッセージング用ラベルの集合 (`label` キーが欠落・非 String の要素は無視)
  static func messagingLabels(from dataChannels: [[String: Any]]) -> Set<String> {
    Set(
      dataChannels.compactMap { $0["label"] as? String }.filter {
        $0.hasPrefix("#")
      })
  }

  /// メッセージング用ラベルがすべてクライアント側で OPEN になった場合に true を返し、
  /// 一括通知済みフラグを立てます。呼び出し元は `dataChannelOpenLock` を保持していること。
  private func shouldNotifyDataChannelAvailableLocked() -> Bool {
    let shouldNotify = Self.shouldNotifyDataChannelAvailable(
      messagingLabels: messagingLabels,
      openedLabels: openedDataChannelLabels,
      notified: onDataChannelNotified)
    if shouldNotify {
      onDataChannelNotified = true
    }
    return shouldNotify
  }

  /// DataChannel の OPEN 追跡状態と一括通知フラグをリセットします。
  /// リダイレクト等で offer が再送された場合に PeerChannel から呼ばれます。
  ///
  /// - Parameter messagingLabels: 新しい offer の `data_channels` から抽出した
  ///   メッセージング用ラベルの集合
  func resetDataChannelNotificationState(messagingLabels: Set<String>) {
    dataChannelOpenLock.lock()
    self.messagingLabels = messagingLabels
    openedDataChannelLabels = []
    onDataChannelNotified = false
    dataChannelOpenLock.unlock()
  }

  /// MediaChannel の接続中にマイクをハードミュート有効化/無効化します
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setAudioHardMute(_ mute: Bool) -> Error? {
    // 接続されていなければエラー
    guard state == .connected else {
      return SoraError.mediaChannelError(
        reason: "MediaChannel is not connected (state: \(state))")
    }

    // 接続設定で音声が有効になっていなければエラー
    guard configuration.audioEnabled else {
      return SoraError.mediaChannelError(reason: "audioEnabled is false")
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return SoraError.mediaChannelError(reason: "role is not sender")
    }

    // 通常経路: RTCAudioDeviceModule のラッパーでハードミュートを切り替える
    if let wrapper = self.nativePeerChannelFactory.audioDeviceModuleWrapper {
      if !wrapper.setAudioHardMute(mute) {
        return SoraError.mediaChannelError(
          reason: "AudioDeviceModuleWrapper::setAudioHardMute failed")
      }
      return nil
    }

    // ダミー音声経路: DummyAudioDevice でハードミュートを切り替える
    if let dummyDevice = self.nativePeerChannelFactory.audioDevice as? DummyAudioDevice {
      if !dummyDevice.setHardMute(mute) {
        return SoraError.mediaChannelError(
          reason: "DummyAudioDevice::setHardMute failed")
      }
      return nil
    }

    return SoraError.mediaChannelError(
      reason: "setAudioHardMute is not supported")
  }

  /// MediaChannel の接続中にマイクをソフトミュート有効化 / 無効化します
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setAudioSoftMute(_ mute: Bool) -> Error? {
    // 接続されていなければエラー
    guard state == .connected else {
      return SoraError.mediaChannelError(
        reason: "MediaChannel is not connected (state: \(state))")
    }

    // 接続設定で音声が有効になっていなければエラー
    guard configuration.audioEnabled else {
      return SoraError.mediaChannelError(reason: "audioEnabled is false")
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return SoraError.mediaChannelError(reason: "role is not sender")
    }

    // 送信ストリームが有効でなければエラー
    guard let senderStream else {
      return SoraError.mediaChannelError(reason: "senderStream is unavailable")
    }

    // ローカル音声トラックが存在しなければエラー
    guard senderStream.hasAudioTrack else {
      return SoraError.mediaChannelError(reason: "senderStream has no AudioTrack")
    }

    // ローカル音声トラックの有効/無効を切り替えます
    senderStream.audioEnabled = !mute
    Logger.debug(type: .mediaChannel, message: "setAudioSoftMute mute=\(mute)")
    return nil
  }

  /// MediaChannel の接続中に映像をソフトミュート有効化 / 無効化します
  /// 黒塗りフレームが送信される状態になります
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setVideoSoftMute(_ mute: Bool) -> Error? {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      return error
    case .success(let stream):
      senderStream = stream
    }

    // ローカル映像トラックの有効/無効を切り替えます
    senderStream.videoEnabled = !mute
    Logger.debug(type: .mediaChannel, message: "setVideoSoftMute mute=\(mute)")
    return nil
  }

  /// MediaChannel の接続中に映像をハードミュート有効化 / 無効化します
  ///
  /// 端末カメラ利用が有効になっている必要があります
  /// 外部入力や別キャプチャ経路には対応していません
  ///
  /// 内部で Actor により、操作を排他実行します。
  /// 同時に呼び出された場合は Actor 側で `SoraError.mediaChannelError` がスローされます
  ///
  /// 映像ハードミュートは、黒塗りフレーム状態で停止させるためローカルトラックの停止を含みます
  /// 事前に映像ソフトミュートを利用していた場合は状態が上書きされます
  /// ハードミュート解除時に直前のソフトミュートの状態を復元するようなことはしません
  ///
  /// ハードミュート有効化に失敗した場合は、呼び出し前の `senderStream.videoEnabled` を復元します。
  /// ただし操作が取り消された場合は復元せず、黒塗り (ソフトミュート) のまま終了します。
  /// 切断の開始と同時に失敗した場合は復元されることがあります。
  /// 復元する値はこの操作が実行を開始した時点の値であり、並行する `setVideoSoftMute` や
  /// `MediaStream.videoEnabled` への直接代入とは排他されません。
  /// 操作の実行中や設定前の取消により拒否された場合は `videoEnabled` を変更しません。
  ///
  /// `senderStream.videoEnabled` の setter は値が変化したときだけ利用者 handler と
  /// `VideoRenderer` を呼びます。呼び出し前が有効な場合は、成功時に `onSwitchVideo(false)` が 1 回、
  /// 復元する失敗時に `onSwitchVideo(false)` と `onSwitchVideo(true)` がこの順に 1 回ずつ発火します。
  /// 有効化の経路ではこれらの handler は `VideoHardMuteActor` の executor で発火します。
  /// これに対し `VideoRenderer.onSwitch(video:)` の配送 executor は main queue であり、
  /// handler と renderer の相対順序は保証されません。
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Throws: エラー時は `SoraError.cameraError` または `SoraError.mediaChannelError` がスローされます
  public func setVideoHardMute(_ mute: Bool) async throws {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      throw error
    case .success(let stream):
      senderStream = stream
    }

    // 接続設定でカメラ利用が有効になっているか
    // 端末カメラではなく別ソース（外部入力や別キャプチャ経路）の場合は false になることがあり、機能としては未対応
    guard configuration.cameraSettings.isEnabled else {
      throw SoraError.mediaChannelError(reason: "cameraSettings.isEnabled is false")
    }

    if mute {
      // 黒塗りの設定は VideoHardMuteActor.setMute 内で行います
      // (所有権を取得できなかった呼び出しが videoEnabled を変更しないようにするため)
      try await Self.videoHardMuteActor.setMute(
        mute: true,
        lease: videoHardMuteLease,
        senderStream: SenderStreamBox(stream: senderStream),
        cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings)
      )
      videoSourceCoordinator.releaseCamera()
    } else {
      guard let reservation = videoSourceCoordinator.beginCamera(stream: senderStream) else {
        throw SoraError.mediaChannelError(
          reason:
            "screen capture is active, stopScreenCapture before setVideoHardMute(false)")
      }

      // ハードミュート無効化 -> ソフトミュートによる黒塗りフレーム送出解除の順になるようにします
      do {
        try await Self.videoHardMuteActor.setMute(
          mute: false,
          lease: videoHardMuteLease,
          senderStream: SenderStreamBox(stream: senderStream),
          cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings),
          cameraStartAuthorization: CameraStartAuthorization(
            reservation: reservation,
            videoSourceCoordinator: videoSourceCoordinator,
            cameraCaptureOwnership: cameraCaptureOwnership)
        )
      } catch {
        videoSourceCoordinator.cancelCamera(reservation)
        throw error
      }
      guard videoSourceCoordinator.isValid(reservation) else {
        videoSourceCoordinator.cancelCamera(reservation)
        throw SoraError.mediaChannelError(
          reason: "video hard mute operation was cancelled")
      }
      senderStream.videoEnabled = true
    }
    Logger.debug(type: .mediaChannel, message: "setVideoHardMute mute=\(mute)")
  }

  /// MediaChannel の接続中に ReplayKit を利用して画面キャプチャおよび映像配信を開始します
  ///
  /// 送信フレームレートは `ScreenCaptureSettings.targetFPS` で制御できます。
  ///
  /// `ScreenCaptureSettings.videoSampleBufferTransformer` は SDK 内部の送信キュー上で呼ばれます。
  /// `targetFPS` による間引きで破棄されるフレームと、送信処理中のために破棄されるフレーム、
  /// キャプチャ停止中と切断中のフレームでは呼ばれません。引数と戻り値の `CMSampleBuffer` の
  /// 所有権は SDK に委ねられ、戻り値の pixel buffer は送信のために SDK が retain します。
  /// 戻り値を返した後にその buffer を書き換えないでください。
  ///
  /// 同一 senderStream に対してカメラキャプチャが動作中の場合は開始できません。
  /// 接続前に `Configuration.initialCameraEnabled = false` を設定してください。
  /// 接続後にカメラを停止する場合は `setVideoHardMute(true)` を先に呼んでください。
  ///
  /// - Parameter settings: 画面キャプチャ設定
  /// - Throws: エラー時は `SoraError.mediaChannelError` または ReplayKit 起因のエラーがスローされます
  public func startScreenCapture(settings: ScreenCaptureSettings = .init()) async throws {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      throw error
    case .success(let stream):
      senderStream = stream
    }

    // controller を最初の await より前に保持し、並行する停止または切断が
    // 遅延中の開始を必ず取り消せるようにする。
    let screenCaptureController = getOrCreateScreenCaptureController()
    guard let reservation = videoSourceCoordinator.beginScreen(stream: senderStream) else {
      throw SoraError.mediaChannelError(
        reason:
          "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
      )
    }

    do {
      // 公開 API から直接開始されたカメラも確認し、同じ送信ストリームでの二重送信を防ぐ。
      guard
        !(await isCameraVideoCaptureRunning(
          on: senderStream,
          authorization: reservation))
      else {
        throw SoraError.mediaChannelError(
          reason:
            "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
        )
      }

      try await screenCaptureController.startCapture(
        settings: settings,
        senderStream: senderStream,
        authorization: reservation,
        videoSourceCoordinator: videoSourceCoordinator
      )
      guard videoSourceCoordinator.completeScreenStart(reservation) else {
        throw SoraError.mediaChannelError(reason: "screen capture start was cancelled")
      }
    } catch {
      // この開始世代が現在も所有者である場合だけ cleanup する。
      // すでに停止または次世代へ移った場合は、その世代の停止処理へ任せる。
      if let screenStopReservation = videoSourceCoordinator.beginScreenStop(for: reservation) {
        await screenCaptureController.stopCapture()
        videoSourceCoordinator.finishScreenStop(
          screenStopReservation,
          stopped: !screenCaptureController.isCaptureActive())
      } else {
        videoSourceCoordinator.failScreenStart(reservation)
      }
      throw error
    }
    Logger.debug(type: .mediaChannel, message: "startScreenCapture")
  }

  /// ReplayKit を利用した画面キャプチャを停止します
  public func stopScreenCapture() async {
    let screenStopReservation = videoSourceCoordinator.beginScreenStop()
    let screenCaptureController = currentScreenCaptureController()
    await screenCaptureController?.stopCapture()
    if let screenStopReservation {
      videoSourceCoordinator.finishScreenStop(
        screenStopReservation,
        stopped: screenCaptureController?.isCaptureActive() != true)
    }
    Logger.debug(type: .mediaChannel, message: "stopScreenCapture")
  }

  /// 画面キャプチャが動作中かを取得します
  public func isScreenCaptureActive() -> Bool {
    currentScreenCaptureController()?.isCaptureActive() ?? false
  }

  // screenCaptureController インスタンスを取得します
  // インスタンス未生成の場合は生成します
  // スクリーンキャプチャ機能は必ず利用するとは限らないため必要時に生成しています
  func getOrCreateScreenCaptureController(
    recorderCoordinator: ScreenCaptureRecorderCoordinator = .shared
  ) -> ScreenCaptureController {
    withScreenCaptureControllerLock {
      if let screenCaptureController {
        return screenCaptureController
      }

      let screenCaptureController = ScreenCaptureController(
        mediaChannel: self,
        recorderCoordinator: recorderCoordinator)
      self.screenCaptureController = screenCaptureController
      return screenCaptureController
    }
  }

  // Current の ScreenCaptureController を取得します。
  // キャプチャ終了時、切断時に取得するために利用します。
  private func currentScreenCaptureController() -> ScreenCaptureController? {
    withScreenCaptureControllerLock {
      screenCaptureController
    }
  }

  // ScreenCaptureController をロック付きで取得します
  private func withScreenCaptureControllerLock<T>(_ block: () throws -> T) rethrows -> T {
    screenCaptureControllerLock.lock()
    defer { screenCaptureControllerLock.unlock() }
    return try block()
  }

  // 映像ミュートのための接続状況や接続設定のチェックを実行した上で送信ストリームを取得します
  //
  // チェックを全て通過した場合は .success で送信ストリームを返します
  // 問題があった場合は .failure で SoraError.mediaChannelError を返します
  private func requireSenderStreamForVideoMute() -> Result<MediaStream, Error> {
    // 接続されていなければエラー
    guard state == .connected else {
      return .failure(
        SoraError.mediaChannelError(reason: "MediaChannel is not connected (state: \(state))"))
    }

    // 接続設定で映像が有効になっていなければエラー
    guard configuration.videoEnabled else {
      return .failure(SoraError.mediaChannelError(reason: "videoEnabled is false"))
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return .failure(SoraError.mediaChannelError(reason: "role is not sender"))
    }

    // 送信ストリームが有効になっていなければエラー
    guard let senderStream else {
      return .failure(SoraError.mediaChannelError(reason: "senderStream is unavailable"))
    }

    // 送信ストリームに映像トラックが含まれていなければエラー
    guard senderStream.hasVideoTrack else {
      return .failure(SoraError.mediaChannelError(reason: "senderStream has no VideoTrack"))
    }

    return .success(senderStream)
  }

  // 指定した senderStream に対してカメラキャプチャが実行中かを返します
  private func isCameraVideoCaptureRunning(
    on senderStream: MediaStream,
    authorization: VideoSourceCoordinator.Reservation
  ) async -> Bool {
    let videoSourceCoordinator = videoSourceCoordinator
    let senderStream = SenderStreamBox(stream: senderStream)
    return await cameraCaptureCoordinator.perform {
      guard videoSourceCoordinator.isValid(authorization) else {
        return true
      }
      guard let current = CameraVideoCapturer.current,
        current.isRunning,
        let currentSenderStream = current.stream
      else {
        return false
      }
      return currentSenderStream === senderStream.stream
    }
  }
}

extension MediaChannel: CustomStringConvertible {
  /// :nodoc:
  public var description: String {
    "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
  }
}

/// :nodoc:
extension MediaChannel: Equatable {
  public static func == (lhs: MediaChannel, rhs: MediaChannel) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }
}
