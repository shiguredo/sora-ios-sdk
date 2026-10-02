import Foundation
import WebRTC

/// ストリームの音声のボリュームの定数のリストです。
public enum MediaStreamAudioVolume {
  /// 最小値
  public static let min: Double = 0

  /// 最大値
  public static let max: Double = 10
}

/// ストリームのイベントハンドラです。
///
/// イベントハンドラのプロパティの get / set は、プロパティごとの `HandlerStorage` が持つ `NSLock` で
/// 排他します。
/// 利用する任意の executor からの設定と、`videoEnabled` / `audioEnabled` の確定を配送する
/// executor からの読み取りが並行してもデータ競合しません。配送側は lock を解放してから取得済みの
/// closure を呼びます (`HandlerStorage` の doc 参照)。
public final class MediaStreamHandlers {
  /// 映像トラックが有効または無効にセットされたときに呼ばれるクロージャー
  ///
  /// 値が実際に変化したときに 1 回だけ呼ばれます。複数の公開 API から同じストリームの
  /// `videoEnabled` が並行に変更された場合は operation の世代で確定が調停され、後から開始した
  /// operation が先に確定していると古い世代の書き込み (失敗時の復元を含む) は破棄されるため、
  /// 破棄された書き込みでは呼ばれません。
  ///
  /// 通知は確定の後に lock を解放して行うため、最後に配送された値が getter の最終値と一致する
  /// 保証はありません。
  ///
  /// `MediaChannel.setVideoHardMute(true)` の経路では `VideoHardMuteActor` の executor で、
  /// `MediaChannel.setVideoSoftMute`、`MediaChannel.setVideoHardMute(false)` の成功時、
  /// `MediaStream.videoEnabled` への直接代入では呼び出し側の executor で呼ばれます。
  ///
  /// `VideoRenderer.onSwitch(video:)` の配送 executor は main queue のため、このクロージャーと
  /// renderer の相対順序は保証されません。並行する operation が確定した場合、このクロージャーの
  /// 呼び出し順序は確定順と一致しないことがあります (通知順序の入れ替わりは発火回数を変えません)。
  public var onSwitchVideo: ((_ isEnabled: Bool) -> Void)? {
    get { onSwitchVideoStorage.current }
    set { onSwitchVideoStorage.current = newValue }
  }

  /// 音声トラックが有効または無効にセットされたときに呼ばれるクロージャー
  ///
  /// 値が実際に変化したときに 1 回だけ呼ばれます。複数の公開 API から同じストリームの
  /// `audioEnabled` が並行に変更された場合は operation の世代で確定が調停され、後から開始した
  /// operation が先に確定していると古い世代の書き込みは破棄されるため、破棄された書き込みでは
  /// 呼ばれません。
  ///
  /// 通知は確定の後に lock を解放して行うため、最後に配送された値が getter の最終値と一致する
  /// 保証はありません。
  ///
  /// `VideoRenderer.onSwitch(audio:)` の配送 executor は main queue のため、このクロージャーと
  /// renderer の相対順序は保証されません。並行する operation が確定した場合、このクロージャーの
  /// 呼び出し順序は確定順と一致しないことがあります (通知順序の入れ替わりは発火回数を変えません)。
  public var onSwitchAudio: ((_ isEnabled: Bool) -> Void)? {
    get { onSwitchAudioStorage.current }
    set { onSwitchAudioStorage.current = newValue }
  }

  /// 初期化します。
  public init() {}

  // MARK: - closure を保持する lock 付き storage

  /// 各イベントハンドラのプロパティを `NSLock` で排他して保持する storage です。
  private let onSwitchVideoStorage = HandlerStorage<((_ isEnabled: Bool) -> Void)?>(nil)
  private let onSwitchAudioStorage = HandlerStorage<((_ isEnabled: Bool) -> Void)?>(nil)
}

/// メディアストリームの機能を定義したプロトコルです。
/// デフォルトの実装は非公開 (`internal`) であり、カスタマイズはイベントハンドラでのみ可能です。
/// ソースコードは公開していますので、実装の詳細はそちらを参照してください。
///
/// メディアストリームは映像と音声の送受信を行います。
/// メディアストリーム 1 つにつき、 1 つの映像と 1 つの音声を送受信可能です。
public protocol MediaStream: AnyObject {
  // MARK: - イベントハンドラ

