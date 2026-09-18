import Foundation
import WebRTC

/// owner queue から main queue へ配送する renderer event です。
///
/// `frame` / `size` / `switch` は世代 (`rendererGeneration`) を持ち、main queue 上で
/// 「現在の世代と renderer」と一致する場合だけ配送します。`added` / `removed` /
/// `disconnect` は世代が進んでいても失いません。
///
/// この型は `@unchecked Sendable` にしません。値は `StreamFrameOwner` の `lock` で
/// 保護した `pendingRendererDeliveries` だけが保持し、owner queue と main queue の
/// 順序で owner 自身が取り出して利用者 callback へ渡します。`@Sendable` closure へ
/// 持ち込まないため、`MediaStream` / `MediaChannel?` / `VideoRenderer` のような
/// 非 Sendable な値を安全に運べます。
enum StreamRendererDelivery {
  /// renderer が設置されました。
  case added(renderer: VideoRenderer, stream: MediaStream)
  /// renderer が取り外されました。
  case removed(renderer: VideoRenderer, stream: MediaStream)
  /// renderer 経由で frame が届きました。`nil` は「frame が `nil` のまま配送する」ことを表します。
  case frame(RTCVideoFrame?, generation: UInt64)
  /// renderer 経由で size が届きました。
  case size(CGSize, generation: UInt64)
  /// 映像の有効 / 無効が変更されました。
  case switchVideo(Bool, generation: UInt64)
  /// 音声の有効 / 無効が変更されました。
  case switchAudio(Bool, generation: UInt64)
  /// stream が終了しました。配送先の renderer は無効化した時点の renderer に固定します
  /// (無効化後に renderer が交換されても、通知先は無効化時の renderer です)。
  case disconnect(renderer: VideoRenderer?, mediaChannel: MediaChannel?)
}

/// `MediaStream` の ingress から owner queue へ運ぶ frame の payload です。
///
/// `@unchecked Sendable` の根拠は次の 3 点に限定します。
///
/// 1. `send(videoFrame:)` の呼び出し側は frame の所有権を SDK へ移し、`send` が戻った後に
///    その `VideoFrame` と保持する画素データを参照・変更しません。SDK 内部の呼び出し元も
///    同じで、`CameraVideoCapturerHandlers.onCapture` が返した frame と画面キャプチャの
///    `ScreenCaptureOwnedFrame` が所有する画素データは配送完了までこの payload が保持します
///    (画面キャプチャ経路は `retainedBacking` で所有者ごと保持します)。`capturer` が持つ
///    可変な `delegate` は SDK が読まず、`VideoFilter` の入力と `RTCVideoSource` への
///    引数として渡すだけです。`RTCVideoFrame` の retain はヘッダで保証された契約ではないため、
///    「retain で寿命が保たれる」ことは根拠に含めません。
/// 2. 書き込みを行う executor は常に 1 つで、所有権は「生成側 → owner queue」の順に 1 回だけ移り、
///    移譲元は以後その値を書き換えません。owner queue 上の処理は payload の frame を読み取り専用で
///    扱います。
/// 3. ingress の frame は呼び出し元 (camera の capture session queue、画面キャプチャの送信キュー、
///    利用者スレッド) から owner queue へ所有権ごと移り、新しい画素データの生成も複製もしません。
struct StreamOwnedFrame: @unchecked Sendable {
  /// 配送する frame です。
  let frame: RTCVideoFrame
  /// frame の生成元 capturer です。`VideoFilter` の入力と `RTCVideoSource` への配送に使います。
  let capturer: RTCVideoCapturer?
  /// 配送先の `RTCVideoSource` です。
  ///
  /// `nativeVideoTrack?.source` を ingress で解決した値です。video track を持たない stream の
  /// frame は payload を作る前に ingress で破棄するため、この値は常に非 `nil` です。
  let videoSource: RTCVideoSource
  /// ingress で採番した sequence です。テストの観測にだけ使い、配送の判定には使いません。
  let ingressSequence: UInt64
  /// 画面キャプチャ経路の画素データの所有者です。配送が完了するまで payload が保持します。
  /// camera 経路と利用者からの直接送信では `nil` です。
  let retainedBacking: ScreenCaptureController.ScreenCaptureOwnedFrame?
}

