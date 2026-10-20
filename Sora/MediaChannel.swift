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
///
/// イベントハンドラのプロパティの get / set は、プロパティごとの `HandlerStorage` が持つ `NSLock` で
/// 排他します。
/// 利用する任意の executor からの設定と、配送する executor からの読み取りが並行しても
/// データ競合しません。配送側は lock を解放してから取得済みの closure を呼ぶため、closure の
/// 中から別の handler を設定しても deadlock しません。設定と配送が競合した場合にどちらの closure が
/// 呼ばれるかは、lock の取得順で決まります (設定が次の配送から反映されるという契約は変わりません)。
///
/// 呼び出し元のスレッドは保証されない。UI 更新や共有状態の変更は main queue / main actor へ
/// 束ねること。
///
/// 配送のたびにプロパティを読むため、接続の途中で設定を変更しても次の配送から反映される
/// (プロパティごとの storage が排他するのは読み書きだけであり、配送側は lock を解放してから
/// 取得済みの closure を呼ぶ)。
///
/// Swift 6 言語モードで `@MainActor` の文脈からハンドラーを設定する場合は、クロージャに
/// `@Sendable` を付けるか `nonisolated` な関数へ処理を分離して隔離を外す。`MediaChannel` /
/// `MediaStream` / `Signaling` は `Sendable` ではないため、main actor へ渡す場合は
/// `nonisolated(unsafe) let` で運び、`Task { @MainActor in ... }` で main actor 上へ移す。
///
/// イベントを actor / Task から購読する場合は
/// `MediaChannel.subscribeEvents(bufferingPolicy:)` を使う。新しい購読 API は、この handler と
/// 同じ配送点から対応するイベントを配送する。
public final class MediaChannelHandlers {
  /// 接続成功時に呼ばれるクロージャー
  public var onConnect: ((Error?) -> Void)? {
    get { onConnectStorage.current }
    set { onConnectStorage.current = newValue }
  }

  /// 接続解除時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message:
      "onDisconnect: ((SoraCloseEvent) -> Void)? に移行してください。onDisconnectLegacy: ((Error?) -> Void)? は、2027 年中に削除予定です。"
  )
  public var onDisconnectLegacy: ((Error?) -> Void)? {
    get { onDisconnectLegacyStorage.current }
    set { onDisconnectLegacyStorage.current = newValue }
  }

  /// 接続解除時に呼ばれるクロージャー
  public var onDisconnect: ((SoraCloseEvent) -> Void)? {
    get { onDisconnectStorage.current }
    set { onDisconnectStorage.current = newValue }
  }

  /// ストリームが追加されたときに呼ばれるクロージャー
  public var onAddStream: ((MediaStream) -> Void)? {
    get { onAddStreamStorage.current }
    set { onAddStreamStorage.current = newValue }
  }

  /// ストリームが除去されたときに呼ばれるクロージャー
  public var onRemoveStream: ((MediaStream) -> Void)? {
    get { onRemoveStreamStorage.current }
    set { onRemoveStreamStorage.current = newValue }
  }

  /// シグナリング受信時に呼ばれるクロージャー。
  /// 引数の `String` には、受信したシグナリングメッセージの JSON 文字列が渡されます。
  public var onReceiveSignalingJSON: ((String) -> Void)? {
    get { onReceiveSignalingJSONStorage.current }
    set { onReceiveSignalingJSONStorage.current = newValue }
  }

  /// シグナリング受信時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message: "JSON 文字列を受け取る onReceiveSignalingJSON へ移行してください。"
  )
  public var onReceiveSignaling: ((Signaling) -> Void)? {
    get { onReceiveSignalingStorage.current }
    set { onReceiveSignalingStorage.current = newValue }
  }

  /// メッセージング用 DataChannel がすべてクライアント側で OPEN になったタイミングで呼ばれるクロージャー。
  /// メッセージング用ラベル（offer の `data_channels` の `#` 始まり）が存在しない場合は発火しない。
  /// この時点ではまだ `type: switched` を受信していない場合があり、
  /// その場合 `sendMessage` は "DataChannel is not open yet" エラーを返す。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannel: ((MediaChannel) -> Void)? {
    get { onDataChannelStorage.current }
    set { onDataChannelStorage.current = newValue }
  }

  /// DataChannel がクライアント側で OPEN になったタイミングで、ラベルごとに 1 回呼ばれるクロージャー。
  /// クライアント側で OPEN になったすべての DataChannel（`#` 始まりのラベルに限定しない）が対象。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannelOpened: ((MediaChannel, String) -> Void)? {
    get { onDataChannelOpenedStorage.current }
    set { onDataChannelOpenedStorage.current = newValue }
  }

  /// DataChannel のメッセージ受信時に呼ばれるクロージャー
  public var onDataChannelMessage: ((MediaChannel, String, Data) -> Void)? {
    get { onDataChannelMessageStorage.current }
    set { onDataChannelMessageStorage.current = newValue }
  }

  /// 初期化します。
  public init() {}

  // MARK: - closure を保持する lock 付き storage

  /// 各イベントハンドラのプロパティを `NSLock` で排他して保持する storage です。
  /// get / set の排他と、lock の外での closure 呼び出し・旧 closure の解放の根拠は
  /// `HandlerStorage` の doc を参照してください。
  private let onConnectStorage = HandlerStorage<((Error?) -> Void)?>(nil)
  private let onDisconnectLegacyStorage = HandlerStorage<((Error?) -> Void)?>(nil)
  private let onDisconnectStorage = HandlerStorage<((SoraCloseEvent) -> Void)?>(nil)
  private let onAddStreamStorage = HandlerStorage<((MediaStream) -> Void)?>(nil)
  private let onRemoveStreamStorage = HandlerStorage<((MediaStream) -> Void)?>(nil)
  private let onReceiveSignalingJSONStorage = HandlerStorage<((String) -> Void)?>(nil)
  private let onReceiveSignalingStorage = HandlerStorage<((Signaling) -> Void)?>(nil)
  private let onDataChannelStorage = HandlerStorage<((MediaChannel) -> Void)?>(nil)
  private let onDataChannelOpenedStorage = HandlerStorage<((MediaChannel, String) -> Void)?>(nil)
  private let onDataChannelMessageStorage = HandlerStorage<((MediaChannel, String, Data) -> Void)?>(
    nil)
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