  /// イベントハンドラ
  var handlers: MediaStreamHandlers { get }

  // MARK: - 接続情報

  /// ストリーム ID
  var streamId: String { get }

  /// 接続開始時刻
  var creationTime: Date { get }

  /// メディアチャンネル
  var mediaChannel: MediaChannel? { get }

  // MARK: - 映像と音声の可否

  /// 映像の可否。
  /// `false` をセットすると、サーバーへの映像の送受信を停止します。
  /// `true` をセットすると送受信を再開します。
  ///
  /// setter は映像レンダラーの `onSwitch(video:)` の配送完了を待ちません。getter は SDK が
  /// 保持する確定値を即時に返し、native track の `isEnabled` への反映は確定時に行います。
  ///
  /// 複数の公開 API から並行に変更した場合は operation の世代で確定が調停され、後から開始した
  /// operation が先に値を確定すると自分の書き込みが破棄され得ます (呼び出しは成功を返します)。
  var videoEnabled: Bool { get set }

  /// 音声の可否。
  /// `false` をセットすると、サーバーへの音声の送受信を停止します。
  /// `true` をセットすると送受信を再開します。
  ///
  /// サーバーへの送受信を停止しても、マイクはミュートされませんので注意してください。
  ///
  /// setter は映像レンダラーの `onSwitch(audio:)` の配送完了を待ちません。getter は SDK が
  /// 保持する確定値を即時に返し、native track の `isEnabled` への反映は確定時に行います。
  ///
  /// 複数の公開 API から並行に変更した場合は operation の世代で確定が調停され、後から開始した
  /// operation が先に値を確定すると自分の書き込みが破棄され得ます (呼び出しは成功を返します)。
  var audioEnabled: Bool { get set }

  /// 映像トラックを保持している場合は `true` を返します。
  ///
  /// 映像ミュート時に映像トラックが存在するかチェックするために使用されます。
  /// ミュート時の確定処理は返り値やエラーを返さないため、
  /// 呼び出し側へエラーを通知するために必要となります。
  var hasVideoTrack: Bool { get }

  /// 音声トラックを保持している場合は `true` を返します。
  ///
  /// 音声ミュート時に音声トラックが存在するかチェックするために使用されます。
  /// ミュート時の確定処理は返り値やエラーを返さないため、
  /// 呼び出し側へエラーを通知するために必要となります。
  var hasAudioTrack: Bool { get }

  /// 受信した音声のボリューム。 0 から 10 (含む) までの値をセットします。
  /// このプロパティはロールがサブスクライバーの場合のみ有効です。
  var remoteAudioVolume: Double? { get set }

  // MARK: 音声データ取得

  /// RTCAudioTrackSink を RTCAudioTrack に関連付けます。
  /// 追加済みのシンクを再度追加した場合は何もしません。
  func addAudioTrackSink(_ sink: RTCAudioTrackSink)

  /// RTCAudioTrackSink の関連付けを解除します。
  /// 未追加の RTCAudioTrackSink を指定した場合は何もしません。
  func removeAudioTrackSink(_ sink: RTCAudioTrackSink)

  // MARK: 映像フレームの送信

  /// 映像フィルター
  ///
  /// `filter(videoFrame:)` はストリームごとの直列 executor 上で呼ばれます。同じストリームで
  /// 同時に 2 つの frame が filter へ入ることはありません。同じ instance を複数のストリームへ
  /// 設定した場合はストリームごとに直列化されるため、排他は利用者の責任です。
  ///
  /// getter と setter は内部の lock で直列化されるため、別々のスレッドから同時に呼んでも
  /// 設定は一意に定まります。交換は既に受理された frame の実行順とは同期しません (各 frame が
  /// 使う filter は実行直前に読んだ値で一意に決まります)。
  var videoFilter: VideoFilter? { get set }

  /// 映像レンダラー。
  ///
  /// renderer callback の配送 executor は main queue です。setter は callback の配送完了を
  /// 待ちません。設定した instance を再度設定した場合と `nil` を `nil` へ代入した場合は
  /// 何も配送しません。別の instance へ交換した場合は、以前の renderer に `onRemoved` が
  /// 1 回配送されます。
  ///
  /// getter と setter は内部の lock で直列化されるため、別々のスレッドから同時に呼んでも
  /// 設定は一意に定まります。どのスレッドから呼んでもかまいません。
  ///
  /// `terminate()` の後に新しい renderer を設定しても何も配送しません (終了したストリームでは
  /// `onAdded` の後に `onDisconnect` が届かない renderer が生まれるためです)。`nil` の代入に
  /// よる取り外しは `terminate()` の後でも行えます。
  var videoRenderer: VideoRenderer? { get set }