/// `MediaStream` へ入力される映像 frame の処理と renderer event の配送を直列化する単一所有者です。
///
/// `BasicMediaStream` ごとに 1 つ存在し、次の 2 つの executor を持ちます。
///
/// - owner queue (serial `DispatchQueue`): frame の受理後の処理 (`VideoFilter` の実行と
///   `RTCVideoSource` への配送) と renderer event の順序決定を行います。
/// - main queue: renderer callback の最終配送先です。
///
/// 同期 getter は owner queue を wait せず、`lock` で保護した storage を読みます。
///
/// `@unchecked Sendable` としているのは、可変状態がすべて `lock` で排他された stored property
/// であり、lock の外へ出る非 Sendable な値が次の 3 つに限られるためです。
///
/// - payload (`StreamOwnedFrame`) として owner queue へ 1 回だけ移動する値。実行する
///   executor は owner queue の 1 つだけです。
/// - 利用者 callback へ main queue 上で 1 回だけ渡す renderer event の値。`deliverNextOnMainQueue`
///   が `pendingRendererDeliveries` から取り出した後に owner は参照しません。
/// - `videoFilter` の同期 getter が返す利用者実装の参照。owner は `lock` 区間で読んだ値を
///   そのまま返し、返却後にその値を書き換えません (利用者実装の排他は利用者の責任です)。
///
/// `queue` と `lock` は `let` で差し替えないため、これらの排他は owner の生存中は変わりません。
final class StreamFrameOwner: @unchecked Sendable {
  /// ingress の未処理 frame 数の上限です。
  ///
  /// 画面キャプチャの flight permit は ingress の受理で返るため、後段の滞留を許す量として
  /// 決めます。カメラ 30fps 相当で約 130ms、画面キャプチャの `targetFPS` 上限 120fps では
  /// 約 33ms の滞留を許す値です。処理中の 1 件も未処理数に含めます。
  static let maxPendingFrameCount = 4

  /// renderer 経由で届いた frame の配送待ち件数の上限です。
  ///
  /// 値は `maxPendingFrameCount` と同じ根拠で決めます。main queue が止まっている間も owner queue は
  /// frame を受け取り続けるため、上限が無いと配送要素と、それが保持する frame の画素データが
  /// 無制限に滞留します。上限に達したときは新しく到着した frame を破棄します (ingress と同じ
  /// 「新しい方を捨てる」方針で、判定を投入時に一意に閉じるため)。
  static let maxPendingRendererFrameCount = 4

  /// frame の処理と renderer event の順序決定を行う serial queue です。
  private let queue = DispatchQueue(
    label: "jp.shiguredo.sora.mediaStream.frameOwner")

  /// 可変状態を保護する lock です。owner queue の executor からも同じ lock を使います。
  private let lock = NSLock()

  /// 現在の `VideoFilter` です。実行するのは owner queue 上だけで、読み書きは lock で排他します。
  private var storedVideoFilter: VideoFilter?

  /// renderer の世代です。`setRenderer` / `clearRenderer` だけが進めます。
  private var rendererGeneration: UInt64 = 0

  /// 現在設置されている renderer です。owner はこの参照で renderer の寿命を延長しません。
  private weak var renderer: VideoRenderer?

  /// main queue へ配送していない renderer event です。
  ///
  /// 配送が完了した要素から順に解放します。frame の件数は `maxPendingRendererFrameCount` で
  /// 制限しますが、`added` / `removed` / `disconnect` など frame 以外の要素は件数で制限しません
  /// (トラックの状態変化とライフサイクルでしか発生せず、頻度が frame に比べて十分低いためです)。
  /// main queue が停止している間は、ここが強参照する renderer / `MediaStream` / `MediaChannel?` と
  /// frame の payload が、その上限までの範囲で滞留します。owner queue の処理は利用者 callback の
  /// 完了に依存しないため、滞留するのは配送待ちの要素だけです。
  private var pendingRendererDeliveries: [StreamRendererDelivery] = []

  /// ingress で採番した frame の sequence です。受理したときだけ進めます。
  private var sequence: UInt64 = 0

  /// owner queue へ投入済みで、まだ処理が終わっていない frame の数です。
  private var pendingFrameCount = 0

  /// main queue へ配送していない frame の数です。`maxPendingRendererFrameCount` と比較します。
  private var pendingRendererFrameCount = 0

  /// 上限超過で破棄した frame の数です。条件 1 / 2 / 4 の破棄は含めません。
  ///
  /// `processedSequences` と異なり `#if DEBUG` で囲みません。値は有界な `Int` 1 個で、
  /// production でも「無言で frame が落ちる」経路の診断に使えるためです (破棄ログにも件数を
  /// 出します)。上限の無い配列だけを Debug 構成へ切り分けます。
  private var discardedFrameCount = 0