/// `MediaChannel` の接続状態の正本を `NSLock` で保護して保持する storage です。
///
/// `MediaChannel.state` はこの storage を読む computed property です。`getStats(handler:)` /
/// `getStatsSnapshot(handler:)` の完了 closure は `MediaChannel` 自身を捕捉できないため、同じ
/// storage を `MediaChannelGetStatsContext` / `MediaChannelGetStatsSnapshotContext` 経由で
/// 読みます。接続状態の保持先はこの storage だけです。
///
/// 接続状態 (`storedState`) の書き込みは `MediaChannel.setState(_:)` だけが行い、その呼び出しは
/// `MediaChannel` の `connectionLifecycleLock` を保持した区間からだけ行います。したがって
/// lock 順序は `connectionLifecycleLock` → この storage の一方向だけです。
///
/// 終端フラグ (`isTerminated`) だけは `MediaChannel.deinit` の先頭から、この storage の
/// `lock` だけで書きます (`connectionLifecycleLock` は取りません)。`connectionLifecycleLock` を
/// 取らないため、この経路を足しても lock 順序の辺は増えません。
///
/// 読み出しは `getStats(handler:)` / `getStatsSnapshot(handler:)` の完了 closure (`state` と `isTerminated`) と
/// `MediaChannel.state` の getter から行います。`MediaChannel.state` は `connectionLifecycleLock` を
/// 保持していない箇所 (`Sora/ScreenCapture.swift` が自身の lock を保持したまま読む箇所を含む)
/// からも読むため、この storage の `lock` は保持したまま他の lock を取らない葉 lock とし、
/// どの経路から入れ子で取っても循環しません。
///
/// `@unchecked Sendable` を認める根拠は、可変状態 (`storedState` / `terminated`) の読み書きを
/// すべてこの `lock` 配下で行うことです。可変状態として保持する値はどちらも値型です。
/// `lock` 自身は `NSLock` (参照型) ですが、`let` で不変に保持し、排他はその内部状態が担うため
/// この storage が `Sendable` を主張する妨げにはなりません。
/// `getStats(handler:)` / `getStatsSnapshot(handler:)` の完了 closure へは
/// `MediaChannelGetStatsContext` / `MediaChannelGetStatsSnapshotContext` が
/// 強参照で渡し、この storage 自身の生存はその box の生存にも従います。
/// 終端フラグを別の storage へ分けると、解放の検出機構が 2 つになるため分けません。
private final class MediaChannelStateStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var storedState: ConnectionState = .disconnected
  private var terminated = false

  /// 現在の接続状態。読み出しと書き込みの両方を `lock` で排他する。
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

  /// `MediaChannel` の `deinit` の本体が始まったか。読み出しは `lock` で排他する。
  ///
  /// 検出点は `deinit` の最初の文です。`getStats(handler:)` / `getStatsSnapshot(handler:)` の
  /// 完了 closure がこのフラグを読んだ時点で `deinit` の最初の文が実行済みなら失敗を返しますが、
  /// フラグの読みがそれに先行した場合は覆えません (その場合は `state` も `transportStorage` も
  /// 生きているため成功を返し得ます)。`getStatsSnapshot()` は呼び出し中 `MediaChannel` を保持する
  /// ため、このフラグが真になることはありません (`getStatsSnapshot(handler:)` は完了 block から
  /// このフラグを読みます)。
  /// この隙間は、`MediaChannelGetStatsContext` / `MediaChannelGetStatsSnapshotContext` に
  /// `MediaChannel` の弱参照を足して完了 closure の先頭で強参照へ束縛する方式なら閉じられますが、
  /// statistics の完了まで解放が遅延し (`deinit` が statistics の完了 thread 上で走ります)、
  /// context が `MediaChannel` を参照しない形も崩れるため採りません。
  var isTerminated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminated
  }

  /// 終端フラグを立てます。呼び出しは `MediaChannel.deinit` の最初の文だけです。
  /// 一度立てた後に戻す経路はなく、解放が始まっていない `MediaChannel` では ``true`` に
  /// なることはありません。
  func markTerminated() {
    lock.lock()
    defer { lock.unlock() }
    terminated = true
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
///   代入後に値を書き換えない)。Debug では `@Sendable` な `let` の
///   `willEvaluateForTesting` も保持するが、不変の closure であり box 自身は状態を持たない。
///   `RTCPeerConnection` は class であるため、ここで主張するのは参照が再代入されないことだけで、
///   オブジェクトの状態の不変性ではない。box は参照を保持して callback へ渡し、Debug では
///   テスト用フックを呼ぶだけで、状態を読み書きしないこと
/// - 変更前から handler と `RTCPeerConnection` を渡していた `RTCPeerConnection.statistics` の
///   完了 block をそのまま包み直すだけで、配送先・通知順序・呼び出し回数を変えず、
///   別系統の境界へ新たに渡さないこと。Debug では完了 block の先頭でテスト用フックを 1 回
///   呼ぶだけで、呼び出しは `nil` なら何もしないこと
/// - 保持する参照型に対する closure の状態アクセスが、既存または本変更で確立した排他に
///   閉じること。`MediaChannelStateStorage` は自身の `NSLock` が `state` と終端フラグ
///   (`isTerminated` / `markTerminated()`) の読み書きを保護する。接続状態の書き込みは
///   `MediaChannel.setState(_:)` が `connectionLifecycleLock` 配下でだけ行う
///   (`connectionLifecycleLock` → storage の一方向) が、終端フラグは `MediaChannel.deinit` が
///   storage の `lock` だけを取って立てる (`connectionLifecycleLock` を取らないため、
///   この storage の `lock` を単独で取る経路を許す)。`PeerChannelTransportStorage` も
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
/// 1 回で終端するためです。`PeerChannel` は `MediaChannel` が生成して所有し、`MediaChannel` への
/// 参照は弱参照だけを持ちますが、`MediaChannel.streams` が返す `MediaStream` も `PeerChannel` を
/// 強参照するため、この弱参照が nil になるのは `MediaChannel` が解放され、かつ利用者が
/// その `MediaStream` を保持していない場合だけです (この binding だけが判定を決める経路は
/// 現時点ではありませんが、将来 `_peerChannel` を手放す経路を足したときのフォールバックとして
/// 残します)。
/// 強参照にすると、完了 block が `PeerChannelTransportStorage` を介して
/// `RTCPeerConnection` の参照を解放後も保持し、統計 callback の完了まで
/// `RTCPeerConnection` の解放が遅れます。
///
/// 生成は `MediaChannel.getStats` の 1 箇所だけで、1 つの block へ 1 回だけ渡して 1 回だけ実行する
/// 使用契約です (型では強制されません)。`Sendable` にするのはこの入れ物だけで、handler と
/// その捕捉状態を `Sendable` にはしません。捕捉状態の所有と同期は、呼び出しスレッドを
/// 保証しない既存の挙動の下で利用者の責務です。実行スレッドの同一性・直列性も契約にしません。
private final class MediaChannelGetStatsContext: @unchecked Sendable {
  let handler: (Result<Statistics, any Error>) -> Void
  let peerConnection: RTCPeerConnection

  /// 現在の接続状態と終端フラグを読む storage。
  ///
  /// 接続状態の正本である。closure は `MediaChannel` を捕捉せず、この storage 自身の `NSLock` で
  /// 保護して読む。終端フラグ (`isTerminated`) は `MediaChannel.deinit` の本体が始まったことを
  /// 示し、完了 block は `state` を確認する前にこれを確認する。
  let stateStorage: MediaChannelStateStorage

  /// 現在の `nativeChannel` を読む `PeerChannel` の storage。
  ///
  /// 弱参照にするのは、`PeerChannel` (と `MediaChannel`) が解放済みなら handler を 1 回だけ
  /// 失敗で終端するためである。解放の検出そのものは `stateStorage` の終端フラグが担うため、
  /// この参照が nil になるのは `PeerChannel` が解放された場合だけである (クラス doc のとおり、
  /// `MediaChannel` の解放だけでは nil にならない)。強参照にすると、完了 block が
  /// `PeerChannelTransportStorage` を介して `RTCPeerConnection` の参照を解放後も保持する。
  weak var transportStorage: PeerChannelTransportStorage?

  #if DEBUG
    /// `MediaChannel.getStatsWillEvaluateForTesting` を Debug で受け取るための
    /// テスト用フックです。
    ///
    /// 役割と使用契約は `MediaChannel.getStatsWillEvaluateForTesting` の doc に書きます。
    /// `willEvaluateForTesting` 以外の引数の構成は `#else` 側の init と揃えます。Release には存在しません。
    let willEvaluateForTesting: (@Sendable () -> Void)?

    init(
      handler: @escaping (Result<Statistics, any Error>) -> Void,
      peerConnection: RTCPeerConnection,
      stateStorage: MediaChannelStateStorage,
      transportStorage: PeerChannelTransportStorage,
      willEvaluateForTesting: (@Sendable () -> Void)?
    ) {
      self.handler = handler
      self.peerConnection = peerConnection
      self.stateStorage = stateStorage
      self.transportStorage = transportStorage
      self.willEvaluateForTesting = willEvaluateForTesting
    }
  #else
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
  #endif
}

// MARK: -

/// libwebrtc の統計情報取得 handler、その取得対象の `RTCPeerConnection`、接続状態と
/// `nativeChannel` を読むための storage を並行処理境界へ渡すための、用途限定の内部ラッパーです
/// (`StatisticsSnapshot` 版)。
///
/// `@unchecked Sendable` を認める根拠は `MediaChannelGetStatsContext` と同じです。可変状態を
/// 持たず、保持する handler / `RTCPeerConnection` / `MediaChannelStateStorage` の参照は `init` で
/// 確定した `let`、`PeerChannelTransportStorage` は `init` でのみ代入する `weak var` です。
/// `RTCPeerConnection` は class であるため、ここで主張するのは参照が再代入されないことだけで、
/// オブジェクトの状態の不変性ではありません。完了 block は handler と storage を読むだけで、
/// `MediaChannel` を捕捉しません。保持する参照型に対する closure の状態アクセスは、既存の
/// lock (`MediaChannelStateStorage` / `PeerChannelTransportStorage`) に閉じます。
///
/// 生成は `MediaChannel.getStatsSnapshot(handler:)` の 1 箇所だけで、1 つの block へ 1 回だけ
/// 渡して 1 回だけ実行する使用契約です (型では強制されません)。handler の型が `Statistics` 版と
/// 異なるため `MediaChannelGetStatsContext` とは別の型にし、完了 block の判定は
/// `MediaChannel.statisticsCompletionFailure(stateStorage:transportStorage:peerConnection:)` を
/// 共通で使います (判定をこの型へ持たせません)。
private final class MediaChannelGetStatsSnapshotContext: @unchecked Sendable {
  let handler: (Result<StatisticsSnapshot, any Error>) -> Void
  let peerConnection: RTCPeerConnection

  /// 現在の接続状態と終端フラグを読む storage。
  ///
  /// `getStats` と同じ storage を読み、`MediaChannel` の解放開始 (`deinit` の最初の文) を
  /// `isTerminated` で判定します。検出機構を重複して持たないため、新しい storage は作りません。
  let stateStorage: MediaChannelStateStorage

  /// 現在の `nativeChannel` を読む `PeerChannel` の storage。
  ///
  /// 弱参照にする理由と、nil になったときに失敗を返す経路は `MediaChannelGetStatsContext` と
  /// 同じです。強参照にすると、完了 block が `PeerChannelTransportStorage` を介して
  /// `RTCPeerConnection` の参照を解放後も保持します。
  weak var transportStorage: PeerChannelTransportStorage?

  #if DEBUG
    /// `MediaChannel.getStatsSnapshotWillEvaluateForTesting` を Debug で受け取るための
    /// テスト用フックです。
    ///
    /// 役割と使用契約は `MediaChannel.getStatsSnapshotWillEvaluateForTesting` の doc に
    /// 書きます。`willEvaluateForTesting` 以外の引数の構成は `#else` 側の init と揃えます。
    /// Release には存在しません。
    let willEvaluateForTesting: (@Sendable () -> Void)?

    init(
      handler: @escaping (Result<StatisticsSnapshot, any Error>) -> Void,
      peerConnection: RTCPeerConnection,
      stateStorage: MediaChannelStateStorage,
      transportStorage: PeerChannelTransportStorage,
      willEvaluateForTesting: (@Sendable () -> Void)?
    ) {
      self.handler = handler
      self.peerConnection = peerConnection
      self.stateStorage = stateStorage
      self.transportStorage = transportStorage
      self.willEvaluateForTesting = willEvaluateForTesting
    }
  #else
    init(
      handler: @escaping (Result<StatisticsSnapshot, any Error>) -> Void,
      peerConnection: RTCPeerConnection,
      stateStorage: MediaChannelStateStorage,
      transportStorage: PeerChannelTransportStorage
    ) {
      self.handler = handler
      self.peerConnection = peerConnection
      self.stateStorage = stateStorage
      self.transportStorage = transportStorage
    }
  #endif
}

// MARK: -

/// `MediaChannel.getStatsSnapshot()` の終端を 1 回だけ確定するための箱です。
///
/// `withTaskCancellationHandler` の `onCancel` は別スレッドから呼ばれるため、
/// `RTCPeerConnection.statistics` の完了 block と競合し得ます。continuation の `resume` は
/// 1 回だけ行う必要があるため、どちらが先に来ても先に来た方を終端として採用し、後から来た方は
/// 何もしません (`onCancel` は `operation` より先にも呼ばれ得ます)。
///
/// 使用契約は「`attach(_:)` を `finish(_:)` より先に 1 回だけ呼ぶ」ことです
/// (`MediaChannel.getStatsSnapshot()` は callback 版を呼ぶ直前に `attach(_:)` を呼びます)。
/// この契約により、`finish(_:)` の時点で continuation は必ず登録済みです。
///
/// `@unchecked Sendable` を認める根拠は、可変状態 (`continuation` / `finished`) の読み書きを
/// すべて `lock` 配下で行うことです。保持する `CheckedContinuation` は `Sendable` です。
private final class MediaChannelGetStatsSnapshotTerminalBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<StatisticsSnapshot, any Error>?
  private var finished = false

  /// continuation を登録します。
  ///
  /// 登録より前にキャンセルで終端していた場合は `CancellationError` でその場で終端します
  /// (完了 block はこの登録より後にしか呼ばれないため、終端済みならキャンセルが先行しています)。
  /// - parameter continuation: 登録する continuation
  func attach(_ continuation: CheckedContinuation<StatisticsSnapshot, any Error>) {
    lock.lock()
    if finished {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  /// 完了 block の結果で終端します。終端済みなら何もしません。
  ///
  /// `attach(_:)` を先に呼ぶ使用契約のため、continuation は登録済みです (契約違反でも
  /// 二重 `resume` はせず、何もしません)。
  /// - parameter result: 完了 block が受け取った結果
  func finish(_ result: Result<StatisticsSnapshot, any Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    guard let continuation else {
      return
    }
    switch result {
    case .success(let snapshot):
      continuation.resume(returning: snapshot)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }

  /// タスクキャンセルで終端します。
  ///
  /// 先に完了 block が終端していた場合は continuation を持ち出せないため、何も起きません
  /// (continuation は終端した側が `nil` にするため、`resume` が 2 回になることはありません)。
  func cancel() {
    lock.lock()
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
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
  ///
  /// get / set は lock 付き storage で排他します。配送は毎回この storage から読むため、接続を
  /// 開始した後に代入しても次の配送から反映されます。配送側は lock を解放してから取得済みの
  /// closure を呼びます。この storage が排他するのは参照の差し替えだけで、各イベントハンドラの
  /// プロパティは
  /// `MediaChannelHandlers` の `HandlerStorage` が排他します。
  public var handlers: MediaChannelHandlers {
    get { handlersStorage.current }
    set { handlersStorage.current = newValue }
  }

  /// `handlers` を保持する lock 付き storage です。参照の差し替えを排他します (各イベントハンドラの
  /// プロパティは
  /// `MediaChannelHandlers` の `HandlerStorage` が排他します)。
  private let handlersStorage = HandlerStorage<MediaChannelHandlers>(MediaChannelHandlers())

  /// 内部処理で使われるイベントハンドラ
  ///
  /// 接続開始前にだけ設定し、接続開始後に並行して書き換える経路が無いため、参照自体は lock 付き
  /// アクセサにしない。イベントハンドラのプロパティの読み書きは `MediaChannelHandlers` が排他する。
  var internalHandlers = MediaChannelHandlers()

  // MARK: - イベントの購読

  /// 接続イベントを購読します。
  ///
  /// 購読者ごとに独立した `AsyncStream` を返します。同じ `MediaChannel` に対して複数回呼ぶと、
  /// それぞれが独立した buffer / drop 方針 / 終端を持ちます (1 つの `AsyncStream` を複数の
  /// `Iterator` で消費するとイベントが購読者間で分かれるため、購読者ごとに stream を作ります)。
  ///
  /// - イベントは接続単位の順序付きの列です。同じ接続のイベントは配送順に届きます。通し番号の
  ///   順序と一致しない場合はあります (同時に配送されたイベントのみ)。
  /// - buffer は既定で `SoraEvent.defaultBufferSize` 件です。あふれた場合は最も古いイベントが
  ///   破棄されます。`sequence` で欠落を検出できます。
  /// - 購読を開始する前に配送されたイベントは届きません (buffer は購読ごとに作られます)。
  ///   接続の完了前に開始するには、`SoraHandlers.onAddMediaChannel` または `Sora.mediaChannels` で
  ///   参照を取得してから購読するか、`Sora.subscribeEvents(bufferingPolicy:)` を使います。
  /// - `connected` と `connectFailed` は接続の完了と同じ配送点で発行されます。接続の完了を
  ///   待ってから購読すると取り逃すため、接続の結果を購読する場合は `Sora` の購読を使ってください。
  /// - payload はすべて値として確定しており、配送後も購読者が保持できます。mutable な
  ///   `MediaChannel` / `MediaStream` / raw WebRTC object は含まれません。`SoraEvent` は
  ///   `Sendable` のため、actor / Task 境界へそのまま渡せます。
  /// - 購読の解除は、購読している `Task` の cancel、購読に使った `AsyncStream` への参照の解放、
  ///   または接続の終了です。購読を解除しても他の購読者の buffer と終端は影響を受けません。
  /// - 接続が終了すると `.disconnected` を配送した後に stream が終端します。終端後の購読には
  ///   終端済みの stream を返します。`.disconnected` を配送せずに終端するのは、明示切断を経由せず
  ///   `MediaChannel` が解放された場合だけです。
  /// - 購読している `Task` の loop の中から同期 API (`connectionId` / `state` などの getter、
  ///   `sendMessage`、`disconnect`) を呼べます。配送は排他区間の外で行うため deadlock しません。
  ///   `disconnect` を呼ぶと `.disconnected` の配送後に購読が終端し、以降のイベントは届きません。
  /// - 配送 executor はイベントの発生元によって異なります (libwebrtc の callback スレッド、
  ///   signaling の受信スレッド、呼び出し元の executor など)。`AsyncStream` の再開後に実行される
  ///   購読者のコードは、購読している `Task` の executor 上で動きます。UI 更新は main actor /
  ///   main queue へ束ねてください。
  /// - `videoEnabledChanged` / `audioEnabledChanged` は、並行する変更の確定順と配送順が一致しない
  ///   ことがあります (`MediaStreamHandlers.onSwitchVideo` と同じ契約です)。
  /// - この API の追加によって、既存の `handlers` の callback 型・配送 executor・配送順序・
  ///   発火回数は変わりません。
  ///
  /// - parameter bufferingPolicy: 購読者ごとの buffer と drop 方針
  /// - returns: この接続のイベントを配送する stream
  public func subscribeEvents(
    bufferingPolicy: AsyncStream<SoraEvent>.Continuation.BufferingPolicy = .bufferingNewest(
      SoraEvent.defaultBufferSize)
  ) -> AsyncStream<SoraEvent> {
    eventPublisher.subscribe(bufferingPolicy: bufferingPolicy)
  }

  #if DEBUG
    /// 現在の購読者の数です (`SoraEventPublisher` のテスト用アクセサを返します)。
    var eventSubscriptionCountForTesting: Int {
      eventPublisher.subscriptionCountForTesting
    }
  #endif

  /// 接続イベントの購読者を管理する storage です。
  private let eventPublisher = SoraEventPublisher()

  /// 現在の transport epoch です。redirect のたびに進み、古い世代のイベントの識別に使います。
  var transportEpoch: Int {
    peerChannel.dataChannelGeneration
  }

  /// この接続に紐づくイベントを配送します。
  ///
  /// 呼び出し側は owner の排他区間を保持せずに呼びます。配送のたびに通し番号を採番します。
  func publishEvent(
    kind: SoraEventKind,
    streamId: String? = nil,
    isEnabled: Bool? = nil,
    signalingJSON: String? = nil,
    dataChannelLabel: String? = nil,
    dataChannelMessage: Data? = nil,
    error: Error? = nil,
    closeEvent: SoraCloseEvent? = nil
  ) {
    eventPublisher.publish(
      SoraEvent(
        kind: kind,
        connectionId: connectionId,
        transportEpoch: transportEpoch,
        error: error.map(SoraEventError.init),
        closeEvent: closeEvent,
        streamId: streamId,
        isEnabled: isEnabled,
        signalingJSON: signalingJSON,
        dataChannelLabel: dataChannelLabel,
        dataChannelMessage: dataChannelMessage))
  }

  /// 購読をすべて終端します。
  ///
  /// 接続の終了と `deinit` から呼びます。冪等なため重複して呼んでも安全です。
  func finishEvents() {
    eventPublisher.finish()
  }

  // MARK: - 接続情報

  /// クライアントの設定
  ///
  /// 公開互換のために利用者が渡した値を返し続けます。接続開始後の非同期区間
  /// (非同期 hop の後、WebRTC callback、`ConnectionTimer`) はこの値の参照型フィールド
  /// (metadata / notify metadata / codec 別 params / `dataChannels` / `forwardingFilter` /
  /// `forwardingFilters` / `webRTCConfiguration`、および snapshot に含めないハンドラクラスと
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
  /// 接続状態の正本は `stateStorage` だけであり、この property はそこを読む computed property です。
  /// getter だけの宣言には `private(set)` を付けられないため `get` / `set` を明示し、`set` は
  /// `setState(_:)` を呼びます (storage を直接書きません)。読み書きの排他は storage の `NSLock` に
  /// 揃います。
  ///
  /// 遷移ログは排他区間の外で出す。`didSet` では lock を保持したまま Logger を呼び得るため、
  /// `connectionLifecycleLock` を保持して遷移させる箇所では、遷移の直後 (lock の解放後) に
  /// 呼び出し元が `logStateChange(from:)` を呼ぶ (この property は computed property のため
  /// `didSet` を持たない)。
  ///
  /// 接続状態の遷移は `setState(_:)` を呼ぶこと。`private(set)` の setter は
  /// `connectionLifecycleLock` を取らずに `setState(_:)` へ入るため、SDK 内部から `state` へ
  /// 代入してよいのは `connectionLifecycleLock` を保持した区間だけです。
  public private(set) var state: ConnectionState {
    get {
      stateStorage.state
    }
    set {
      setState(newValue)
    }
  }

  /// 接続状態の正本を lock 付きで保持する storage
  ///
  /// `state` はこの storage を読む computed property であり、`getStats(handler:)` /
  /// `getStatsSnapshot(handler:)` の完了 closure も `MediaChannel` を捕捉できないためこの storage
  /// 経由で読む。`state` の書き込みは `setState(_:)` にだけ置き、`connectionLifecycleLock` を
  /// 保持した区間で行う。終端フラグは `deinit` の先頭で立て、`getStats(handler:)` /
  /// `getStatsSnapshot(handler:)` の完了 closure が `state` を確認する前に読む。
  private let stateStorage = MediaChannelStateStorage()

  /// 接続状態を遷移させ、接続状態の正本である storage を更新します。
  ///
  /// 呼び出し側は `connectionLifecycleLock` を保持した状態で呼びます。`state` は storage を読む
  /// computed property であり、`state` への代入は必ずこのメソッドへ入るため、ここから `state` へ
  /// 代入すると無限再帰します。書き込む先は storage だけです。
  private func setState(_ next: ConnectionState) {
    stateStorage.state = next
  }

  /// 接続中 (`state == .connected`) であれば ``true``
  public var isAvailable: Bool { state == .connected }

  #if DEBUG
    /// 実接続を伴わずに接続状態を作るテスト用フックです。
    ///
    /// `connectionLifecycleLock` を保持して `setState(_:)` を通すため、接続状態の正本である
    /// storage だけが変わり、他の接続ライフサイクル (`currentConnectionTask` /
    /// `connectionTimerAuthorization` / `hasStartedConnection`) は変わりません。
    /// テストは `getStats` / `getStatsSnapshot` 以外の接続ライフサイクル API を呼ばず、後始末で `.disconnected` に
    /// 戻してから `MediaChannel` を解放します。Release には存在せず、本番からは呼びません。
    func setConnectionStateForTesting(_ next: ConnectionState) {
      connectionLifecycleLock.lock()
      defer { connectionLifecycleLock.unlock() }
      setState(next)
    }

    /// `getStats` の完了 block が判定の先頭で呼ぶ closure を保持する
    /// テスト用フックです。
    ///
    /// テストはこの closure で `peerChannel.nativeChannel` の差し替え、接続状態の変更、
    /// `MediaChannel` の最後の強参照の解放 (終端フラグの確認) を行います。`getStats` は
    /// 呼び出し時点のこの closure を box へ不変の値として渡し、完了 closure は box 経由で
    /// 呼びます (完了 closure が `MediaChannel` を捕捉しない形を保つため)。
    ///
    /// closure は `RTCPeerConnection.statistics` の完了 thread から呼ばれるため、触ってよいのは
    /// 既存の lock (`PeerChannelTransportStorage` / `MediaChannelStateStorage` /
    /// `connectionLifecycleLock`) に閉じた状態だけです。利用者 handler や公開 API を呼びません。
    /// ただし最後の強参照を解放する使い方だけは例外で、その closure の中で `MediaChannel.deinit`
    /// の本体 (Task の生成、リソースの破棄、`PeerChannel` の切断) がこの thread 上で走ります
    /// (切断処理は接続ライフサイクルの排他が許す時点まで遅延し得ます)。解放後は `MediaChannel` に
    /// 到達できないため、この property を `nil` に戻せません (その用途では解放前に設定したままに
    /// します)。最後の強参照を保持する箱は closure から弱参照で捕捉し、解放が起きない場合に
    /// `MediaChannel` を延命しないようにします。
    /// この property の読み書きは `getStats` を呼ぶスレッドだけが行い、完了 block は property を
    /// 触りません (`getStats` を呼ぶ前に設定します)。本番では常に `nil` です。
    /// Release には存在しません。
    var getStatsWillEvaluateForTesting: (@Sendable () -> Void)?

    /// `getStatsSnapshot(handler:)` の完了 block が判定の先頭で呼ぶ closure を保持するテスト用フックです。
    ///
    /// 役割と使用契約は `getStatsWillEvaluateForTesting` と同じですが、対象は
    /// `getStatsSnapshot(handler:)` の完了 block です (`getStatsSnapshot()` は callback 版を
    /// 呼び出し中 `MediaChannel` を保持するため、hook の中で解放する使い方はできません)。
    /// `getStats` 側のフックと分けているのは、`getStatsWillEvaluateForTesting` の doc が
    /// `getStats` 専用と明記しているためです。本番では常に `nil` で、Release には存在しません。
    var getStatsSnapshotWillEvaluateForTesting: (@Sendable () -> Void)?
  #endif

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
    // deinit の本体が始まったことを storage へ記録する。getStats(handler:) /
    // getStatsSnapshot(handler:) の完了 closure は MediaChannel を捕捉しないため、変更前の
    // [weak self] が検出していた解放を伝える手段はこのフラグだけになる。deinit の最初の文に
    // 置くこと (これより後に移すと、deinit の本体が動いている間にフラグを読んだ完了 block が
    // 成功を返す区間が広がる)。
    // ここでは connectionLifecycleLock を取らず、storage の lock だけを使う。
    stateStorage.markTerminated()

    videoSourceCoordinator.revoke()
    // 明示切断を経由せずに最終参照が解放された場合も、通常切断と同じ所有リソースを破棄する。
    // 各処理は冪等なため、通常切断後の deinit から重複して呼ばれても安全である。
    prepareForDisconnect(error: nil)

    // Sora と利用者の双方が参照を解放した場合も、接続中の PeerChannel を明示的に閉じる。
    // 実処理が進行中なら PeerChannel の接続ライフサイクルの排他が安全な時点まで切断を遅延する。
    _peerChannel?.disconnect(error: nil, reason: .user)

    // 明示切断を経由せずに解放された場合も購読を終端する。
    finishEvents()
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
    // rpcChannel の参照は送信経路と同じ排他単位で読む。redirect による無効化 (nil 代入) と
    // 並行しても参照の読み書きにデータ競合が生じない。参照の取り出しだけを排他し、
    // pending の登録と送信は区間の外で行う (その終端は RPCChannel の barrier と invalidate が
    // 保証する)。
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
      weakSelf.publishEvent(kind: .streamAdded, streamId: stream.streamId)
    }

    peerChannel.internalHandlers.onRemoveStream = { [weak self] stream in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "removed a stream")
      Logger.debug(type: .mediaChannel, message: "call onRemoveStream")
      weakSelf.internalHandlers.onRemoveStream?(stream)
      weakSelf.handlers.onRemoveStream?(stream)
      weakSelf.publishEvent(kind: .streamRemoved, streamId: stream.streamId)
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
        weakSelf.publishEvent(kind: .dataChannelOpened, dataChannelLabel: label)
      }
      if shouldNotifyBatch {
        Logger.debug(type: .mediaChannel, message: "call onDataChannel")
        weakSelf.handlers.onDataChannel?(weakSelf)
        weakSelf.publishEvent(kind: .dataChannelAvailable)
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
      weakSelf.publishEvent(kind: .signalingReceivedJSON, signalingJSON: json)
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
    publishEvent(kind: .connected)
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
      publishEvent(kind: .connectFailed, error: connectionError)
    }

    Logger.debug(type: .mediaChannel, message: "did disconnect")
    Logger.debug(type: .mediaChannel, message: "call onDisconnect")
    internalHandlers.onDisconnectLegacy?(error)
    handlers.onDisconnectLegacy?(error)
    let closeEvent = makeDisconnectEvent(error: error)
    handlers.onDisconnect?(closeEvent)
    publishEvent(kind: .disconnected, closeEvent: closeEvent)
    // 接続の終了で購読を終端する。buffer に残っているイベントは配送してから終端する。
    finishEvents()
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
  ///
  /// 非同期取得中に切断された場合でも安全になるよう、コールバック内で
  /// チャンネルの解放が始まっていないこと (`MediaChannelStateStorage` の終端フラグ)、
  /// チャンネルの生存確認、state == .connected の再確認、peerChannel.nativeChannel が
  /// 同一インスタンスかどうか、をチェックしています。
  ///
  /// handler の実行スレッドは経路で異なります。`RTCPeerConnection.statistics` の完了 block から
  /// 呼ばれる経路 (成功と、終端フラグ / `state` / `nativeChannel` の同一性判定で失敗する場合) の
  /// handler は libwebrtc 側のスレッドから呼ばれ、入口の前段判定 (未接続 / `nativeChannel` が
  /// nil) で失敗する経路の handler は呼び出し元のスレッドから同期的に呼ばれます。どちらの経路も
  /// 呼び出し元スレッドは保証されません。UI 更新や共有状態の変更は main queue / main actor へ
  /// 束ねてください。
  ///
  /// Swift 6 言語モードでは、handler の中で `first(where:)` などの closure を呼ばず、
  /// handler の中の closure に `@Sendable` を付けて Sendable な値へ詰め替えてから main actor /
  /// main queue へ渡すか、handler の先頭で main に束ねます。handler の中で closure を呼ぶと、
  /// MainActor 隔離を継承した closure が WebRTC スレッドで実行時隔離チェックに掛かります。
  /// handler 引数の型 (`@escaping (Result<Statistics, Error>) -> Void`) は変更しません。
  ///
  /// actor / Task 境界へ統計情報を渡す場合は、`getStatsSnapshot(handler:)` が handler へ渡す値と
  /// `getStatsSnapshot()` が返す値が immutable で deep Sendable なため、こちらを使用してください。
  /// `Statistics` は mutable class のため、そのまま境界を越えて渡せません。
  ///
  /// - parameter handler: 統計情報取得後に呼ばれるクロージャー
  public func getStats(handler: @escaping (Result<Statistics, Error>) -> Void) {
    let peerConnection: RTCPeerConnection
    switch validatedPeerConnectionForStatistics() {
    case .success(let validated):
      peerConnection = validated
    case .failure(let error):
      handler(.failure(error))
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
    // PeerChannelTransportStorage (NSLock) の参照で行う。解放の検出は同じ storage の終端フラグで
    // 行い、PeerChannel 側の弱参照は解放済みのチャンネルへ 1 回だけ失敗を返す経路として残す。
    #if DEBUG
      let context = MediaChannelGetStatsContext(
        handler: handler,
        peerConnection: peerConnection,
        stateStorage: stateStorage,
        transportStorage: peerChannel.transportStorage,
        willEvaluateForTesting: getStatsWillEvaluateForTesting)
    #else
      let context = MediaChannelGetStatsContext(
        handler: handler,
        peerConnection: peerConnection,
        stateStorage: stateStorage,
        transportStorage: peerChannel.transportStorage)
    #endif
    peerConnection.statistics { [context] report in
      #if DEBUG
        // テスト用フックは他の判定より前に呼ぶ。テストが完了 block の評価時点の
        // 状態を確定的に作れるようにするため、状態と nativeChannel の判定が確定する前に呼ぶ。
        context.willEvaluateForTesting?()
      #endif

      if let error = Self.statisticsCompletionFailure(
        stateStorage: context.stateStorage,
        transportStorage: context.transportStorage,
        peerConnection: context.peerConnection)
      {
        context.handler(.failure(error))
        return
      }

      context.handler(.success(Statistics(contentsOf: report)))
    }
  }

  // MARK: - Statistics snapshot

  /// libwebrtc の統計情報を、actor / Task 境界へ渡せる snapshot として取得します。
  ///
  /// `getStats(handler:)` と同じ `RTCPeerConnection.statistics` を入力源にし、戻り値だけを
  /// immutable で deep Sendable な `StatisticsSnapshot` に変えます。既存の `getStats(handler:)` の
  /// シグネチャと挙動、`Statistics` / `StatisticsEntry` は変更しません。
  ///
  /// handler の実行スレッドは `getStats(handler:)` と同じです。`RTCPeerConnection.statistics` の
  /// 完了 block から呼ばれる経路 (成功と、終端フラグ / `state` / `nativeChannel` の同一性判定 /
  /// 統計値の変換で失敗する場合) の handler は libwebrtc 側のスレッドから呼ばれ、入口の前段判定
  /// (未接続 / `nativeChannel` が nil) で失敗する経路の handler は呼び出し元のスレッドから
  /// 同期的に呼ばれます。どちらの経路も呼び出し元スレッドは保証されません。
  ///
  /// Swift 6 言語モードでの扱い方も `getStats(handler:)` と同じです (handler の中で closure を
  /// 呼ばず、handler の中の closure に `@Sendable` を付けて Sendable な値へ詰め替えてから
  /// main actor / main queue へ渡すか、handler の先頭で main に束ねます)。
  ///
  /// 失敗時の `SoraError.peerChannelError` の `reason` は、入口の前段判定で
  /// `"MediaChannel is not connected (state: …)"` と `"RTCPeerConnection is unavailable (nativeChannel: nil)"`、
  /// 完了 block の判定で `"MediaChannel is unavailable"` と
  /// `"MediaChannel is not connected (state: …)"` と
  /// `"RTCPeerConnection is unavailable (nativeChannel changed)"` になります。統計値を `JSONValue` へ
  /// 変換できない場合は `SoraError.mediaChannelError` になります。
  ///
  /// - parameter handler: 統計情報取得後に呼ばれるクロージャー
  public func getStatsSnapshot(handler: @escaping (Result<StatisticsSnapshot, Error>) -> Void) {
    let peerConnection: RTCPeerConnection
    switch validatedPeerConnectionForStatistics() {
    case .success(let validated):
      peerConnection = validated
    case .failure(let error):
      handler(.failure(error))
      return
    }

    // getStats(handler:) と同じく、完了 closure は MediaChannel を捕捉しない。state と
    // nativeChannel は storage 経由で読み、判定の順序は getStats(handler:) と同じ共通ヘルパーで
    // 行う (解放の検出機構も同じ終端フラグを共有する)。
    #if DEBUG
      let context = MediaChannelGetStatsSnapshotContext(
        handler: handler,
        peerConnection: peerConnection,
        stateStorage: stateStorage,
        transportStorage: peerChannel.transportStorage,
        willEvaluateForTesting: getStatsSnapshotWillEvaluateForTesting)
    #else
      let context = MediaChannelGetStatsSnapshotContext(
        handler: handler,
        peerConnection: peerConnection,
        stateStorage: stateStorage,
        transportStorage: peerChannel.transportStorage)
    #endif
    peerConnection.statistics { [context] report in
      #if DEBUG
        // テスト用フックは他の判定より前に呼ぶ。テストが完了 block の評価時点の
        // 状態を確定的に作れるようにするため、状態と nativeChannel の判定が確定する前に呼ぶ。
        context.willEvaluateForTesting?()
      #endif

      if let error = Self.statisticsCompletionFailure(
        stateStorage: context.stateStorage,
        transportStorage: context.transportStorage,
        peerConnection: context.peerConnection)
      {
        context.handler(.failure(error))
        return
      }

      // 値の変換は完了 block の中 (libwebrtc 側のスレッド) で行い、raw WebRTC object を
      // snapshot の外へ出さない。変換できない値があった場合は silent drop せず、
      // 1 回だけ失敗で終端する。
      do {
        context.handler(.success(try StatisticsSnapshot(contentsOf: report)))
      } catch {
        Logger.debug(
          type: .mediaChannel,
          message: "failed to convert statistics to snapshot: \(error)")
        context.handler(.failure(error))
      }
    }
  }

  /// libwebrtc の統計情報を、actor / Task 境界へ渡せる snapshot として取得します。
  ///
  /// `getStatsSnapshot(handler:)` の async 版です。タスクのキャンセルは `CancellationError` で
  /// 終端します。libwebrtc には統計取得をキャンセルする API が無いため、キャンセル後も
  /// `RTCPeerConnection.statistics` は開始して完了 block まで走りますが、終端済みの結果は
  /// 返しません (キャンセルが要求の開始より先でも、開始の有無で終端の挙動を分けません)。
  ///
  /// このメソッドは呼び出し中 `MediaChannel` を保持します。そのため `deinit` による切断と
  /// 後始末は、完了 block が届くかタスクがキャンセルされるまで遅延します。完了 block が届かない
  /// 場合に `await` を終わらせる手段はタスクキャンセルだけです (既存 `rpc` のような timeout は
  /// 持ちません)。また、呼び出し中は `MediaChannel` が生存するため、完了 block の終端フラグ
  /// (`MediaChannelStateStorage.isTerminated`) が真になることはなく、解放開始による失敗は
  /// `getStatsSnapshot(handler:)` だけが返します。
  ///
  /// キャンセルは async 版だけを対象とし、キャンセル・切断・状態遷移が競合しても終端は 1 回です。
  /// キャンセルと結果の到着が競合した場合は、先に終端した方を採用します (キャンセルが先なら
  /// `CancellationError`、結果が先なら snapshot を返します)。入口の前段判定 (未接続 /
  /// `nativeChannel` が nil) は `getStatsSnapshot(handler:)` と共通で、キャンセル済みのタスクでは
  /// `CancellationError` が優先されます。
  ///
  /// - Throws: `SoraError.peerChannelError` (未接続 / `nativeChannel` が nil / 接続状態の遷移後 /
  ///   `nativeChannel` の差し替え後。`reason` は `getStatsSnapshot(handler:)` と同じ)、
  ///   `SoraError.mediaChannelError` (統計値を `JSONValue` へ変換できない)、
  ///   `CancellationError` (タスクがキャンセルされた)
  /// - Returns: 統計情報の snapshot
  public func getStatsSnapshot() async throws -> StatisticsSnapshot {
    // キャンセルと完了 block の競合で continuation の resume を 1 回だけにするための箱。
    // (withTaskCancellationHandler の onCancel は別スレッドから呼ばれる)
    let terminal = MediaChannelGetStatsSnapshotTerminalBox()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<StatisticsSnapshot, any Error>) in
          terminal.attach(continuation)
          // キャンセル済みでも要求を開始する (libwebrtc に統計取得をキャンセルする API が無く、
          // 開始の有無で終端の挙動を分けない)。完了 block の結果は箱が捨てる。
          // 入口の判定・完了 block・終端の判定は callback 版と共通にする (実装を 2 つ持たない)。
          getStatsSnapshot { result in
            terminal.finish(result)
          }
        }
      },
      onCancel: {
        terminal.cancel()
      })
  }

  // MARK: - Statistics 共通の判定

  /// 統計取得 API (`getStats(handler:)` / `getStatsSnapshot(handler:)`) の入口の判定です。
  ///
  /// 未接続と `nativeChannel` が nil の場合だけを判定し、失敗は呼び出し元のスレッドで handler へ
  /// 渡せる `SoraError` として返します。判定の順序と失敗理由をこの 1 箇所に集約し、両 API で
  /// 揃えます。
  /// - Returns: 取得対象の `RTCPeerConnection`、または入口の判定で失敗した `SoraError`
  private func validatedPeerConnectionForStatistics() -> Result<RTCPeerConnection, SoraError> {
    // state の読みは lock を取るため、判定とメッセージで同じ値を使うよう 1 回だけ読む。
    let currentState = state
    guard currentState == .connected else {
      let message = "MediaChannel is not connected (state: \(currentState))"
      Logger.debug(type: .mediaChannel, message: message)
      return .failure(SoraError.peerChannelError(reason: message))
    }

    guard let peerConnection = peerChannel.nativeChannel else {
      // 直前の guard を通過しているため state は必ず .connected であり、メッセージには出さない。
      let message = "RTCPeerConnection is unavailable (nativeChannel: nil)"
      Logger.debug(type: .mediaChannel, message: message)
      return .failure(SoraError.peerChannelError(reason: message))
    }
    return .success(peerConnection)
  }

  /// 統計取得 API の完了 block が共通で行う判定です。
  ///
  /// 判定の順序は `MediaChannel` の解放開始 (終端フラグ) → 接続状態 → `nativeChannel` の同一性です。
  /// 前者は deinit 中も state が `.connected` のままで nativeChannel も残るため、後者は変更前の
  /// `[weak self]` と同じ経路のため、どちらも統計を返さず 1 回だけ失敗を返します。終端フラグの
  /// 判定は読んだ時点の状態であり、読みが deinit の最初の文に先行した場合は覆えません
  /// (PeerChannel の弱参照は現時点では前者と同時にしか nil にならない。将来 `_peerChannel` を
  /// 手放す経路を足したときのフォールバックとして残す)。
  /// - Parameters:
  ///   - stateStorage: 接続状態と終端フラグを読む storage
  ///   - transportStorage: 現在の `nativeChannel` を読む storage (解放済みなら nil)
  ///   - peerConnection: 統計を要求した時点の `RTCPeerConnection`
  /// - Returns: handler へ返す `SoraError`。判定を通過した場合は nil
  private static func statisticsCompletionFailure(
    stateStorage: MediaChannelStateStorage,
    transportStorage: PeerChannelTransportStorage?,
    peerConnection: RTCPeerConnection
  ) -> SoraError? {
    guard !stateStorage.isTerminated, let transportStorage else {
      return SoraError.peerChannelError(reason: "MediaChannel is unavailable")
    }

    // 切断で state が遷移した後は、nativeChannel の参照が残っていても旧接続の統計を
    // 成功として返さない。state は storage の lock 配下で読み、lock は保持しない。
    let state = stateStorage.state
    guard state == .connected else {
      let message = "MediaChannel is not connected (state: \(state))"
      Logger.debug(type: .mediaChannel, message: message)
      return SoraError.peerChannelError(reason: message)
    }

    // 参照の取り出しは storage の lock 配下で行い、同一性判定 (`===`) は lock の外で行う。
    // 直前の guard を通過しているため state は必ず .connected であり、メッセージには出さない。
    guard let currentPeerConnection = transportStorage.native,
      currentPeerConnection === peerConnection
    else {
      let message = "RTCPeerConnection is unavailable (nativeChannel changed)"
      Logger.debug(type: .mediaChannel, message: message)
      return SoraError.peerChannelError(reason: message)
    }
    return nil
  }

  /// DataChannel を利用してメッセージを送信します
  public func sendMessage(label: String, data: Data) -> Error? {
    // 送信の可否判定 (`switchedToDataChannel` と登録済みの `DataChannel`) から送信
    // (`dc.sendWithoutLogging(_:)`) までを 1 つの排他区間で行う。redirect による無効化は
    // 同じ排他単位で行われるため、無効化が完了した後に開始した送信は旧 DataChannel へ届かない。
    let messagingStorage = peerChannel.messagingStorage
    // 送信を試みた DataChannel とその結果。判定で拒否した場合は nil。
    var send: (dataChannel: DataChannel, result: DataChannelSendResult)?
    var rejectedWithoutSwitching = false
    let error: Error? = messagingStorage.withLock { () -> Error? in
      guard messagingStorage.switchedToDataChannelLocked else {
        // redirect 中は旧 DataChannel への送信を防ぐため false にしている。
        // 利用者には「まだ指定した DataChannel に接続されていない」として通知する。
        rejectedWithoutSwitching = true
        return SoraError.messagingError(reason: "DataChannel is not open yet")
      }

      guard label.starts(with: "#") else {
        return SoraError.messagingError(reason: "label should start with #")
      }

      guard let dc = messagingStorage.dataChannelLocked(label: label) else {
        return SoraError.messagingError(reason: "no DataChannel found: label => \(label)")
      }

      let readyState = dc.readyState
      guard readyState == .open else {
        return SoraError.messagingError(
          reason:
            "readyState of the DataChannel is not open: label => \(label), readyState => \(WebRTCEnumDescription.dataChannelState(readyState))"
        )
      }

      let sendResult = dc.sendWithoutLogging(data)
      send = (dc, sendResult)

      return sendResult == .sent
        ? nil : SoraError.messagingError(reason: "failed to send message: label => \(label)")
    }

    // ログは排他区間の外で出す。区間の中で `Logger` を呼ぶと、利用者の出力 handler が
    // 同じ排他単位を取る送信経路を再入したときにデッドロックする。
    // (そのため送信ログは送信の後になる)
    if let send {
      send.dataChannel.logSendAttempt(data)
      send.dataChannel.logCompressionFailureIfNeeded(send.result)
    } else if rejectedWithoutSwitching, peerChannel.isRedirecting {
      // redirect 中かどうかは排他区間の外で読むため、判定時点とは前後し得る
      // (debug ログの条件のみで、戻り値と reason は変わらない)
      Logger.debug(
        type: .mediaChannel,
        message: "sendMessage: rejected (redirecting): label => \(label)")
    }

    return error
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
  /// この呼び出し 1 回を 1 operation とし、`MediaStream.audioEnabled` への直接代入とは
  /// operation の世代 (operation の開始時に取得した順) で調停されます。後から開始した operation の
  /// 値が最新になり、より大きい世代が先に確定している場合、この呼び出しの書き込みは破棄されます
  /// (呼び出しは成功を返します)。
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
  /// この呼び出し 1 回を 1 operation とし、`setVideoHardMute` と `MediaStream.videoEnabled` への
  /// 直接代入とは operation の世代 (operation の開始時に取得した順) で調停されます。後から開始した
  /// operation の値が最新になり、より大きい世代が先に確定している場合、この呼び出しの書き込みは
  /// 破棄されます (呼び出しは成功を返します)。
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
  /// ハードミュート有効化に失敗した場合は、`VideoHardMuteActor` の直列化区間へ入った時点の
  /// `senderStream.videoEnabled` を復元します。ただし操作が取り消された場合は復元せず、
  /// 黒塗り (ソフトミュート) のまま終了します。
  /// 切断の開始と同時に失敗した場合は復元されることがあります。
  /// ただしこの基準値は呼び出し直前の値と厳密に一致する保証はありません。
  ///
  /// この呼び出し 1 回を 1 operation とし、`videoEnabled` の設定・復元・ハードミュート解除後の
  /// 有効化はすべてこの呼び出しが公開 API の入口で取得した世代で確定します。`setVideoSoftMute` や
  /// `MediaStream.videoEnabled` への直接代入など、後から開始した operation が先に値を確定している
  /// 場合は、この操作の書き込み (解除後の有効化を含む) が破棄されます (この操作の失敗時の復元も
  /// 破棄されます)。
  /// 操作の実行中や設定前の取消により拒否された場合は `videoEnabled` を変更しません。
  ///
  /// この操作の書き込みが破棄された場合でも、ハードミュートのカメラ停止・再開は実行されます。
  /// その場合 `videoEnabled` の確定値と実カメラ状態が食い違うことがあり、その場合は復旧に
  /// `setVideoHardMute(false)` が必要です (`setVideoSoftMute(false)` では復旧しません)。
  ///
  /// `senderStream.videoEnabled` の確定処理は値が変化したときだけ利用者 handler と
  /// `VideoRenderer` を呼びます (`BasicMediaStream` の経路は setter ではなくこの確定処理を直接呼びます)。
  /// この書き込みが後続の operation により破棄されない場合に限り、呼び出し前が有効なときは成功時に
  /// `onSwitchVideo(false)` が 1 回、復元する失敗時に `onSwitchVideo(false)` と `onSwitchVideo(true)` が
  /// この順に 1 回ずつ発火します。
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

    // operation の世代は公開 API の入口 (最初の await より前) で取得します。設定と復元を
    // await をまたいで同じ世代で確定するためです。SDK が生成する送信ストリームは
    // BasicMediaStream だけなので通常は世代を取得でき、他の実装では nil を渡して
    // VideoHardMuteActor 側が public な setter へフォールバックします。
    let basicStream = senderStream as? BasicMediaStream
    let generation = basicStream?.beginVideoOperation()

    if mute {
      // 黒塗りの設定は VideoHardMuteActor.setMute 内で行います
      // (所有権を取得できなかった呼び出しが videoEnabled を変更しないようにするため)
      try await Self.videoHardMuteActor.setMute(
        mute: true,
        generation: generation,
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
          generation: generation,
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
      // 有効化も設定・復元と同じ世代で確定します。後から開始した operation が先に確定している
      // 場合は破棄されます。
      if let basicStream, let generation {
        basicStream.commitVideoEnabled(true, generation: generation)
      } else {
        senderStream.videoEnabled = true
      }
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