  /// 映像フレームをサーバーに送信します。
  /// 送信される映像フレームは映像フィルターを通して加工されます。
  /// 映像レンダラーがセットされていれば、加工後の映像フレームが
  /// 映像レンダラーによって描画されます。
  ///
  /// フィルターの実行と `RTCVideoSource` への配送、映像レンダラーへの callback は
  /// 非同期に行われます。このメソッドは配送の完了を待たずに戻ります。呼び出し側は frame の
  /// 所有権を SDK へ移し、このメソッドが戻った後に `videoFrame` とそれが保持する画素データを
  /// 参照・変更しないでください。
  ///
  /// 映像トラックを持たないストリーム (video source が `nil`) では frame は配送されず、
  /// `VideoFilter` も呼ばれません。フィルターの実行が滞留している場合、上限を超えて到着した
  /// frame は破棄されます。 `terminate()` の後に到着した frame も配送されません。
  ///
  /// - parameter videoFrame: 送信する映像フレーム。
  ///                         `nil` を指定した場合は何もしません。
  func send(videoFrame: VideoFrame?)

  // MARK: 終了処理

  /// ストリームの終了処理を行います。
  ///
  /// 以降に到着した frame と renderer の frame / size / switch は配送されません。`VideoRenderer`
  /// の `onDisconnect` は終了処理を呼んだ時点の renderer へ 1 回だけ (main queue へ非同期に)
  /// 配送し、`onRemoved` は配送しません。`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` は
  /// 終了処理の後も呼ばれ得ますが、renderer の `onSwitch` は配送されません。
  func terminate()
}

class BasicMediaStream: MediaStream {
  let handlers = MediaStreamHandlers()

  var peerChannel: PeerChannel

  var streamId: String = ""
  var videoTrackId: String = ""
  var audioTrackId: String = ""
  var creationTime: Date

  var mediaChannel: MediaChannel? {
    // MediaChannel は必ず存在するが、 MediaChannel と PeerChannel の循環参照を避けるために、 PeerChannel は MediaChannel を弱参照で保持している
    // mediaChannel を force unwrapping することも検討したが、エラーによる切断処理中なども安全である確信が持てなかったため、
    // SDK 側で force unwrapping することは避ける
    peerChannel.mediaChannel
  }

  /// frame の受理と renderer 配送の単一所有者です。
  ///
  /// 生成は `init` より前に確定するため、同期 getter と frame の ingress を任意のスレッドから
  /// 呼んでも初回アクセスの競合は起きません。
  let streamOwner = StreamFrameOwner()

  var videoFilter: VideoFilter? {
    get {
      streamOwner.videoFilter
    }
    set {
      streamOwner.videoFilter = newValue
    }
  }

  /// renderer の状態 (`videoRendererAdapter` と owner の `renderer` / `rendererGeneration`) を
  /// 直列化する lock です。
  ///
  /// `videoRenderer` の getter と setter は任意のスレッドから呼ばれるため、adapter の差し替えと
  /// owner の世代の更新を同じ区間で行わないと、両者が食い違ったまま固定されます (以後 frame が
  /// 世代不一致で破棄され続けます)。`videoFilter` は owner の lock 付き storage だけを触るため
  /// この lock は不要です。
  ///
  /// この lock は frame 経路 (ingress と owner queue) からは取らないため、保持中に
  /// `RTCVideoTrack.add` / `remove` を呼んでも映像処理を止めません。ただし `RTCVideoTrack` の
  /// ヘッダには thread 契約の記載が無く、同梱 WebRTC がバイナリのため「呼び出し元を待たない」ことは
  /// リポジトリ内のソースでは検証できません。この前提が崩れた場合は native 呼び出しを lock の外へ
  /// 出す必要があります。
  private let rendererLock = NSLock()