  /// `terminate()` 済みかどうかです。
  ///
  /// `true` になった後は frame の ingress と renderer 経由の frame / size / switch を受理せず、
  /// 配送もしません。無効化の時点で積まれていた `added` / `removed` / `disconnect` と、無効化の後に
  /// `clearRenderer` が積んだ `removed` も配送します (無効化の時点で未配送だった `added` / `removed` は
  /// `onDisconnect` より先に、無効化の後に取り外した場合の `removed` は `onDisconnect` の後に届きます)。
  private var isInvalidated = false

  #if DEBUG
    /// owner queue で処理まで進んだ frame の `sequence` です。テストの観測にだけ使います。
    ///
    /// 記録と保持は Debug 構成だけで行います。production (Release) では frame ごとの記録も
    /// 保持もしないため、`processedSequencesForTesting` も Debug 構成でのみ参照できます。
    /// 上限の無い配列を frame ごとに伸ばす観測用の状態を production に持ち込まないための
    /// 切り分けです。
    private var processedSequences: [UInt64] = []
  #endif

  /// `nil` の capturer を `RTCVideoSource` へ渡すためのダミーです。
  ///
  /// `RTCVideoSource.capturer(_:didCapture:)` の第 1 引数の扱いはヘッダに契約がありません。
  /// SDK は `capturer` を `VideoFilter` の入力と `RTCVideoSource` への引数にだけ使い、
  /// `RTCVideoCapturer` の `delegate` を読まないため、`nil` の場合の固定 instance として
  /// このダミーを共有します。
  private nonisolated(unsafe) static let dummyCapturer = RTCVideoCapturer()

  // MARK: - 映像フィルター

