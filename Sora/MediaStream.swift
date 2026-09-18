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
public final class MediaStreamHandlers {
  /// 映像トラックが有効または無効にセットされたときに呼ばれるクロージャー
  ///
  /// `MediaChannel.setVideoHardMute(true)` の経路では `VideoHardMuteActor` の executor で、
  /// `MediaChannel.setVideoSoftMute`、`MediaChannel.setVideoHardMute(false)` の成功時、
  /// `MediaStream.videoEnabled` への直接代入では呼び出し側の executor で呼ばれます。
  ///
  /// `VideoRenderer.onSwitch(video:)` の配送 executor は main queue のため、このクロージャーと
  /// renderer の相対順序は保証されません。
  public var onSwitchVideo: ((_ isEnabled: Bool) -> Void)?

  /// 音声トラックが有効または無効にセットされたときに呼ばれるクロージャー
  ///
  /// `VideoRenderer.onSwitch(audio:)` の配送 executor は main queue のため、このクロージャーと
  /// renderer の相対順序は保証されません。
  public var onSwitchAudio: ((_ isEnabled: Bool) -> Void)?

  /// 初期化します。
  public init() {}
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
  /// setter は映像レンダラーの `onSwitch(video:)` の配送完了を待ちません。getter は即時に
  /// 現在のトラックの状態を返します。
  var videoEnabled: Bool { get set }

  /// 音声の可否。
  /// `false` をセットすると、サーバーへの音声の送受信を停止します。
  /// `true` をセットすると送受信を再開します。
  ///
  /// サーバーへの送受信を停止しても、マイクはミュートされませんので注意してください。
  ///
  /// setter は映像レンダラーの `onSwitch(audio:)` の配送完了を待ちません。
  var audioEnabled: Bool { get set }

  /// 映像トラックを保持している場合は `true` を返します。
  ///
  /// 映像ミュート時に映像トラックが存在するかチェックするために使用されます。
  /// ミュート時に実行する videoEnabled setter は返り値やエラーを返さないため、
  /// 呼び出し側へエラーを通知するために必要となります。
  var hasVideoTrack: Bool { get }

  /// 音声トラックを保持している場合は `true` を返します。
  ///
  /// 音声ミュート時に音声トラックが存在するかチェックするために使用されます。
  /// ミュート時に実行する audioEnabled setter は返り値やエラーを返さないため、
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

  var videoEnabled: Bool {
    get {
      nativeVideoTrack?.isEnabled ?? false
    }
    set {
      guard videoEnabled != newValue else {
        return
      }
      if let track = nativeVideoTrack {
        track.isEnabled = newValue
        handlers.onSwitchVideo?(newValue)
        streamOwner.submitSwitch(video: newValue)
      }
    }
  }

  var audioEnabled: Bool {
    get {
      nativeAudioTrack?.isEnabled ?? false
    }
    set {
      guard audioEnabled != newValue else {
        return
      }
      if let track = nativeAudioTrack {
        track.isEnabled = newValue
        handlers.onSwitchAudio?(newValue)
        streamOwner.submitSwitch(audio: newValue)
      }
    }
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