  var videoRenderer: VideoRenderer? {
    get {
      rendererLock.lock()
      defer { rendererLock.unlock() }
      return videoRendererAdapter?.videoRenderer
    }
    set {
      // 利用者 callback (`Logger` の出力 handler を含む) を lock 保持中に呼ばないため、
      // ログは lock を外してから出します。
      rendererLock.lock()
      if let value = newValue {
        // 同じ instance の再設定では世代も adapter も変更しません。onRemoved を配送すると
        // 利用者の描画が止まったままになるためです。ここで public の getter を呼ぶと
        // `rendererLock` を再取得してデッドロックするため、adapter を直接読みます。
        guard videoRendererAdapter?.videoRenderer !== value else {
          rendererLock.unlock()
          return
        }
        // 世代の採番と .added / .removed の投入を先に行います。adapter を native track へ
        // 追加するのはその後で、新 adapter の frame が onAdded より先に配送されないようにします。
        // `terminate()` 済みの場合は採番されないため、設置も adapter の差し替えも行いません。
        guard let generation = streamOwner.setRenderer(self, value) else {
          rendererLock.unlock()
          Logger.debug(
            type: .videoRenderer,
            message: "ignore video renderer: stream owner is invalidated")
          return
        }
        videoRendererAdapter = VideoRendererAdapter(
          videoRenderer: value, owner: streamOwner, generation: generation)
      } else {
        guard videoRendererAdapter != nil else {
          rendererLock.unlock()
          return
        }
        // .removed を投入してから旧 adapter を native track から除去します。
        streamOwner.clearRenderer(self)
        videoRendererAdapter = nil
      }
      rendererLock.unlock()

      // video track を持たない stream では adapter がどのトラックにも登録されず frame が
      // 届かないため、無言で失敗しないように記録します (取り外しの経路では出しません)。
      if newValue != nil, nativeVideoTrack == nil {
        Logger.debug(
          type: .videoRenderer,
          message: "video renderer is set but native video track is nil")
      }
    }
  }

  /// テストから現在の adapter を参照するための accessor です。
  var videoRendererAdapterForTesting: VideoRendererAdapter? {
    rendererLock.lock()
    defer { rendererLock.unlock() }
    return videoRendererAdapter
  }

  /// native track への登録を差し替えるためだけの stored property です。
  ///
  /// ここで `Logger` を呼ぶと利用者の出力 handler が `videoRenderer` を読みに来た場合に
  /// 非再帰 lock で deadlock するため、ログは出しません。
  private var videoRendererAdapter: VideoRendererAdapter? {
    willSet {
      guard let videoTrack = nativeVideoTrack else { return }
      guard let adapter = videoRendererAdapter else { return }
      videoTrack.remove(adapter)
    }
    didSet {
      guard let videoTrack = nativeVideoTrack else { return }
      guard let adapter = videoRendererAdapter else { return }
      videoTrack.add(adapter)
    }
  }

  var nativeStream: RTCMediaStream

  var nativeVideoTrack: RTCVideoTrack? {
    nativeStream.videoTracks.first
  }

  var nativeVideoSource: RTCVideoSource? {
    nativeVideoTrack?.source
  }

  var nativeAudioTrack: RTCAudioTrack? {
    nativeStream.audioTracks.first
  }

  /// `videoEnabled` / `audioEnabled` の確定値と operation の世代を保持する storage です。
  ///
  /// 確定値と native track への反映を同じ lock 区間で更新し、getter が返す値と native track の
  /// `isEnabled` が食い違わないようにします。利用者 callback はこの lock を解放してから呼びます
  /// (保持したまま呼ぶと、callback から `videoEnabled` を読む利用者のコードが非再帰 lock で
  /// deadlock するためです)。
  ///
  /// `CameraState.operationGeneration` と同じく世代で古い書き込みを破棄しますが、別の概念です。
  /// あちらはカメラ状態機械の世代で、こちらは stream ごとの有効フラグの operation の世代です。
  private let enabledLock = NSLock()

  /// 映像の確定値です。初期値は native track の `isEnabled` に合わせ、native track を持たない
  /// stream では以後も値を確定しないため `false` のままです。
  private var storedVideoEnabled = false

  /// 音声の確定値です。初期値は native track の `isEnabled` に合わせ、native track を持たない
  /// stream では以後も値を確定しないため `false` のままです。
  private var storedAudioEnabled = false

  /// 映像 operation の世代の採番に使う値です。operation の開始ごとに進めます。
  private var videoOperationGeneration: UInt64 = 0

  /// 音声 operation の世代の採番に使う値です。operation の開始ごとに進めます。
  private var audioOperationGeneration: UInt64 = 0