  /// 現在の `VideoFilter` です。get / set は lock で排他します。
  ///
  /// 交換は受理済み frame の実行順とは同期しません。各 frame が使う filter は owner queue が
  /// 配送直前に lock 区間で読んだ値として一意に決まるため、1 つの frame が 2 つの filter を
  /// 通ることはありません。
  var videoFilter: VideoFilter? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedVideoFilter
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedVideoFilter = newValue
    }
  }

  // MARK: - frame の ingress

  /// frame を ingress へ投入します。
  ///
  /// `send(videoFrame:)` の同期呼び出しから呼びます。`send` の戻り値を待たせないため、
  /// filter の実行と `RTCVideoSource` への配送の完了は待ちません。
  ///
  /// - Parameters:
  ///   - frame: 配送する frame
  ///   - videoSource: ingress が lock の外で解決した配送先。`nil` の場合は配送せず破棄します
  ///     (`sequence` を消費せず、`discardedFrameCount` にも加算しません)
  ///   - ownedFrame: 画面キャプチャ経路の画素データの所有者。配送が完了するまで保持します
  func submitIngressFrame(
    _ frame: VideoFrame,
    videoSource: RTCVideoSource?,
    retaining ownedFrame: ScreenCaptureController.ScreenCaptureOwnedFrame?
  ) {
    switch frame {
    case .native(let capturer, let nativeFrame):
      lock.lock()
      // 破棄条件 4: 無効化済みの stream の frame は配送せずに破棄します。
      if isInvalidated {
        lock.unlock()
        Logger.debug(
          type: .mediaStream,
          message: "discard video frame: stream owner is invalidated")
        return
      }
      // 破棄条件 2: video track を持たない stream の frame は配送せずに破棄します。
      guard let videoSource else {
        lock.unlock()
        Logger.debug(
          type: .mediaStream,
          message: "discard video frame: stream has no video source")
        return
      }
      // 破棄条件 3: 後段の滞留が上限に達している場合は新しく到着した frame を破棄します。
      guard pendingFrameCount < Self.maxPendingFrameCount else {
        discardedFrameCount += 1
        let discardedFrameCount = discardedFrameCount
        lock.unlock()
        Logger.debug(
          type: .mediaStream,
          message:
            "discard video frame: pending frame count reached \(Self.maxPendingFrameCount), discarded \(discardedFrameCount)"
        )
        return
      }
      // 採番・未処理数の加算・payload の生成・ owner queue への投入を同じ lock 区間で行います。
      // 分けると、並行する `send` が採番順と実行順で入れ替わります (採番だけ先に終えた
      // スレッドが投入で後れを取ると、owner queue は番号の逆順に処理します)。
      sequence &+= 1
      let ingressSequence = sequence
      pendingFrameCount += 1
      let payload = StreamOwnedFrame(
        frame: nativeFrame,
        capturer: capturer,
        videoSource: videoSource,
        ingressSequence: ingressSequence,
        retainedBacking: ownedFrame)
      // `queue.async` は非同期のため、lock を保持したまま呼んでも自己デッドロックしません。
      queue.async { [self] in
        // 未処理数の減算は owner queue で処理が終わった時点で行います。
        process(payload)
      }
      lock.unlock()
    }
  }

  /// owner queue 上で filter を実行し、`RTCVideoSource` へ配送します。
  ///
  /// 破棄経路でも未処理数を必ず 1 回減算するため、入口で `defer` します。
  private func process(_ payload: StreamOwnedFrame) {
    defer {
      lock.lock()
      pendingFrameCount -= 1
      lock.unlock()
    }

    // 無効化の判定と filter の読み出しは同じ lock 区間で行います。filter は配送直前に読むため、
    // 交換と frame 入力が競合しても、この frame が使う filter はここで読んだ値に一意に決まります。
    lock.lock()
    let invalidated = isInvalidated
    let filter = storedVideoFilter
    lock.unlock()

    if invalidated {
      Logger.debug(
        type: .mediaStream,
        message: "discard accepted video frame: stream owner is invalidated")
      return
    }

    let frame = VideoFrame.native(capturer: payload.capturer, frame: payload.frame)
    let filteredFrame = filter?.filter(videoFrame: frame) ?? frame

    #if DEBUG
      // この記録はテストの観測にだけ使うため、Debug 構成だけで行います (production では
      // 誰も読まない配列を frame ごとに伸ばさないため)。
      lock.lock()
      processedSequences.append(payload.ingressSequence)
      lock.unlock()
    #endif

    switch filteredFrame {
    case .native(let capturer, let nativeFrame):
      payload.videoSource.capturer(
        capturer ?? Self.dummyCapturer, didCapture: nativeFrame)
    }
  }

  // MARK: - renderer の設置と除去

  /// renderer を設置し、採番した世代を返します。
  ///
  /// 現在の renderer と同一 instance の場合は世代も配送要素も変更しません。同一 instance に
  /// `.added` と `.removed` の両方を積むと、`onRemoved` の配送で `VideoView` の描画が止まり、
  /// 以後 `onAdded` が来ないためです。
  ///
  /// 以前の renderer が既に解放されている場合は `.removed` を積まず、`.added` だけを積みます。
  ///
  /// 無効化済みの場合は設置せず `nil` を返します (終了した stream に `onAdded` だけを配送すると、
  /// 対になる `onDisconnect` が届かない renderer が生まれるためです)。取り外しは
  /// `clearRenderer` で引き続き行えます。
  ///
  /// - Returns: 採番した世代。無効化済みの場合は `nil`。
  @discardableResult
  func setRenderer(_ stream: MediaStream, _ newRenderer: VideoRenderer) -> UInt64? {
    // このメソッドは `BasicMediaStream` の `rendererLock` 保持中に呼ばれる。`Logger` の出力 handler は
    // 同期で呼ばれるため、ここでログを出すと handler が `videoRenderer` を読みに来た場合に非再帰
    // lock で deadlock する。無効化済みの通知は lock を外した呼び出し元が行う。
    lock.lock()
    if isInvalidated {
      lock.unlock()
      return nil
    }
    if let renderer, renderer === newRenderer {
      lock.unlock()
      return rendererGeneration
    }
    rendererGeneration &+= 1
    if let renderer {
      appendDeliveryLocked(.removed(renderer: renderer, stream: stream))
    }
    renderer = newRenderer
    appendDeliveryLocked(.added(renderer: newRenderer, stream: stream))
    let generation = rendererGeneration
    lock.unlock()
    return generation
  }

  /// 現在の renderer を取り外します。
  ///
  /// 世代は常に進め、設置中の adapter から届く frame / size を破棄します。
  func clearRenderer(_ stream: MediaStream) {
    lock.lock()
    defer { lock.unlock() }
    rendererGeneration &+= 1
    if let renderer {
      appendDeliveryLocked(.removed(renderer: renderer, stream: stream))
    }
    renderer = nil
  }

  // MARK: - renderer からの入力

  /// renderer 経由で届いた frame を配送します。
  ///
  /// 無効化後は受理しません (`deliverNextOnMainQueue` での破棄に加え、payload の生成も
  /// owner queue への投入も行いません)。配送待ちの frame が上限に達している場合は、新しく
  /// 到着した frame を破棄します (ingress と同じ「新しい方を捨てる」方針です)。
  func submitRendererFrame(_ frame: RTCVideoFrame?, generation: UInt64) {
    lock.lock()
    if isInvalidated {
      lock.unlock()
      Logger.debug(
        type: .videoRenderer,
        message: "discard renderer frame: stream owner is invalidated")
      return
    }
    guard pendingRendererFrameCount < Self.maxPendingRendererFrameCount else {
      lock.unlock()
      Logger.debug(
        type: .videoRenderer,
        message:
          "discard renderer frame: pending renderer frame count reached \(Self.maxPendingRendererFrameCount)"
      )
      return
    }
    pendingRendererFrameCount += 1
    appendDeliveryLocked(.frame(frame, generation: generation))
    lock.unlock()
  }

  /// renderer 経由で届いた size を配送します。
  ///
  /// 無効化後は受理しません。size はトラックの解像度が変わったときだけ届くため件数の上限は
  /// 設けません。
  func submitRendererSize(_ size: CGSize, generation: UInt64) {
    lock.lock()
    guard !isInvalidated else {
      lock.unlock()
      Logger.debug(
        type: .videoRenderer,
        message: "discard renderer frame size: stream owner is invalidated")
      return
    }
    appendDeliveryLocked(.size(size, generation: generation))
    lock.unlock()
  }

  /// 映像の有効 / 無効の変更を配送します。
  ///
  /// 無効化後は受理しません。
  func submitSwitch(video isEnabled: Bool) {
    lock.lock()
    guard !isInvalidated else {
      lock.unlock()
      Logger.debug(
        type: .videoRenderer,
        message: "discard video switch: stream owner is invalidated")
      return
    }
    appendDeliveryLocked(.switchVideo(isEnabled, generation: rendererGeneration))
    lock.unlock()
  }

  /// 音声の有効 / 無効の変更を配送します。
  ///
  /// 無効化後は受理しません。
  func submitSwitch(audio isEnabled: Bool) {
    lock.lock()
    guard !isInvalidated else {
      lock.unlock()
      Logger.debug(
        type: .videoRenderer,
        message: "discard audio switch: stream owner is invalidated")
      return
    }
    appendDeliveryLocked(.switchAudio(isEnabled, generation: rendererGeneration))
    lock.unlock()
  }

  // MARK: - 無効化

  /// この owner を無効化し、`onDisconnect` を 1 回だけ配送します。
  ///
  /// 配送先の renderer は無効化した時点の renderer に固定します (`renderer` は弱参照のため、
  /// 配送までに解放された場合は配送しません)。無効化以降は frame の ingress も renderer 経由の
  /// frame / size / switch も受理しません。
  ///
  /// owner queue は wait しないため、呼び出し元 (capture session queue や
  /// `sendVideoFrameQueue`) と利用者 callback の再入で deadlock しません。
  /// 2 回目以降の呼び出しでは何も配送しません。
  func invalidate(disconnectFrom mediaChannel: MediaChannel?) {
    lock.lock()
    defer { lock.unlock() }
    guard !isInvalidated else {
      return
    }
    isInvalidated = true
    // 配送先を無効化した時点で固定します。配送時に現在の renderer を読み直すと、無効化の後に
    // renderer を nil にした場合は配送されず、別の renderer を設置した場合は `onAdded` を
    // 受け取っていない renderer に `onDisconnect` が届きます。
    appendDeliveryLocked(.disconnect(renderer: renderer, mediaChannel: mediaChannel))
  }

  // MARK: - 配送

  /// 配送要素を積み、owner queue を経由して main queue へ 1 件配送します。lock 保持中に呼びます。
  ///
  /// `pendingRendererDeliveries` は lock、配送の順序は owner queue、最終配送は main queue が
  /// 担います。owner queue を経由させるのは、複数の executor から投入された event の順序を
  /// 1 つの直列 executor で確定するためです。
  ///
  /// main queue の block は owner だけを capture します。`pendingRendererDeliveries` が保持する
  /// 非 Sendable な値 (renderer / `MediaStream` / `MediaChannel?` / frame の payload) は
  /// `@Sendable` closure へ持ち込めないためです。
  private func appendDeliveryLocked(_ delivery: StreamRendererDelivery) {
    pendingRendererDeliveries.append(delivery)
    queue.async { [self] in
      DispatchQueue.main.async { [self] in
        deliverNextOnMainQueue()
      }
    }
  }

  /// main queue 上で、配送していない先頭の renderer event を 1 件配送します。
  ///
  /// `frame` / `size` / `switch` は、現在の世代と renderer を同じ lock 区間で読み、世代が
  /// 一致する場合だけ配送します。owner queue での判定だけに依存しません。
  private func deliverNextOnMainQueue() {
    lock.lock()
    guard !pendingRendererDeliveries.isEmpty else {
      lock.unlock()
      return
    }
    let delivery = pendingRendererDeliveries.removeFirst()
    if case .frame = delivery {
      // 配送待ちの frame 数の減算は、配送要素を取り出した時点で行います。
      pendingRendererFrameCount -= 1
    }
    let currentRenderer = renderer
    let currentGeneration = rendererGeneration
    let invalidated = isInvalidated
    lock.unlock()

    // 無効化後は frame / size / switch を配送しません。added / removed / disconnect は
    // 世代や無効化にかかわらず配送します (無効化時に未配送の added / removed を先に届けてから
    // onDisconnect を 1 回だけ届けるためです)。
    if invalidated {
      switch delivery {
      case .added, .removed, .disconnect:
        break
      case .frame, .size, .switchVideo, .switchAudio:
        Logger.debug(
          type: .videoRenderer,
          message: "ignore renderer event: stream owner is invalidated")
        return
      }
    }

    switch delivery {
    case .added(let target, let stream):
      target.onAdded(from: stream)

    case .removed(let target, let stream):
      target.onRemoved(from: stream)

    case .disconnect(let target, let mediaChannel):
      // 配送先は invalidate が固定した renderer です。配送までに解放されていた場合は
      // 配送できません (`.removed` と同じ扱い)。
      guard let target else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore disconnect: video renderer is already released")
        return
      }
      target.onDisconnect(from: mediaChannel)

    case .frame(let frame, let generation):
      guard let currentRenderer else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video frame: no video renderer set")
        return
      }
      guard generation == currentGeneration else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video frame: generation \(generation) is not current")
        return
      }
      let videoFrame = frame.map {
        VideoFrame.native(capturer: nil, frame: $0)
      }
      currentRenderer.render(videoFrame: videoFrame)

    case .size(let size, let generation):
      guard let currentRenderer else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video frame size: no video renderer set")
        return
      }
      guard generation == currentGeneration else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video frame size: generation \(generation) is not current")
        return
      }
      currentRenderer.onChange(size: size)

    case .switchVideo(let isEnabled, let generation):
      guard let currentRenderer else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video switch: no video renderer set")
        return
      }
      guard generation == currentGeneration else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore video switch: generation \(generation) is not current")
        return
      }
      currentRenderer.onSwitch(video: isEnabled)

    case .switchAudio(let isEnabled, let generation):
      guard let currentRenderer else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore audio switch: no video renderer set")
        return
      }
      guard generation == currentGeneration else {
        Logger.debug(
          type: .videoRenderer,
          message: "ignore audio switch: generation \(generation) is not current")
        return
      }
      currentRenderer.onSwitch(audio: isEnabled)
    }
  }

  // MARK: - テスト用

  /// owner queue へ投入済みの event の処理完了を待ちます。テスト専用の seam です。
  ///
  /// main queue への配送は待ちません (main queue の配送は `XCTestExpectation` で待ちます)。
  /// owner queue 自身の executor から呼ぶと自己デッドロックするため、テストの executor からのみ
  /// 呼びます。
  func drainForTesting() {
    queue.sync {}
  }

  /// ingress で採番した最後の sequence です。受理後に無効化で破棄された frame も含みます。
  var lastAcceptedSequenceForTesting: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return sequence
  }

  #if DEBUG
    /// owner queue で処理まで進んだ frame の sequence を実行順に並べた配列です。
    ///
    /// 上限超過で破棄された frame と、受理後に無効化で破棄された frame は含みません。
    /// 記録も保持も Debug 構成だけで行うため、この accessor も Debug 構成でのみ参照できます
    /// (テストは Debug 構成で実行します)。
    var processedSequencesForTesting: [UInt64] {
      lock.lock()
      defer { lock.unlock() }
      return processedSequences
    }
  #endif

  /// 上限超過で破棄した frame の数です。
  var discardedFrameCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return discardedFrameCount
  }
}