  /// 最後に映像の値を確定した operation の世代です。
  ///
  /// 採番 (`videoOperationGeneration`) と確定の判定で別の値を持つのは、値を確定しない operation
  /// (拒否された `setVideoHardMute` など) が後続として開始しても、先行 operation の復元を破棄
  /// しないためです。破棄するのは「後続の operation が実際に値を確定した場合」に限ります。
  private var committedVideoGeneration: UInt64 = 0

  /// 最後に音声の値を確定した operation の世代です。
  private var committedAudioGeneration: UInt64 = 0

  var videoEnabled: Bool {
    get {
      enabledLock.lock()
      defer { enabledLock.unlock() }
      return storedVideoEnabled
    }
    set {
      // 直接代入 1 回を 1 operation とし、入口で世代を取得して確定します。
      let generation = beginVideoOperation()
      commitVideoEnabled(newValue, generation: generation)
    }
  }

  var audioEnabled: Bool {
    get {
      enabledLock.lock()
      defer { enabledLock.unlock() }
      return storedAudioEnabled
    }
    set {
      // 直接代入 1 回を 1 operation とし、入口で世代を取得して確定します。
      let generation = beginAudioOperation()
      commitAudioEnabled(newValue, generation: generation)
    }
  }

  // MARK: - videoEnabled / audioEnabled の operation の直列化

  /// 映像の operation を開始し、この operation の世代を返します。
  ///
  /// 公開 API の入口で呼びます。`MediaChannel.setVideoHardMute` は `await` をまたいで設定と復元を
  /// 行うため、取得した世代を `VideoHardMuteActor.setMute` へ渡し、すべての書き込みを同じ世代で
  /// 確定します。
  func beginVideoOperation() -> UInt64 {
    enabledLock.lock()
    defer { enabledLock.unlock() }
    videoOperationGeneration &+= 1
    return videoOperationGeneration
  }

  /// 音声の operation を開始し、この operation の世代を返します。
  func beginAudioOperation() -> UInt64 {
    enabledLock.lock()
    defer { enabledLock.unlock() }
    audioOperationGeneration &+= 1
    return audioOperationGeneration
  }

  /// 映像の有効値を operation の世代付きで確定します。
  ///
  /// 最後に確定した operation より古い世代の書き込みは破棄します (後続の operation が確定した
  /// 値を先行の operation の書き込みや復元で上書きしないため)。値が変化したときだけ native track
  /// の `isEnabled` を書き換え、利用者 handler と `VideoRenderer` へ通知します。
  /// native track を持たない stream では値を確定せず、storage も handler も変更しません。
  ///
  /// - Returns: この書き込みを確定した場合は `true`、破棄した場合と native track を持たない場合は
  ///   `false`。ストレージの値と書き込む値が同じ場合も確定しているため `true` を返し、通知だけを
  ///   行いません。戻り値は「値が変化したか」ではなく「書き込みが確定したか」を表します。
  @discardableResult
  func commitVideoEnabled(_ value: Bool, generation: UInt64) -> Bool {
    enabledLock.lock()
    guard generation >= committedVideoGeneration, let track = nativeVideoTrack else {
      enabledLock.unlock()
      return false
    }
    let changed = storedVideoEnabled != value
    storedVideoEnabled = value
    committedVideoGeneration = generation
    if changed {
      track.isEnabled = value
    }
    enabledLock.unlock()

    if changed {
      // 通知は確定の後に lock を解放してから行います。並行する operation がこの間に確定した場合、
      // 通知の順序は確定順と一致しないことがありますが、通知順序の入れ替わりは発火回数を変えず、
      // 1 つの operation 内の順序は保たれます。
      handlers.onSwitchVideo?(value)
      streamOwner.submitSwitch(video: value)
    }
    return true
  }

  /// 音声の有効値を operation の世代付きで確定します。
  ///
  /// 判定と通知は `commitVideoEnabled` と同じです。native track を持たない stream では値を
  /// 確定せず、storage も handler も変更しません。
  ///
  /// - Returns: この書き込みを確定した場合は `true`、破棄した場合と native track を持たない場合は
  ///   `false`。ストレージの値と書き込む値が同じ場合も確定しているため `true` を返し、通知だけを
  ///   行いません。戻り値は「値が変化したか」ではなく「書き込みが確定したか」を表します。
  @discardableResult
  func commitAudioEnabled(_ value: Bool, generation: UInt64) -> Bool {
    enabledLock.lock()
    guard generation >= committedAudioGeneration, let track = nativeAudioTrack else {
      enabledLock.unlock()
      return false
    }
    let changed = storedAudioEnabled != value
    storedAudioEnabled = value
    committedAudioGeneration = generation
    if changed {
      track.isEnabled = value
    }
    enabledLock.unlock()

    if changed {
      // 通知は確定の後に lock を解放してから行います (`commitVideoEnabled` と同じ理由)。
      handlers.onSwitchAudio?(value)
      streamOwner.submitSwitch(audio: value)
    }
    return true
  }

  var hasAudioTrack: Bool {
    nativeAudioTrack != nil
  }

  var hasVideoTrack: Bool {
    nativeVideoTrack != nil
  }

  var remoteAudioVolume: Double? {
    get {
      nativeAudioTrack?.source.volume
    }
    set {
      guard let newValue else {
        return
      }
      if let track = nativeAudioTrack {
        var volume = newValue
        if volume < MediaStreamAudioVolume.min {
          volume = MediaStreamAudioVolume.min
        } else if volume > MediaStreamAudioVolume.max {
          volume = MediaStreamAudioVolume.max
        }
        track.source.volume = volume
        Logger.debug(
          type: .mediaStream,
          message: "set audio volume \(volume)")
      }
    }
  }

  func addAudioTrackSink(_ sink: RTCAudioTrackSink) {
    Logger.debug(type: .mediaStream, message: "add audio track sink \(sink)")
    // RTCAudioTrack 側で RTCAudioTrackSink 追加時の重複チェックを行うため
    // iOS SDK 側では重複チェックを行わない。
    nativeAudioTrack?.add(sink)
  }

  func removeAudioTrackSink(_ sink: RTCAudioTrackSink) {
    Logger.debug(type: .mediaStream, message: "remove audio track sink \(sink)")
    nativeAudioTrack?.remove(sink)
  }

  init(peerChannel: PeerChannel, nativeStream: RTCMediaStream) {
    self.peerChannel = peerChannel
    self.nativeStream = nativeStream
    // 確定値を native track の状態で初期化します。
    storedVideoEnabled = nativeStream.videoTracks.first?.isEnabled ?? false
    storedAudioEnabled = nativeStream.audioTracks.first?.isEnabled ?? false
    streamId = nativeStream.streamId
    creationTime = Date()
  }

  /// ストリームの終了処理を行います。
  ///
  /// owner を無効化し、以降に到着した frame と renderer の frame / size / switch を配送しません。
  /// 2 回目以降の呼び出しでは何も配送しません。renderer の `onDisconnect` は main queue へ
  /// 非同期に配送されるため、このメソッドは配送の完了を待ちません。
  func terminate() {
    streamOwner.invalidate(disconnectFrom: peerChannel.mediaChannel)
  }

  func send(videoFrame: VideoFrame?) {
    send(videoFrame: videoFrame, retaining: nil)
  }

  /// 画面キャプチャ経路の画素データの所有者を渡して frame を送信します。
  ///
  /// public な `send(videoFrame:)` と同じ ingress を使います。`ownedFrame` は配送が完了するまで
  /// owner が保持するため、SDK 内部の呼び出し元は `send` の戻り値の後で画素データを参照・変更
  /// しないという `MediaStream.send(videoFrame:)` の契約を満たせばよくなります。
  ///
  /// - Parameters:
  ///   - videoFrame: 送信する映像フレーム
  ///   - ownedFrame: 画素データの所有者。`nil` の場合は owner が保持しません
  func send(
    videoFrame: VideoFrame?,
    retaining ownedFrame: ScreenCaptureController.ScreenCaptureOwnedFrame?
  ) {
    guard let videoFrame else {
      // 破棄条件 1: nil の frame は何もしません。sequence も消費しません。
      Logger.debug(type: .mediaStream, message: "ignore nil video frame")
      return
    }
    // 配送先の解決は owner の lock の外で行います。native へのアクセスを lock 中に
    // 行わないためです。解決の単位 (frame ごと) と executor (呼び出し元) は現行と同じです。
    let videoSource = nativeVideoSource
    streamOwner.submitIngressFrame(
      videoFrame, videoSource: videoSource, retaining: ownedFrame)
  }
}
