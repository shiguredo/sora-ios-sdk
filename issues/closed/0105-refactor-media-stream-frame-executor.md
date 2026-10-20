# MediaStream の映像フレーム処理 executor を単一化する

- Created: 2026-08-27
- Completed: 2026-09-18
- Priority: Medium
- Branch: feature/refactor-media-stream-frame-executor
- Polished: 2026-09-17

## 優先度根拠

- `BasicMediaStream.send(videoFrame:)` は呼び出し元の executor 上で `VideoFilter` を実行し `RTCVideoSource` へ frame を渡す (`Sora/MediaStream.swift:273-287`)。filter の実行順序と交換、`terminate()` 後の破棄がコード上の契約になっていない。
- 公開 API を増やさない内部構造の整理だが、`VideoFilter` と renderer callback の実行 executor という利用者が観測できる契約が変わるため Medium とする。
- `0027` / `0110` / `0122` が本 issue の完了を前提にしており、`0103` / `0104` が frame 経路の未決事項を本 issue へ委譲している。

## 目的

`MediaStream` へ入力される映像 frame の受理から `VideoFilter` の実行、`RTCVideoSource` への配送までを、stream ごとの ordered owner queue に集約する。renderer の add / frame / size / switch / remove / disconnect は owner queue で順序を決定し、最終配送 executor を main queue に統一する (現行の呼び出し元 executor からの変更)。

カメラ、画面キャプチャ、利用者の直接送信が並行しても filter の実行順序が崩れず、`terminate()` または切断の後に到着した frame が `RTCVideoSource` と renderer へ配送されない構造にする。音声の送受信経路と audio sink は変更しない。公開 API のシグネチャは変更しないが、filter の実行 executor、配送の非同期化、上限超過の frame 破棄という観測挙動を変える refactor である。

## 現状

### frame の入力経路

`Sora/MediaStream.swift:273-287` の `BasicMediaStream.send(videoFrame:)` は、呼び出し元の executor 上で `videoFilter` を読み、`filter(videoFrame:)` を実行し (276 行)、`nativeVideoSource?.capturer(_:didCapture:)` を呼ぶ (281-283 行)。dispatch も actor hop もない。`nativeVideoSource` は `nativeVideoTrack?.source` (`:178-180`) であり、video track が無ければ frame は無言で破棄される。`capturer` が `nil` の場合は `nonisolated(unsafe) static let dummyCapturer` (272 行) を使う。

入力元は 3 つで、実行される executor が異なる。

- `CameraVideoCapturerDelegate.capturer(_:didCapture:)` (`Sora/CameraVideoCapturer.swift:1578-1593`)。`CameraVideoCapturer.handlers.onCapture` を実行してから `stream.send(videoFrame:)` を呼ぶ (1587-1591 行)。libwebrtc の capture session queue 上で発火する前提であり、`Sora/CameraVideoCapturer.swift:674-676` に「upstream の実装を確認できないため、現行の挙動を前提とする」と明記されている。camera queue への hop は `CameraQueueExecutor` (`:643-653`) に閉じている。
- `ScreenCaptureController.processOwnedFrame(_:)` (`Sora/ScreenCapture.swift:682-728`)。serial queue `sendVideoFrameQueue` (`:238-239`) 上で transformer、`VideoFrame` の生成、capture ID の照合を行ってから `senderStream.send(videoFrame:)` を呼ぶ (727 行)。
- 利用者による `MediaStream.send(videoFrame:)` の直接呼び出し (公開 protocol の要件 `Sora/MediaStream.swift:109`)。任意の executor。

同一 stream で camera と screen capture が同時に動くことは `MediaChannel` の guard で禁止されている (`Sora/MediaChannel.swift:1500-1522`)。並行し得るのは「public send × camera」「public send × screen capture」「別 stream で同じ `VideoFilter` instance を共有した場合」である。

### filter と renderer

`videoFilter` は保護のない stored property で (`Sora/MediaStream.swift:134`)、取得と変更に同期がない。`VideoFilter` は `AnyObject` だけの protocol で (`Sora/VideoCapturer.swift:7-12`)、`Sendable` も executor 契約もない。`VideoFilter.filter(_:)` は非 optional を返し drop 経路を持たない。

`videoRenderer` の追加・除去、`videoEnabled` / `audioEnabled` の変更、`terminate()` は、renderer callback を呼び出し元の executor で直接呼ぶ (`Sora/MediaStream.swift:136-151, 186-216, 268-270`)。`VideoRendererAdapter` が main queue へ hop するのは `setSize` / `renderFrame` だけで (`Sora/VideoRenderer.swift:74-96`)、`onAdded` / `onRemoved` / `onSwitch(video:)` / `onSwitch(audio:)` / `onDisconnect` は呼び出し元の executor で同期に呼ばれる。この 2 経路のため renderer event の因果順序は保証されていない。`terminate()` は `onDisconnect` を呼ぶだけで、adapter を native track から除去しない。

renderer frame は `RTCVideoTrack` の `add(_:)` で登録した adapter へ libwebrtc から配送される (登録は `Sora/MediaStream.swift:153-170`、adapter の定義は `Sora/VideoRenderer.swift:64-96`)。`BasicMediaStream.send(videoFrame:)` はこの経路に関与しないため、SDK 側の ingress の sequence を renderer frame に付与できず、`send` の復帰と renderer callback の順序も保証されない。

### frame の所有

`VideoFrame` は `.native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)` の 1 ケースだけである (`Sora/VideoFrame.swift:10-15`)。pixel buffer を保持するケースは無く、`init?(from: CMSampleBuffer)` も `RTCCVPixelBuffer` に包んだ `RTCVideoFrame` を作る (52-63 行)。`VideoFrame` / `RTCVideoFrame` / `RTCCVPixelBuffer` / `RTCVideoCapturer` は `Sendable` ではない (`WebRTC.xcframework` のヘッダに `NS_SWIFT_SENDABLE` はない)。`RTCVideoFrame` の `timeStamp` (90kHz) は assign 可能であり、ヘッダには retain の記載も無い。

既存の unchecked 越境は 2 つある。`VideoRendererFrameEvent: @unchecked Sendable` が `VideoFrame` を main queue へ渡し (`Sora/VideoRenderer.swift:29-37, 93-95`)、`SenderStreamBox: @unchecked Sendable` が `MediaStream` を actor 境界へ渡す (`Sora/VideoMute.swift:22-28`)。

### 終了と再ネゴシエーション

`terminate()` は公開 protocol の要件であり (`Sora/MediaStream.swift:114`)、`PeerChannel` が redirect 受理時 (`Sora/PeerChannel.swift:1691-1701`) と切断時 (`:1834-1837`) に全 stream へ呼ぶ。

`ConnectionLifecycleState.transportEpoch` は frame 経路から参照されていない (`Sora/ConnectionLifecycle.swift:14, 104-107`、`Sora/PeerChannel.swift:366-369`)。

re-offer / re-answer の再ネゴシエーションでは stream を作り直さず (`Sora/PeerChannel.swift:1172-1177`)、`didAdd` も同じ stream ID の stream が既にある場合は無視される (`:2022-2028`)。

### 既存テストと CI

`SoraTests/ScreenCaptureFrameGenerationTests.swift` は `sendVideoFrameQueue` を drain した直後に `VideoFilter` の到達回数を assert する (648-650, 663-665, 708-709 行ほか)。`SoraTests/DummyVideoCapturer.swift:148` は main RunLoop の Timer から `send(videoFrame:)` を呼び、`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `RpcE2ETests` がこれを使う。`frameCount` は `SendonlyE2ETests.swift:62`、`SendrecvE2ETests.swift:138, 140`、`SimulcastE2ETests.swift:225` で `> 0` の比較に使われている。

CI は Simulator (`iPhone 17 Pro`) で `xcodebuild build-for-testing` → `test-without-building` を実行する (`.github/workflows/ci.yml:53-89`、`SWIFT_VERSION=6`)。実機でテストを実行する job は無い (`build.yml:24-35` は device 向けの build のみ)。`Makefile` にテストターゲットは無い。

`Sora/MediaStream.swift:102-109` の doc は「`nil` を指定すると空の映像フレームを送信します」と書くが、実装 (285-286 行) は何もしない。

## 前提となる issue

- `0100` / `0101` / `0102` / `0103` / `0104` (完了): 「単一所有者 + 直列 ingress + lock 付き snapshot storage」の方式を確立した。本 issue は同じ方式を `BasicMediaStream` の frame 処理と renderer 配送へ適用する。
- `0095` / `0097` (完了): redirect と切断で旧 stream を終端して frame の混入を防ぐ防御を確定した。本 issue はこの防御を executor の無効化で維持し、`transportEpoch` は使わない。
- `0104` (完了): `ScreenCaptureOwnedFrame` を追加し、`@unchecked Sendable` の根拠を「Create ルールの所有権」と「callback から送信キューへの 1 回の所有権移動」に限定した。`:166` で「`0105` が内部 handle を導入した場合は `ScreenCaptureOwnedFrame` を `0105` の ingress へ接続する変更を `0105` で行う」と委譲している。本 issue は `ScreenCaptureOwnedFrame` の移動を変更せず、`send` の中で新しい payload に詰め替える (「frame の ingress と所有表現」)。
- `0103` (完了): 「delegate callback では frame と capturer identity を取得し、`0105` が ordered frame ingress を導入済みならそこへ渡す」(`:141`) とし、「`SenderStreamBox` は `0105` の完了まで維持する」(`:142`) と確定した。本 issue は delegate の接続先を `send` のまま維持し、`SenderStreamBox` を置き換えない (「スコープ外」)。
- `0098` (完了): 「`0105` が stream 用の内部 handle を導入した場合は、それを actor へ渡す方式へ変更できる」とした (`:50`)。本 issue の owner は frame と renderer 配送の内部 handle であり、actor へ渡す `MediaStream` の扱いは変更しない。
- `0136` (完了): `setVideoHardMute(true)` の `videoEnabled` の設定と復元を `VideoHardMuteActor` の executor へ移し、`onSwitchVideo` の発火回数と順序を確定した (`:49-69`)。本 issue は有効フラグの書き込みを変更せず、`MediaStreamHandlers` の executor も変更しない (「スコープ外」)。
- `0163` (open): `videoEnabled` / `audioEnabled` の変更を operation 単位で直列化する。本 issue から切り出した作業であり、`0136` が残した排他を扱う。frame の処理順序と executor は本 issue が扱い、`0163` は確定値の直列化だけを扱う。`0163` は本 issue と同じ `MediaStream.videoEnabled` / `audioEnabled` setter (`Sora/MediaStream.swift:186-216`) を変更するため、どちらかを先行させ、もう一方を rebase して実装する。
- `0154` (open): `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` の closure 排他を扱う。`MediaStreamHandlers` は `0154` の対象として挙げられていない (「スコープ外」で `0154` へ移管する)。
- `0027` (open): 「`0105` で frame ownership、stream epoch、sequence、全 renderer callback の ordered ingress を確立する」として本 issue を前提にしている (`:41, :56`)。本 issue は sequence と renderer 配送の順序付けを提供し、stream epoch は導入しない。
- `0110` (open): stream の frame event の順序保証を本 issue に委ねている (`:41, :86`)。
- `0122` (open): 「`0105` の ordered frame / renderer ingress が実装済みであること」(`:14`) を前提にし、「renderer callback は `0105` の sequence / epoch 付き ordered ingress だけから配送する」(`:36`) としている。
- `0119` / `0151` (open): Thread Sanitizer の CI 基盤は未整備で、手動 TSan 実行は `0151` の競合で失敗する。

## 設計方針

### StreamFrameOwner

`Sora/StreamFrameOwner.swift` を新設し、`BasicMediaStream` ごとに 1 つの owner を持たせる。

- `final class StreamFrameOwner: @unchecked Sendable`。非 Sendable な値は lock 区間の中だけで保持し、利用者 callback へは main queue 上で 1 回だけ移して渡す (渡した後に owner は参照しない)。`owner queue` 上だけで完結する値 (filter の実行と source への配送に使う `RTCVideoSource` / `RTCVideoFrame`) はそのまま owner queue 上で読む。
- serial `DispatchQueue` (`label: "jp.shiguredo.sora.mediaStream.frameOwner"`) を持ち、frame の受理、`VideoFilter` の実行、`RTCVideoSource` への配送、renderer event の配送をこの queue 上で直列に行う。`CameraStateOwner` (`Sora/CameraStateOwner.swift`) と同じ「serial queue + lock 付き storage」方式とし、同期 getter は owner queue を wait しない。
- 保持する状態は次に限定し、すべて `NSLock` で保護する。`var videoFilter: VideoFilter?`、`var rendererGeneration: UInt64` と `weak var renderer: VideoRenderer?`、`var pendingRendererDeliveries: [StreamRendererDelivery]`、`var sequence: UInt64` (frame の ingress 用)、`var pendingFrameCount: Int`、`var discardedFrameCount: Int`、`var isInvalidated: Bool`、`var processedSequences: [UInt64]` (テストの観測用。`#if DEBUG` で囲み、production では記録も保持もしない)。`RTCVideoSource` は payload ごとに ingress で解決して渡す (field に保持しない)。
- owner が `MediaStream` を強参照するのは `pendingRendererDeliveries` の `added` / `removed` 要素だけで、`MediaChannel?` は `disconnect` 要素だけが保持し、どちらも配送完了時に解放する。恒久参照はしない。この一時的な強参照により、`BasicMediaStream` の解放は pending の drain まで遅延する。配送時に弱参照を解決し直さないため、`BasicMediaStream` や `MediaChannel` が先に解放されても callback の引数を失わない。
- owner を強参照するのは `BasicMediaStream` だけとする。`VideoRendererAdapter` は owner を弱参照する。owner queue へ投入する block は owner を強参照し、投入済みの event は `BasicMediaStream` の解放後も完了させる。`deinit` では queue へ何も投入しない。
- `BasicMediaStream` は owner を生成するだけとし、`RTCVideoSource` は ingress ごとに `nativeVideoTrack?.source` を読んで payload に載せる。現行 `send` も呼び出しのたびにこの解決を行っており (`Sora/MediaStream.swift:281`、`:178-180`)、読み出しの単位 (frame ごと) と executor (呼び出し元 thread) は現行と同じである。ただし経路内の相対位置は変わり、現行は filter の実行後 (`:276`)、本設計は ingress なので filter の実行前になる。送信 stream は `NativePeerChannelFactory.createNativeSenderStream` が `nativeStream.addVideoTrack(videoTrack)` を済ませてから `BasicMediaStream` を生成する (`Sora/NativePeerChannelFactory.swift:276-285`、`Sora/PeerChannel.swift:735-746`)。`nativeStream` は `var` 宣言が `Sora/MediaStream.swift:172`、代入が `init` の `:263` の 1 箇所だけであり、`let` でも `private(set)` でもないため「init 後に再代入されない」ことはコンパイラ保証ではなく実装規約である。libwebrtc 所有の受信 stream では track 構成が後から変わり得るため、source を init 時に固定しない。`streamOwner` は `let streamOwner = StreamFrameOwner()` として宣言時に初期化する (同期 getter と ingress を任意のスレッドから呼んでも初回アクセスの競合を作らない)。
- API は `submitIngressFrame(_ frame: VideoFrame, videoSource: RTCVideoSource?, retaining ownedFrame: ScreenCaptureController.ScreenCaptureOwnedFrame?)` (ingress。`send` の同期呼び出しで受け取る。`videoSource` は ingress が lock の外で解決した配送先)、`videoFilter` の get / set、`setRenderer(_ stream: MediaStream, _ renderer: VideoRenderer) -> UInt64?` (採番した generation を返し、無効化済みの場合は `nil`) / `clearRenderer(_ stream: MediaStream)`、`submitRendererFrame(_ frame: RTCVideoFrame?, generation: UInt64)` / `submitRendererSize(_ size: CGSize, generation: UInt64)`、`submitSwitch(video:)` / `submitSwitch(audio:)`、`invalidate(disconnectFrom: MediaChannel?)`、`drainForTesting()`、`lastAcceptedSequenceForTesting` / `processedSequencesForTesting` / `discardedFrameCountForTesting` (テスト用) とする。
- `internal static let maxPendingFrameCount = 4` を上限とする。未処理数は permit では制限されない (permit は ingress の受理で返る) ため、後段の滞留を許す量として決める。カメラ 30fps 相当で約 130ms、画面キャプチャの `targetFPS` 上限 120fps では約 33ms の滞留を許す値である。処理中の 1 件も未処理数に含める。上限に達したときは新しく到着した frame を破棄する (処理中の frame を中断して入れ替えるより実装が単純で、破棄の判定が ingress で一意に閉じるため)。fps に応じた間引きは画面キャプチャ側の `targetFPS` 間引き (`Sora/ScreenCapture.swift:774-812`) で既に行われており、上限超過の破棄はその後に加わる SDK 側の drop として位置付ける (`RTCVideoSource` の `adaptOutputFormatToWidth:height:fps:` にも fps に応じた drop の記述があるが、SDK からは呼んでいない)。
- lock を保持したまま利用者 callback (`VideoFilter.filter(_:)`、`VideoRenderer` の各 callback) と native へのアクセス (`RTCVideoSource.capturer(_:didCapture:)`、`nativeVideoTrack` = `nativeStream.videoTracks.first` とその `source` の読み出し) を実行しない。lock 区間では owner が保持する状態 (参照・世代・sequence・未処理数) を読むだけにする。例外は `BasicMediaStream` が `videoRenderer` の get / set 専用に持つ `rendererLock` で、保持中に `RTCVideoTrack.add` / `remove` を呼ぶ (この lock は frame 経路から取らず、同梱 WebRTC の実装はどちらも worker thread へ非同期に投入して即座に戻るため、映像処理を止めない)。

### frame の ingress と所有表現

- `send(videoFrame:)` は同期 API のまま、frame を owner の ingress へ投入して戻る。filter の実行と `RTCVideoSource` への配送の完了は待たない。待たせると、呼び出し元が camera の capture session queue と screen capture の `sendVideoFrameQueue` であるため、利用者 filter が同じ queue へ hop する API を呼んだ場合に deadlock し得る。受理と破棄は戻り値で示さず、debug ログに出す。呼び出し側は frame の所有権を SDK へ移し、`send` が戻った後にその `VideoFrame` と保持する画素データを参照・変更しない (「公開 API の契約」)。
- ingress は次の順で行う。まず lock を保持せずに `nativeVideoTrack?.source` を読んで `videoSource` を解決し (「StreamFrameOwner」の「lock 中で native へアクセスしない」制約に従う)、次に 1 つの lock 区間で「無効化判定 (条件 4) → `videoSource` 判定 (条件 2) → 上限判定 (条件 3) → sequence の採番 → 未処理数の加算 → owner queue への投入」をまとめて行う。判定順を 2 → 3 に固定するのは、両条件が同時に成立した場合に `discardedFrameCount` へ加算するかが順序依存で決まることを避けるためである (条件 3 は加算し、条件 2 は加算しない)。無効化または `videoSource` が `nil` の場合は採番も未処理数の加算も行わず、debug ログを出して戻る (この破棄は `discardedFrameCount` に含めない)。採番と投入を 1 つの lock 区間で行わないと、並行する `send` が採番順と実行順で入れ替わる。未処理数の減算は owner queue で frame の処理 (filter と source への配送、または破棄) が終わった時点で行い、破棄経路でも必ず 1 回減算する。
- owner queue へ渡す payload は `StreamOwnedFrame` (internal) とする。この payload は ingress だけが作るものとし、renderer 経由の frame は payload に載せず `RTCVideoFrame?` を直接運ぶ。保持するのは `frame: RTCVideoFrame`、`capturer: RTCVideoCapturer?`、`videoSource: RTCVideoSource`、`ingressSequence: UInt64`、`retainedBacking: ScreenCaptureOwnedFrame?` である。`capturer` は `VideoFilter` の入力と `RTCVideoSource` への配送に現行どおり使い、SDK は `delegate` を読まない。`videoSource` は ingress で解決した配送先で常に非 `nil` である (`nativeVideoTrack?.source` が `nil` の frame は payload を作る前に ingress で破棄する)。`retainedBacking` は画面キャプチャ経路の画素データの所有者を配送完了まで保持するためのもので、camera 経路と public send 経路では `nil` とする。`ingressSequence` はテスト観測用で production の配送判定には使わない。`nil` の capturer 用のダミー instance は `Sora/StreamFrameOwner.swift` へ移す。
- `StreamOwnedFrame` の `@unchecked Sendable` の根拠は次の 3 点に限定して型 doc に書く。
  1. 呼び出し側は `send(videoFrame:)` に frame の所有権を移し、`send` が戻った後にその `VideoFrame` と保持する画素データを参照・変更しない (「公開 API の契約」)。SDK 内部の呼び出し元も同じで、`CameraVideoCapturerHandlers.onCapture` が返した frame と `ScreenCaptureOwnedFrame` が所有する画素データは配送完了まで `StreamOwnedFrame` が保持する (画面キャプチャ経路は `retainedBacking` で所有者ごと保持する)。保持する `capturer` は `RTCVideoCapturer` の可変な `delegate` を持ち得るが、SDK は `delegate` を読まず、`VideoFilter` の入力と `RTCVideoSource` への引数として渡すだけである。SDK は配送が完了するまで payload として保持し、画素データを書き換えない (`timeStamp` は assign 可能だが SDK は設定しない)。`RTCVideoFrame` の retain はヘッダで保証された契約ではなく実装依存であるため、「retain で寿命が保たれる」ことは根拠に含めない。
  2. 書き込みを行う executor は常に 1 つであり、所有権は「生成側 → owner queue → (renderer 配送時は) main queue」の順に 1 回ずつ移り、移譲元は以後その値を書き換えない。同じ `RTCVideoFrame` を source への配送と renderer への配送が同時に読むことはあるが、いずれも読み取り専用である。
  3. renderer 経路の frame は libwebrtc が生成した frame をそのまま 1 hop 延長して運ぶだけであり、既存の `VideoRendererFrameEvent: @unchecked Sendable` が行っていた native thread → main queue の越境 (`Sora/VideoRenderer.swift:29-37, 93-95`) に owner queue の 1 hop を加えたものである。新しい画素データの生成も複製もしない。
- `ScreenCaptureOwnedFrame` (`ScreenCaptureController` の入れ子型。`Sora/ScreenCapture.swift:148, 203-216`) の移動は変更しない。`processOwnedFrame` が `sendVideoFrameQueue` 上で作った `VideoFrame` と `ownedFrame` を、`BasicMediaStream` の internal な `send(videoFrame:retaining:)` 経由で owner へ渡す (public な `send(videoFrame:)` は `retaining: nil` で同じ経路を使う)。`senderStream as? BasicMediaStream` が失敗した場合は public `send(videoFrame:)` にフォールバックする (`retainedBacking` は `nil` になる)。`retainedBacking` の型は internal な入れ子型 `ScreenCaptureController.ScreenCaptureOwnedFrame` であり、`ScreenCaptureOwnedSampleBuffer` と合わせて `Sora/StreamFrameOwner.swift` から internal で参照できることを確認する (参照できない場合は入れ子型を file scope へ出す)。0104 が委譲した「`ScreenCaptureOwnedFrame` を `0105` の ingress へ接続する」は、この経路で画素データの所有権を配送完了まで保つこととして満たす。0104 は closed のため更新せず、この読み替えを本 issue の `## 解決方法` に書く。`sendVideoFrameQueue` と `videoSampleBufferTransformer` の executor は現行のまま維持する。
- 「広域の `@unchecked Sendable` wrapper」を新設しない。本 issue で新設する `@unchecked Sendable` 型は `StreamFrameOwner` と `StreamOwnedFrame` の 2 つだけであり、それぞれの根拠を型 doc に書く。`SenderStreamBox` のような複数の呼び出し元で共有する箱は追加しない。

### VideoFilter

- legacy `VideoFilter` は owner queue 上でだけ実行する。owner queue 上の処理は payload から `VideoFrame.native(capturer: payload.capturer, frame: payload.frame)` を組み立てて `videoFilter?.filter(videoFrame:)` に渡し、返された `VideoFrame.native(capturer:frame:)` の `capturer ?? dummyCapturer` と `frame` を `RTCVideoSource.capturer(_:didCapture:)` へ渡す (現行 `Sora/MediaStream.swift:273-287` と同じ組み立て)。同一 stream で同時に 2 つの frame が filter に入ることはない。同じ `VideoFilter` instance を複数の stream で共有した場合は owner queue が別であるため直列化されず、その排他は利用者の責任であることを `Sora/VideoCapturer.swift` の doc に書く。
- `videoFilter` の get / set は owner の lock 付き storage で排他する。owner queue は frame の配送直前に同じ lock 区間で filter を読む。各 frame が使う filter は「owner が読み取った時点の値」として一意に決まり、交換と frame 入力が競合しても 1 つの frame が 2 つの filter を通ることはない。交換自体を owner queue の event にしないため、非 Sendable な `VideoFilter` を `@Sendable` closure へ持ち込まない (`0103` が `stream` の setter から owner queue を `sync` しないと決めたのと同じ理由)。交換は受理済み frame の実行順とは同期しないことを doc に書く。
- `VideoFilter` に `Sendable` を要求せず、既存 conformer を壊さない。
- frame 加工フックは `VideoFilter.filter` の他に `CameraVideoCapturerHandlers.onCapture` (`Sora/CameraVideoCapturer.swift:1622`) と `ScreenCaptureSettings.videoSampleBufferTransformer` (`Sora/ScreenCapture.swift:29`) がある。どちらも実行 executor を変更しない。`onCapture` は capture session queue 上で ingress の前に、`videoSampleBufferTransformer` は `sendVideoFrameQueue` 上で ingress の前に実行される (現行どおり)。それぞれの doc にこの位置関係を追記する。

### RTCVideoSource への配送

- owner queue 上で `RTCVideoSource.capturer(_:didCapture:)` を呼ぶ。入力元ごとに配送 executor を分けない。filter の実行と配送を同じ直列 executor で行わないと、3 入力元をまたいだ順序を保証できないためである。
- `RTCVideoSource` は `RTCVideoCapturerDelegate` を実装し、ヘッダに thread 契約の記載はない (`RTCVideoSource.h`)。`RTCCameraVideoCapturer` の native 操作と delegate callback を capture session queue 上で行う制約 (`Sora/CameraVideoCapturer.swift:645-676`) は維持し、変更するのは「delegate が受け取った frame を source へ転送する executor」だけである。画面キャプチャ経路と public send 経路は現行でも capture session queue 以外から source を呼んでいる (`dummyCapturer` を使う `Sora/MediaStream.swift:281-283`、`Sora/ScreenCapture.swift:727`)。
- `RTCVideoSource` の呼び出しは owner の中の 1 箇所に閉じ、`0070` の Phase 3 / Phase 4 (`issues/0070-change-migrate-to-webrtc-c-xcframework.md:86, 342-343`) で置き換える対象をこの 1 箇所にする。
- 実機での確認項目は「テスト方針」の「実機で手動確認する」に列挙する。owner queue から `RTCVideoSource` へ配送する方式は実機で確認し、結果を「解決方法」に記録する。

### renderer への配送

- owner は renderer event を owner queue 上で順序付け、internal な enum `StreamRendererDelivery` として配送する。case と保持する値は次のとおり。`added(renderer: VideoRenderer, stream: MediaStream)` / `removed(renderer: VideoRenderer, stream: MediaStream)` / `frame(RTCVideoFrame?, generation: UInt64)` / `size(CGSize, generation: UInt64)` / `switchVideo(Bool, generation: UInt64)` / `switchAudio(Bool, generation: UInt64)` / `disconnect(renderer: VideoRenderer?, mediaChannel: MediaChannel?)` (配送先は無効化した時点の renderer に固定し、配送までに解放されていた場合は配送しない)。`added` / `removed` の renderer と stream、`disconnect` の mediaChannel は配送完了まで owner が強参照する。`frame` / `size` / `switch` が持つ `generation` は、main queue 上で現在の世代と比較するために使う (`switch` は `submitSwitch` の時点の世代、`frame` / `size` は adapter が保持する世代)。順序は owner queue への投入順で確定し、frame の ingress の `sequence` とは共有しない。この enum は `@unchecked Sendable` にせず、`@Sendable` closure へ持ち込まない。
- legacy `VideoRenderer` への最終配送 executor は main queue に統一する。現行で main queue なのは `render` / `onChange(size:)` だけであり (`Sora/VideoRenderer.swift:74-96`)、SDK 内部の renderer callback 経由で `VideoView` の `start()` / `stop()` / `clear()` (`Sora/VideoView.swift:145-234`) が main 以外から呼ばれる経路をなくす (`start()` などは public のため、利用者が任意スレッドから呼ぶ契約は変わらない)。この変更は利用者が観測できる契約変更であり、`CHANGES.md` と doc に記載する。`videoRenderer` の setter は callback の配送完了を待たなくなる (現行は `onAdded` / `onRemoved` を同期で呼ぶ)。
- `onAdded` / `onRemoved` は「配送先の renderer を event ごとに固定する」。`videoRenderer` の setter は、`newValue` が現在の renderer と異なる instance である場合にだけ、lock 区間で世代を進め、`pendingRendererDeliveries` に `.removed(以前の renderer)` を積んでから `.added(新しい renderer)` を積み、owner queue へ投入する (`removed` を先に積み、旧 renderer の停止通知を先に配送する)。以前の renderer が既に解放されている場合 (設置中の renderer への参照は `weak` のため) は `.removed` を積まずに `.added` だけを積み、世代は進める。`newValue` が現在の renderer と同一 instance である場合、現在の renderer が `nil` で `newValue` も `nil` である場合は、世代を進めず `pendingRendererDeliveries` にも何も積まずに戻る。この no-op が必要なのは、同一 instance に `.added` と `.removed` の両方を積むと、配送された `onRemoved` が `VideoView.autoStop()` (`Sora/VideoView.swift:224-226`) で `isRendering` を `false` にし、以後 `onAdded` が来ないため preview が止まったままになるからである (現行 `Sora/MediaStream.swift:140-150` は同一 instance の再設定でも `onAdded` を呼ぶだけで `onRemoved` は呼ばず、`nil` を `nil` へ代入しても何も起きない)。`pendingRendererDeliveries` には全種類の delivery を lock 区間で投入順に積む。`frame` / `size` / `switch` が持つ payload は非 Sendable なため `@Sendable` closure へ持ち込めず、main queue の block は owner だけを capture して owner から 1 件ずつ取り出す (このため `frame` / `size` / `switch` にも pending が必要である)。`invalidate(disconnectFrom:)` は lock 区間で末尾に `.disconnect(mediaChannel:)` を追加してから owner queue へ投入する。pending は配送が完了するまで renderer / `MediaStream` / `MediaChannel?` を強参照する (設置中の renderer への参照は `weak` のままで、owner は renderer の寿命を延長しない。現行の `VideoRendererAdapter` が renderer を弱参照するのと同じ)。世代一致の判定対象は `frame` / `size` / `switch` だけとし、`added` / `removed` は世代が進んでいても失わない。これにより、setter で `nil` を代入した場合または交換した場合に、`onAdded` を受け取った renderer は必ず `onRemoved` を 1 回受け取る (交換時に旧 renderer へ `onRemoved` を配送するのは現行に無い追加であり、「公開 API の契約」と `CHANGES.md` に書く)。`terminate()` は `onRemoved` を配送せず `onDisconnect` だけを配送する (現行と同じ)。
- `onAdded(from:)` / `onRemoved(from:)` の `MediaStream` 引数と `onDisconnect(from:)` の `MediaChannel?` 引数は非 Sendable であるため、`@Sendable` closure の payload に載せない。main queue 上の block は owner を強参照し、owner が配送要素として保持している `MediaStream` / `MediaChannel?` を main queue 上で取り出して渡す。配送要素から取り出した後に解放する。
- `frame` / `size` / `switch` は、main queue 上で「現在の世代と renderer」を同一 lock 区間で読み、世代が一致する場合だけ配送する。owner queue での判定だけに依存しない。世代が未設定 (0) の間に届いた frame / size は配送しない。
- `VideoRendererAdapter` は `setSize` / `renderFrame` を main queue へ直接渡さず owner へ `queue.async` で投入する。`RTCVideoSource.capturer(_:didCapture:)` は owner queue から呼ばれ、その中で同じ video track の renderer へ同期配送されるため、`renderFrame` は owner queue 上で呼ばれ得る。owner への投入に `queue.sync` を使うと自己デッドロックするため、必ず非同期投入とする。adapter は owner を弱参照し、generation は owner が `setRenderer` の呼び出しで採番して adapter へ渡し、init で受け取った不変値として保持する (交換のたびに adapter を作り直すため書き換えない)。native track への `add(adapter)` は `.added` を owner へ投入した後、`remove(adapter)` は `.removed` を投入した後に行い、新 adapter の frame が `onAdded` より先に届かないようにする。既存の `VideoRendererFrameEvent` / `VideoRendererSizeEvent` は削除する。
- main queue 上で `VideoView.start()` の `DispatchQueue.main.async` を経由すると、`onAdded` の直後に配送された frame が `isRendering == false` で破棄される。`Sora/VideoView.swift` を変更対象に加え、`start()` (`Sora/VideoView.swift:158-165`) は main queue 上で呼ばれた場合に `isRendering = true` の代入だけを同期で行う。`bringSubviewToFront` は現行どおり `DispatchQueue.main.async` のままとし、`clear()` (`:145-155`) は変更しない (`clear()` は `isRendering` を書かない)。
- ingress の sequence は renderer frame へ伝播しない。frame ごとの対応は配送順で表し、診断には `RTCVideoFrame.timeStampNs` と `VideoFrame.timestamp` (`Sora/VideoFrame.swift:36-41`) を使う。renderer 経由の frame は ingress の payload を使わないため ingress の `sequence` を消費せず、renderer event の順序は owner queue と main queue の FIFO で表す。
- `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` は本 issue では executor を変更しない。`0136` が確定した「`setVideoHardMute(true)` の経路では `VideoHardMuteActor` の executor、それ以外は呼び出し元」を維持し、`0136` の executor 記録のうち `VideoRenderer.onSwitch` 側だけを本 issue が main queue へ変える。両者の executor が異なること、handler と renderer の相対順序を保証しないことを doc に明記する (`Sora/MediaStream.swift:15-23`、`Sora/MediaChannel.swift:1404-1414`。`CHANGES.md` の `onSwitchVideo` のみの記載は維持する)。
- MainActor 前提の新しい renderer protocol、`@preconcurrency` の除去、非 UI renderer の custom queue は `0027` / `0060` で扱う。配送の順序は owner が決め、`0060` が追加する利用者の queue は最終配送先としてだけ使う (順序と drop の判断を利用者 queue へ委ねない)。本 issue は配送先を選択する公開 API を追加しない。
- `StreamFrameOwner` の `drainForTesting()` は `queue.sync {}` とする。テストの executor からのみ呼び、owner queue 自身の executor から呼ぶと自己デッドロックする (0104 の `drainSendVideoFrameQueue()` と同じ制約)。`lastAcceptedSequenceForTesting` は ingress で採番した最後の `sequence` を返し、受理後に条件 4 で破棄された frame も含む。`processedSequencesForTesting` は owner queue で処理まで進んだ frame の `sequence` を実行順に並べた配列で (`VideoFilter` が未設定でも記録する)、上限超過で破棄された frame と受理後に無効化で破棄された frame は含まない。記録する storage と accessor は `#if DEBUG` で囲み、production では frame ごとの記録も保持もしない (上限の無い観測用配列を production に持ち込まないため。テストは Debug 構成で実行する)。`discardedFrameCountForTesting` は上限超過で破棄した件数を返す (条件 1 / 2 / 4 の破棄は含まない)。同期 getter は lock 区間で読む。owner への内部投入はすべて `queue.async` であり、`queue.sync` は `drainForTesting()` だけに限定する。
- `pendingRendererDeliveries` は配送が完了した要素から順に解放する。配送は owner queue と main queue の 2 段であるため、owner queue が停止した場合は pending と、それに強参照された renderer / `MediaStream` / `MediaChannel?` / frame の payload が解放されない (owner → pending → `BasicMediaStream` → owner の一時的な循環が配送完了まで残る)。owner queue の処理は利用者 callback の完了に依存しないため、この保留は高々 1 バッチである。

### frame 破棄の判定

owner が frame を破棄する条件と、判定する executor / `sequence` の消費 / `discardedFrameCount` への加算 / `lastAcceptedSequenceForTesting` への反映を次に固定する。ingress の採番は 1 から始め、受理ごとに +1 する。

1. `videoFrame` が `nil` (`send(videoFrame: nil)`): `send` の入口で判定する。`sequence` を消費せず、`discardedFrameCount` に加算せず、受理としても扱わない。
2. `nativeVideoTrack?.source` が `nil` (video track を持たない stream。例: `videoEnabled == false` で接続した送信 stream、映像 track を持たない受信 stream): ingress で判定する。`sequence` を消費せず、`discardedFrameCount` に加算せず、受理としても扱わない。source は ingress ごとに `nativeVideoTrack?.source` を読んで payload に載せる (現行 `send` と同じく frame ごとに解決する) ため、track 構成が後から変わっても追随する。この条件は `send` の ingress の frame だけに適用し、renderer の frame / size / switch には適用しない (renderer frame は `send` を通らない)。
3. ingress の未処理数が `maxPendingFrameCount` に達している: ingress で判定する。`sequence` を消費せず、`discardedFrameCount` に加算し、受理としても扱わない。debug ログ (英語) を出す。
4. owner が無効化されている (`terminate()` 済み): ingress では `sequence` を消費せず、`discardedFrameCount` に加算せず、受理としても扱わない。ingress 通過後に無効化された場合は owner queue の実行時にも確認し、受理済みの frame を破棄する (`sequence` は受理時に消費済みで、`discardedFrameCount` には加算しない)。

renderer の `frame` は ingress の上限判定の対象外だが、main queue が停止している間に配送要素が無制限に滞留しないよう `internal static let maxPendingRendererFrameCount = 4` を上限とし、超過した frame は投入時に破棄する (`maxPendingFrameCount` と同じ「新しい方を捨てる」方針)。`size` / `switch` はトラックの状態変化でしか発生しないため件数の上限を設けない。renderer 経由の `frame` / `size` / `switch` は、無効化されている場合と世代が一致しない場合に配送時にも破棄し、無効化後は投入時にも受理しない (payload の生成も owner queue への投入も行わない)。破棄は debug ログに出す。renderer event は `discardedFrameCount` に加算しない。

- `transportEpoch` による照合は行わない。redirect と切断では `PeerChannel` が全 stream を `terminate()` して `streams` を破棄し、新しい接続では新しい `BasicMediaStream` が生成されるため (`Sora/PeerChannel.swift:1691-1701, 1834-1837, 720-746, 2016-2057`)、未無効化の owner に旧 transport の frame が届く経路が無く、無効化後の frame は破棄条件 4 で落ちる。`0027` / `0122` が前提にしている「stream epoch」は本 issue では導入しない (「変更対象」で前提を更新する)。
- re-offer / re-answer では owner を無効化せず sequence 順の維持だけを保証する。
- `terminate()` は ingress と同一の lock 区間で `isInvalidated` を立て、owner queue を待たずに戻る。owner queue を `sync` で待たないのは、呼び出し元が capture session queue と `sendVideoFrameQueue` であり、利用者 filter からの再入と合わせて deadlock し得るためである。`invalidate(disconnectFrom:)` の引数として呼び出し元の executor で `peerChannel.mediaChannel` を読み、配送要素として保持する。owner queue は無効化以降、未処理の frame を filter にも `RTCVideoSource` にも渡さず、renderer の `frame` / `size` / `switch` も配送しない。`pendingRendererDeliveries` の `added` / `removed` は配送してから `onDisconnect` を 1 回配送する (`onRemoved` は配送しない)。`onDisconnect` の配送先は無効化した時点の renderer に固定し、配送時に現在の renderer を読み直さない (無効化の後に `nil` を代入した場合は配送されず、別の renderer を設置した場合は `onAdded` を受け取っていない renderer に `onDisconnect` が届くため)。無効化の後に新しい renderer を設置しても何も配送せず、`nil` の代入による取り外しは受け付ける (設置を受け付けると `onAdded` の後に `onDisconnect` が届かない renderer が生まれる)。`terminate()` は冪等とし、2 回目以降は `onDisconnect` を再配送しない。
- 無効化と owner queue で実行中の block は同期しないため、`isInvalidated` を確認した後に `RTCVideoSource.capturer(_:didCapture:)` を実行中の block は `nativeChannel` の close (`Sora/PeerChannel.swift:1703, 1851-1853`) と並行し得る (最大 1 frame 分の窓)。この窓を閉じるために owner queue を同期 wait する設計は deadlock の危険があるため採らない。owner が `RTCVideoSource` を強参照し続けるため frame の寿命は保たれるが、close と `capturer(_:didCapture:)` の並行安全性はヘッダからは確認できない。この窓を許容し、実機確認に「無効化直後と close 直後に assertion / crash が出ないこと」を追加する。「`0095` が epoch 照合で閉じていた窓は、executor の無効化とこの実機確認で置き換える」ことを doc と `CHANGES.md` に書く。
- `PeerChannel` の `didRemove stream` は `remove(stream: stream)` を呼び `terminate()` を呼ばない (`Sora/PeerChannel.swift:2049-2057`)。この経路では renderer の callback が配送されない既存の挙動を変更しない (renderer のライフサイクルは `0027` で扱う)。このため `onAdded` → `onRemoved` の対は `videoRenderer` の setter 経由の遷移だけを対象とする。
- `terminate()` の `onDisconnect` は owner → main の非同期配送である。stream をまたぐ renderer callback の順序 (旧 stream の `onDisconnect` と新 stream の `onAdded`) は保証しないことを doc と `CHANGES.md` に書く。

### 公開 API の契約

- `send(videoFrame:)` の「ingress へ投入して戻る」契約、破棄条件、`nil` の扱い (何もしない)、frame の所有権が SDK へ移り `send` が戻った後に呼び出し側が frame と画素データを参照・変更しないことを doc に明記する。
- renderer の setter (`videoRenderer` の set / nil 代入) と `videoEnabled` / `audioEnabled` の setter は renderer callback の配送完了を待たない (getter は即時に新値を返す) ことを doc に明記する。
- `nativeVideoSource` が `nil` の stream では現行と異なり filter が呼ばれなくなる。この挙動変更を `send` の doc と `CHANGES.md` に記載する。
- `Sora/MediaStream.swift:107-108` の `send(videoFrame:)` の doc の `nil` の記述を実装 (285-286 行) に合わせて修正する。104-105 行の「加工後の映像フレームが映像レンダラーによって描画されます」は現行の因果として正しいため残し、非同期配送になることと順序保証の範囲を追記する。
- `videoRenderer` の setter は callback の配送完了を待たず、交換時は旧 renderer に `onRemoved` を配送する (現行は配送しない) こと、同一 instance の再設定と `nil` から `nil` への代入では何も配送せず世代も進めないことを doc に明記する。`VideoView.start()` は main queue 上で `isRendering` を即時に true にするため、公開 getter が返す値の時点が変わることも doc に明記する。
- `Sora/VideoFrame.swift` の `.native` が持つ `capturer` は現行どおり `VideoFilter` の入力と `RTCVideoSource` への配送に使う (SDK は `delegate` を読まない) ことを doc に追記する。public case の型は変更しない。
- `videoFilter` / `videoRenderer` に `@Sendable` や actor 隔離を要求しない。実行 executor の契約を protocol の doc と `skills/sora-ios-sdk/SKILL.md` に記載する。`videoRenderer` の getter / setter は `BasicMediaStream` の `rendererLock` で直列化されるため、どのスレッドから呼んでもかまわないことも doc に記載する (`videoFilter` は owner の lock 付き storage が直列化する)。
- 上限を超えた frame の破棄、`terminate()` 後の破棄、`terminate()` の冪等性を doc に記載する。renderer 経由の frame が配送待ち件数の上限で破棄されることも記載する。
- `onDisconnect` の配送先が `terminate()` を呼んだ時点の renderer であること、`terminate()` の後に新しい renderer を設定しても何も配送せず `nil` の代入による取り外しは行えることを doc に記載する。

## スコープ外

- `videoEnabled` / `audioEnabled` の書き込みの直列化 (operation 単位の排他と、失敗時の復元の原子性) は `0163` で扱う。本 issue は renderer の `onSwitch` の配送順序だけを担い、`MediaStreamHandlers.onSwitchVideo` の executor と `0136` が `VideoHardMuteActor` の executor へ置いた書き込みは変更しない。
- `setVideoHardMute(true)` 失敗時のカメラ予約の扱い (`0159`) は変更しない。
- `SenderStreamBox` (`Sora/VideoMute.swift:22-28`) の置き換えは行わない。これは actor 境界へ `MediaStream` を渡すための箱であり、置き換えると `CameraStateOwner` の `WeakStream` / `compareAndSetStream` (`Sora/CameraStateOwner.swift:50-115`)、`CameraCaptureOwnership` / `VideoSourceCoordinator` の弱参照と同一性比較 (`Sora/CameraVideoCapturer.swift:36-59, 100-166, 326-366`)、`CameraVideoCapturer.startForSDK(senderStream:)` (`:1385-1447`) まで波及する。frame の ingress には必要ないため、`SenderStreamBox` を置き換える別 issue を起票して引き継ぐ (未起票)。`0103` の「`0105` の完了まで維持する」(`:142`) は closed のため更新せず、別 issue の前提に「`0103` の維持判断は frame ingress とは独立であり、置き換えは別 issue で行う」と書く。
- 新しい Media Processors API と frame の drop 契約は `0057` で扱う。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。`StreamOwnedFrame` は internal に閉じ、`VideoFrame` の public case は変更しない。
- `MediaStreamHandlers` の closure property の読み書き排他は、現時点の `0154` は対象に挙げていない (どの issue の対象でもない)。本 issue では配送 executor だけを変更し、closure の排他は `0154` の対象に追加する (「変更対象」)。
- `CameraVideoCapturerHandlers` / `MediaChannelHandlers` / `WebSocketChannelHandlers` の closure 排他は `0154` で扱う。
- `VideoView.stop()` (`Sora/VideoView.swift:169-171`) の `isRendering` の書き込みと executor、および `clear()` の `bringSubviewToFront` の扱いは変更しない。`isRendering` の読み書きの排他は `0027` の MainActor 移行で扱う。
- Thread Sanitizer による検証は `0119` の CI job が整った時点で補助的に行い、`0119` / `0151` が未完了の間は完了条件に含めない。

## 変更対象

- `Sora/StreamFrameOwner.swift` (新規): `StreamFrameOwner` / `StreamOwnedFrame` / `StreamRendererDelivery`、`dummyCapturer`
- `Sora/MediaStream.swift`: `BasicMediaStream` への owner の追加と `streamOwner` の internal 化 (設計方針のとおり宣言時に初期化する)、`send(videoFrame:)` の ingress 投入への変更と doc の修正 (`:107-108` の `nil` の記述)、internal な `send(videoFrame:retaining:)` の追加、`videoFilter` の owner 委譲、`videoRenderer` setter の `.added` / `.removed` 投入への変更 (callback の配送完了を待たず、同一 instance の再設定と `nil` から `nil` への代入では何も投入せず世代も進めない)、`rendererLock` による `videoRenderer` getter / setter の直列化 (adapter の差し替えと owner の世代更新を同一区間で行う)、`videoEnabled` / `audioEnabled` setter の `videoRenderer?.onSwitch` の owner 委譲、無効化時に `setRenderer` が `nil` を返して設置を行わないこと、`terminate()` の無効化と doc、`dummyCapturer` の削除、`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の doc の更新、`videoRendererAdapterForTesting` (internal) の追加
- `Sora/VideoRenderer.swift`: `VideoRendererAdapter` の `setSize` / `renderFrame` を owner への `queue.async` 投入に変更、owner の弱参照と generation の不変保持、`VideoRendererSizeEvent` / `VideoRendererFrameEvent` の削除、`setSize` / `renderFrame` の暫定ロジックに付いた `TODO(zztkm)` (`:71-73`) の削除 (MainActor 前提 API への移行が必要であることを型 doc に書く。issue 番号はソースコードに書かない)、`VideoRenderer` protocol の callback の executor 契約を doc に追記
- `Sora/VideoFrame.swift`: `.native` の `capturer` を現行どおり `VideoFilter` の入力と `RTCVideoSource` への配送に使い、SDK は `delegate` を読まないことを doc に追記 (型は変更しない)
- `Sora/VideoView.swift`: `start()` (`:158-165`) で main queue 上なら `isRendering = true` の代入だけを同期化する (main queue 統一で顕在化する frame 取りこぼしの回帰防止であり、既存不具合の修正ではない)。`VideoView` は `Sora/VideoView.swift:30` に `@MainActor` の明示注釈を持たないが、`UIView` 継承による暗黙の `@MainActor` 隔離であり、`VideoRenderer` 準拠は `@preconcurrency` のため、callback から main queue 上で同期に書けるのはこの緩和に依存する。`@preconcurrency` を外す際に隔離違反にならない書き方とし、`@preconcurrency` の緩和に依存していることを doc に書く (issue 番号はソースコードに書かない)。`bringSubviewToFront` は async のまま、`clear()` は変更しない。`stop()` (`:169-171`) は変更しない (「スコープ外」)
- `Sora/VideoCapturer.swift`: `VideoFilter.filter` の executor 契約と、複数 stream で共有した場合の利用者責任を doc に追記
- `Sora/CameraVideoCapturer.swift`: delegate の doc に「frame は `send` の ingress へ渡す」ことを追記。`onCapture` の doc に実行 executor と ingress との位置を追記 (処理は変更しない)
- `Sora/ScreenCapture.swift`: `processOwnedFrame` の `senderStream.send(videoFrame:)` (`:727`) を `BasicMediaStream` の internal な `send(videoFrame:retaining:)` に置き換え、`processOwnedFrame` の doc と flight permit の説明を「ingress への投入で返却する」へ更新、`targetFPS` が上限であり上限破棄された frame も `markVideoFrameSent` の基準に残ることを doc に追記、`videoSampleBufferTransformer` の doc に ingress との位置を追記
- `Sora/MediaChannel.swift`: `setVideoHardMute` の doc を「handler は `VideoHardMuteActor` の executor、`VideoRenderer` は main queue」に更新 (処理は変更しない)
- `Sora/PeerChannel.swift`: `terminate()` 呼び出し箇所の doc に executor の無効化を追記 (処理は変更しない)
- `SoraTests/StreamFrameOwnerTests.swift` (新規): 直列化 / sequence / filter 実行順序 / 交換との競合 / 上限での破棄 / 無効化後の破棄 / renderer event の順序と `onAdded` → `onRemoved` の対
- `SoraTests/VideoViewStartTests.swift` (新規): `start()` が main queue 上で `isRendering` を同期更新すること
- `SoraTests/StreamFrameOwnerTestHelpers.swift` (新規): `ownerForTesting` / drain のヘルパー / `RecordingVideoFilter` / `SynchronousFilterGate` / `RecordingVideoRenderer` / `makeSenderStreamWithVideoTrack` を `internal` で定義し、`StreamFrameOwnerTests.swift` と `ScreenCaptureFrameGenerationTests.swift` の両方から使う
- `SoraTests/ScreenCaptureFrameGenerationTests.swift`: owner の drain seam を追加し、`private` ヘルパーを `StreamFrameOwnerTestHelpers.swift` の `internal` ヘルパーへ置き換える
- `SoraTests/DummyVideoCapturer.swift`: `frameCount` の意味 (ingress へ投入した frame 数) を doc に追記
- `SoraTests/SendableConformanceTests.swift`: `StreamOwnedFrame` を `requireSendable` で追加する (`requireSendable<T: Sendable>(_: T.Type)` は型引数を取るため実 frame を生成しない。Sendable の表明だけを行い、根拠の妥当性は型 doc のレビューで確認する)
- `skills/sora-ios-sdk/SKILL.md`: 映像節に `VideoFilter` / renderer callback の executor 契約、`send` の配送契約、無効化後の破棄を追記
- `CHANGES.md`: `## develop` へ `- [UPDATE] MediaStream の映像フレーム処理 executor を単一化する` と詳細 11 項目 (renderer callback の executor が main queue に統一されること、`videoRenderer` の setter が callback の配送完了を待たず交換時に旧 renderer へ `onRemoved` を配送し、同一 instance の再設定と `nil` から `nil` への代入では何も配送しないこと、`videoEnabled` / `audioEnabled` の setter が callback の配送完了を待たないこと、`VideoView.start()` が main queue 上で `isRendering` を即時に更新すること、`send` が配送完了を待たず frame の所有権が SDK へ移ること (`send` が戻った後に呼び出し側が frame と画素データを参照・変更しないこと)、上限超過の frame が破棄されること、`nativeVideoSource` が `nil` の stream では filter が呼ばれないこと、`terminate()` が冪等で以降 frame を配送しないこと、`terminate()` が `onRemoved` を配送しないこと、切断直後の 1 frame 分の配送窓を許容すること、stream をまたぐ renderer callback の順序を保証しないこと)、末尾に `  - @t-miya` を追記する

次の issue の記述は本 issue の PR 内で更新する (本 PR で更新済み)。

- `issues/0027-refactor-videorenderer-mainactor-migration.md`: 前提 (`:41`) と payload / 順序の方針 (`:56`) から epoch を削除し、現状の event box の記述 (`:26-28`) を「`0105` が削除し、adapter は owner queue → main queue の配送になった」へ更新し、`VideoRendererAdapter` の native track からの除去 (本 issue が `0027` へ委譲する) を設計方針と完了条件に追記する
- `issues/0122-remove-legacy-video-renderer.md`: 設計方針の「sequence / epoch 付き」(`:36`) を「sequence 付き」へ直し、event box を前提にした記述 (`:26, :34, :54`) を削除する
- `issues/0057-add-media-processors.md`: 現物に `## 前提となる issue` が無いため `## 方針` (`:14`) の後に新設し、本 issue の ingress と processor 契約の責務境界、raw WebRTC 型を新しい公開 API に出さない方針 (`0070` と整合) を書く
- `issues/0060-add-videorenderer-custom-queue.md`: 「`0105` で 7 callback の最終配送が main queue に統一された。`0060` は最終配送先を利用者 queue に置き換える issue である」と固定し、順序は owner が決め利用者 queue は最終配送先であることを追記する。「常にメインキュー」は `0105` 完了時点では正しい記述になるため書き換え対象から外し、`renderFrame(_ frame: RTCVideoFrame?)` の記述は現行の `VideoRenderer.render(videoFrame:)` に合わせる
- `issues/0110-add-sendable-event-api.md`: 前提となる issue (`:36-42`) を、frame event の順序保証 (`0105`) と有効フラグの直列化 (`0163`) に更新する (現物は `0105` のみのため `0163` を追加する)。スコープ外の `0154` の対象列挙 (`:80`) に `MediaStreamHandlers` を加える
- `issues/0154-refactor-handler-bag-exclusion.md`: タイトルを「MediaChannel と WebSocketChannel と CameraVideoCapturer と MediaStream の handler bag の読み書きを排他する」に変更し、目的 (`:11`)・現状 (`:15`)・設計方針 (`:25`)・完了条件 (`:40`) に `MediaStreamHandlers` を加え、前提 (`:32-36`) に「`0105` が closure 排他を本 issue へ委ねている」を追記する
- `issues/0163-bug-fix-video-enabled-flag-serialization.md`: 前提となる issue に本 issue (frame の処理順序と executor) を追記し、`Sora/MediaStream.swift` の setter を両 issue が変更するため実装順序の依存があることを明記する。あわせて `0163` の「`videoRenderer` の `onSwitch` を operation の executor で呼ぶ」記述 (`:38`) を、renderer の `onSwitch` の配送 executor は本 issue が main queue にするという記述へ更新する

## テスト方針

モックやスタブは使用しない。テスト用の `VideoFilter` / `VideoRenderer` 実装は実 protocol に対する観測用の実装とし、既存の `CountingVideoFilter` (`SoraTests/ScreenCaptureFrameGenerationTests.swift:71-89`) と同じ方針で作る。

### Simulator (CI の unit test) で実行する

`SoraTests/StreamFrameOwnerTests.swift` を新設する。`ScreenCaptureFrameGenerationTests.swift` の `private` ヘルパー (`ScreenCaptureTestGate` / `makeSenderStream` / `makeSenderStreamWithVideoTrack` / `makeSampleBuffer`) は再利用できないため、同種のヘルパーを `SoraTests/StreamFrameOwnerTestHelpers.swift` に `internal` で定義し、両テストファイルから使う。

- `RecordingVideoFilter`: 呼び出し順と、同時実行の有無 (実行中フラグ) を記録する実 `VideoFilter`
- `SynchronousFilterGate`: `VideoFilter.filter` が同期メソッドであるため、actor ではなく `DispatchSemaphore` で filter を停止・再開するゲート (再開後は以降に到着する frame も停止しない)
- `RecordingVideoRenderer`: 7 種類の callback の順序と `Thread.isMainThread` を記録する実 `VideoRenderer`
- `makeSenderStreamWithVideoTrack(mediaChannel:)`: 既存テストと同じ構成を再定義し、`ScreenCaptureFrameGenerationTests.swift` の `private` ヘルパーを置き換える
- `makeTestConfiguration()` / `makeTestMediaChannel()`: `Configuration` と `MediaChannel` の構築を両テストファイルで共有する (`role` は `sendonly` 固定。別 role が必要になった時点で引数を追加する)
- `ownerForTesting(_ stream: MediaStream) -> StreamFrameOwner`: `BasicMediaStream` へ downcast して owner を取得する
- `drainSendVideoFrameQueueAndOwner(controller:senderStream:)`: 送信キューと owner queue の 2 段の処理完了を待つ
- `makeVideoFrameForTesting(timeStampNs:width:)` / `makeNativeVideoFrameForTesting(timeStampNs:width:)`: 実 CoreVideo の API で pixel buffer (高さは 48 固定) を作り、`RTCCVPixelBuffer` 経由で `RTCVideoFrame` を組み立てる

- 公開 `send(videoFrame:)` を `maxPendingFrameCount` と同数のスレッドから並行に呼び (`MediaStream` は Sendable ではないため既存の `SenderStreamBox` 経由で `@Sendable` closure へ渡す)、`RecordingVideoFilter` で「同一 stream で同時に 2 つの frame が filter に入らないこと」と「`processedSequencesForTesting` が昇順であり、filter を通った frame に欠落も重複も無いこと」を検査する。
- filter の交換と frame 入力を競合させ、各 frame が使った filter の instance を記録して、frame ごとに filter が一意に決まること (同じ frame が 2 つの filter を通らないこと) を検査する。`SynchronousFilterGate` で「停止 → 投入 → 交換 → 再開」と「交換 → 投入 → 再開」の 2 ケースを決定的に実行する。
- ingress の上限: `SynchronousFilterGate` で filter を停止し、`maxPendingFrameCount` を超える frame を投入して、`lastAcceptedSequenceForTesting` が 1 から 4 になること (5 件目以降は受理しない)、`discardedFrameCountForTesting` が投入数 - 4 になること、`processedSequencesForTesting` が上限までの frame だけを含むことを検査する。
- `terminate()` の後に投入した frame が filter へ到達しないこと、`terminate()` を 2 回呼んでも `onDisconnect` が 1 回であること、無効化の後に届いた renderer の frame / size / switch が配送されないことを検査する。`onDisconnect` の回数は callback の一覧ではなく `.disconnect` の件数で数える (frame を実 `RTCVideoSource` へ配送すると libwebrtc が登録済みの adapter へ frame / size を配送することがあるため)。
- renderer の順序: `RecordingVideoRenderer` で `onAdded` / `render` / `onChange(size:)` / `onSwitch(video:)` / `onDisconnect` / `onRemoved` の呼び出し順序と、各 callback の `Thread.isMainThread` を記録する。`onSwitch(audio:)` は音声トラックを持つ stream を使う別のテストで検査する。6 種類の callback がすべて main queue で配送されることを検査する。`frame` / `size` は `videoRendererAdapterForTesting` で取得した adapter の `renderFrame(_:)` / `setSize(_:)` を直接呼んで駆動する (adapter は libwebrtc から呼ばれる実 `RTCVideoRenderer` であり、実カメラは不要)。`frame` / `size` / `switch` は main queue 上で世代を照合するため、1 段ずつ配送を待ってから次の event を発生させる。
- `videoRenderer` の交換と `nil` 代入で、`onAdded` を受け取った renderer が必ず `onRemoved` を 1 回受け取ること (setter 経由の遷移に限る。`terminate()` は `onDisconnect` のみ)、交換前の adapter から届いた frame / size が新しい renderer へ配送されないことを、`videoRendererAdapterForTesting` を保持して検査する。
- 同一 instance を再設定した場合と、`nil` を `nil` へ代入した場合に、callback が 1 つも配送されず generation も進まず、前後で frame / size が引き続き同じ renderer へ配送されること (`.removed` が配送されて `VideoView.autoStop()` 相当の停止が起きないこと) を検査する。以前の renderer を解放した後に新しい renderer を設定した場合に、`.removed` が配送されず (解放済みのため) 新しい renderer に `onAdded` が 1 回来ること、generation が進んで旧 adapter の frame / size が配送されないことを検査する。
- `videoFilter` / `videoRenderer` の get / set を並行実行し、実行が完了して値が一意に定まること (data race が無いこと) を検査する。`videoRenderer` は `BasicMediaStream` の `rendererLock` が「同一 instance 判定 → `setRenderer` の採番と投入 → adapter の差し替え」を同一区間で行うため、adapter が指す renderer と owner が世代を照合する renderer が食い違わない。テストは並行 set / get の直後に getter で取り出した renderer が frame を受け取ることでこれを検査する (`SoraTests/StreamFrameOwnerTests.swift` の `testConcurrentVideoRendererSetKeepsStateConsistent` / `testConcurrentVideoFilterSetKeepsStateConsistent`)。data race そのものの検出は Thread Sanitizer (`0119`) の担当で、このテストは論理的な一意性を検査する。
- generation: `videoRenderer` を交換した後、旧 adapter から届いた frame / size が配送されず、`setRenderer` の戻り値で渡した generation と一致する frame / size だけが配送されること、generation 0 の frame / size が配送されないことを検査する。
- `VideoView.start()` が main queue 上で `isRendering` を同期で `true` にすること (`SoraTests/VideoViewStartTests.swift`。`start()` が積む非同期処理はテスト内で drain して、nib の遅延読み込みを別テストへ漏らさない)。
- `send` が `VideoFilter` の完了を待たずに戻ること (別スレッドから投入し、期限付きの待ち合わせで検査する)。
- `sequence`: `lastAcceptedSequenceForTesting` が 1 から始まること、`processedSequencesForTesting` が実行順の昇順であること、上限超過の破棄で `discardedFrameCountForTesting` が増え条件 1 / 2 / 4 の破棄では増えないこと、renderer 経由の frame を投入しても `lastAcceptedSequenceForTesting` が進まないこと (ingress とは別経路であること) を検査する。
- 破棄条件を個別に検査する。`nil` frame は filter が呼ばれないこと、video track を持たない stream (`makeSenderStream`) では source が `nil` のため filter が呼ばれないことを確認する。
- `SoraTests/ScreenCaptureFrameGenerationTests.swift` は owner の drain を挟んだうえで、既存の期待値 (filter 到達回数 / permit の会計 / 間引きと drop の条件) を維持する (詳細は「既存テストへの影響」)。
- `DummyVideoCapturer` を使う E2E (`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `RpcE2ETests`) は待ち方を変更せずに成功することを確認する。
- camera 経路と screen capture 経路は「3 入力元が同じ `send` を通ること」をコードで確認する。`CameraVideoCapturerDelegate` は private であり、Simulator に実カメラと実 ReplayKit が無いため、入力元ごとの並行入力は自動テストの対象にしない。
- テストには、入力元ごとの event sequence と期待する破棄条件を日本語コメントで明記する。

### 既存テストへの影響

- `SoraTests/ScreenCaptureFrameGenerationTests.swift` の `VideoFilter` 到達回数の assert は `send` の同期性に依存する。owner の drain seam を追加して待つ (`drainSendVideoFrameQueueAndOwner(controller:senderStream:)` が「送信キュー → owner queue」の 2 段を drain する)。
- `Sora/ScreenCapture.swift` の flight permit は `send` から戻った時点で返却される。SDK 内部の呼び出し元 (`processOwnedFrame`) は `send` の後に frame を参照も変更もしないため `send` の doc の義務は満たすが、配送段の上限制約は owner の `maxPendingFrameCount` になる。`markVideoFrameSent` が `send` の前に走るため、上限で破棄された frame も `targetFPS` の間引き基準に残る。`targetFPS` は上限であり保証値ではない。
- `terminate()` の `onDisconnect` が非同期配送になるため、`terminate()` の直後に renderer callback を assert する既存テストがあれば待ち方を変更する (`SoraTests` には該当する renderer callback の assert が無いことを確認済み)。

### テストで再現できない防御経路

次の経路は決定的に再現する手段が無いため、テスト対象に含めず、コードで確認する。

- 採らなかった代替案: `RTCVideoSource` への配送を `CameraQueueExecutor` (`Sora/CameraVideoCapturer.swift:648-653`) 経由へ戻す方式。実カメラとそれに依存する vendor の挙動が必要で Simulator では再現できないため、実機で owner queue 配送が問題になった場合の代替として記録する。
- owner queue が停止した状態で `terminate()` が呼ばれ、`pendingRendererDeliveries` が解放されない経路。owner queue の停止を外部から作る手段が無い。
- video track を持たない stream で `nativeVideoTrack?.source` が `nil` になることは再現できる (`makeSenderStream`) が、track 構成が実行中に変わる経路は再現できない (破棄条件 2 のテストで代表させる)。

### 実機で手動確認する (CI では未検証として区別する)

実機確認は `sora-ios-sdk-samples` のサンプルアプリで行う (SwiftPM のテストは tool-hosted のため実機で実行できない)。debug ログを有効化して破棄の発生を観測する。

- 実カメラの frame が owner queue 経由で `RTCVideoSource` へ配送され、送信と `VideoView` の preview が継続すること。frame が破棄されて送信が止まらないこと。
- 実 ReplayKit の画面キャプチャ送信が継続すること。
- カメラと画面キャプチャを切り替えても filter の順序が崩れないこと。
- 切断と redirect の直後 (無効化と `nativeChannel.close()` の直後) に assertion / crash が出ないこと (「frame 破棄の判定」の 1 frame 分の窓の確認)。
- `VideoView` に `videoRenderer` を設定した直後の frame が `isRendering == false` で破棄されず、preview が開始されること (`start()` の同期化の確認)。`Sora/VideoView.swift` の描画は key window に依存するため CI では再現できない。
- 代替案 (`CameraQueueExecutor` 経由) は採らない。採る場合はその構成でのみ未検証項目として区別する。
- 確認結果は 0104 と同じく本 issue の `## 解決方法` に「実機で確認した項目 / 未検証項目」として記録する。

## 完了条件

- `BasicMediaStream` ごとに frame 処理の owner が 1 つ存在し、frame の受理、`VideoFilter` の実行、`RTCVideoSource.capturer(_:didCapture:)` の呼び出しが同じ owner queue 上で直列に行われること。renderer event は owner queue で順序が決定され、main queue で FIFO に配送されること。
- camera、screen capture、public send の 3 入力元が同じ ingress を経由すること (コードで確認する)。受理順に `sequence` が採番され、採番と owner queue への投入が同一 lock 区間で行われること (テストで検証する)。
- legacy `VideoFilter` が owner queue 上でだけ実行され、同一 stream で同時に 2 つの frame が filter に入らず、filter の交換と frame 入力が競合しても各 frame が使う filter が一意に決まること (テストで検証する)。
- ingress の未処理 frame の上限が実装され、超過した frame が `RTCVideoSource` と renderer へ配送されないこと (テストで検証する)。
- `terminate()` 以降に到着した frame と renderer の frame / size / switch event が配送されず、`terminate()` が冪等で、`onDisconnect` が 1 回だけ配送されること (テストで検証する)。
- `terminate()` の直後に renderer を取り外した場合も、無効化時の renderer が `onDisconnect` を受け取ること。`terminate()` の後に設定した renderer へは何も配送されず、getter が無効化時の renderer を返すこと (テストで検証する)。
- renderer 経由の frame の配送待ち件数が `maxPendingRendererFrameCount` で制限され、配送で減算されて次の frame が受理されること (テストで検証する)。
- `transportEpoch` を frame の破棄判定に使っていないこと。
- 本 issue で新設した `@unchecked Sendable` 型が `StreamFrameOwner` と `StreamOwnedFrame` の 2 つだけで、それぞれの根拠が「StreamFrameOwner」と「frame の ingress と所有表現」に書いた内容に限定して型 doc に書かれていること (retain をヘッダ保証として書いていないこと)。`SenderStreamBox` を置き換えていないこと。
- 公開 protocol `MediaStream` に requirement を追加していないこと。`VideoRendererAdapter` の既存 event box と `TODO(zztkm)` が削除されていること。
- legacy `VideoRenderer` の 7 種類の callback (`onAdded` / `render` / `onChange(size:)` / `onSwitch(video:)` / `onSwitch(audio:)` / `onRemoved` / `onDisconnect`) が owner の順序で main queue へ FIFO 配送されること。`videoRenderer` の setter で `nil` を代入または交換した場合に、`onAdded` を受け取った renderer が必ず `onRemoved` を 1 回受け取り、交換前の adapter から届いた frame / size が配送されないこと (テストで検証する)。同一 instance の再設定と `nil` から `nil` への代入では何も配送されず generation も進まないこと (テストで検証する)。`videoRenderer` の getter / setter を並行実行しても、adapter が指す renderer と owner が世代を照合する renderer が食い違わず、選択された renderer に frame が配送されること (テストで検証する)。
- renderer の `frame` / `size` / `switch` が、generation の不一致時と未設定 (0) のときに配送されないこと。generation の採番主体が `setRenderer` と `clearRenderer` であり、adapter は init で受け取った世代を書き換えないこと (テストと `git diff` で検証する)。
- ingress の `sequence` が 1 から始まり、`lastAcceptedSequenceForTesting` が受理した frame の最後の値を返すこと (受理後に条件 4 で破棄された frame を含む)。`processedSequencesForTesting` には owner queue で処理まで進んだ frame だけが現れること。上限超過の破棄が `discardedFrameCountForTesting` に加算され、条件 1 / 2 / 4 の破棄は加算されないこと (テストで検証する)。renderer 経由の frame が ingress の `sequence` を消費しないこと (テストで検証する)。
- `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の executor が現行のまま (`VideoHardMuteActor` または呼び出し元) であり、renderer の `onSwitch` とは executor が異なることが doc に書かれていること。
- `send(videoFrame:)` の doc に「ingress へ投入して戻る」契約、破棄条件、`nil` の扱い (何もしない)、frame の所有権が SDK へ移り `send` が戻った後に参照・変更しないことが書かれ、doc と実装が一致していること。`videoRenderer` / `videoEnabled` / `audioEnabled` の setter が callback の配送完了を待たないことが doc に書かれていること。
- `CameraVideoCapturerHandlers.onCapture` と `ScreenCaptureSettings.videoSampleBufferTransformer` の実行 executor と、ingress に対する位置が doc に書かれていること。
- `skills/sora-ios-sdk/SKILL.md` の映像節に `VideoFilter` / renderer callback の executor 契約、`send` の配送契約、無効化後の破棄が書かれていること。
- `CHANGES.md` の `## develop` に `- [UPDATE] MediaStream の映像フレーム処理 executor を単一化する` の entry が `  - @t-miya` 付きで追加されていること。
- `SoraTests/StreamFrameOwnerTests.swift` の追加テストと、owner の drain を追加した `SoraTests/ScreenCaptureFrameGenerationTests.swift` を含む既存テストがすべて成功すること。
- 実カメラ経由の配送は実機で確認され、未検証項目として区別され、結果が `## 解決方法` に記録されていること。

### 検証手段

- 入力元の統一: `grep -rn "\.send(videoFrame:" Sora/` の結果のうち実装の呼び出しが、`Sora/CameraVideoCapturer.swift` の delegate 2 件 (`onCapture` の有無で分岐)、`Sora/ScreenCapture.swift` の 2 件 (internal な `send(videoFrame:retaining:)` と public な `send(videoFrame:)` へのフォールバック) の合計 4 件であることを確認する (その他の一致は doc の言及であり、`Sora/MediaStream.swift` の実装は `.send` を伴わずに `send(videoFrame:retaining:)` を呼ぶ)。
- ingress の順序: `Sora/StreamFrameOwner.swift` の ingress が `nativeVideoTrack?.source` の解決を lock の外で行い、条件 4 → 条件 2 → 条件 3 の判定と sequence の採番・未処理数の加算・owner queue への投入を 1 つの lock 区間で行っていることをコードで確認する。
- generation: `setRenderer` の戻り値で generation を受け取り adapter に渡していること、adapter がその値を書き換えないこと、generation 0 の frame / size を破棄することをコードとテストで確認する。
- `sequence` の観測: `lastAcceptedSequenceForTesting` / `processedSequencesForTesting` / `discardedFrameCountForTesting` がテストから読め (`processedSequencesForTesting` は `#if DEBUG` のため Debug 構成で実行する)、renderer 経由の frame が ingress の `sequence` を消費しないことをテストで確認する。
- owner の一意性: `grep -n "StreamFrameOwner(" Sora/MediaStream.swift` が 1 件であり、他のソースファイルに owner の生成が無いことを確認する (`grep -rn "StreamFrameOwner(" Sora/` の結果が `Sora/MediaStream.swift` の 1 箇所だけ)。
- `@unchecked Sendable` の限定: `grep -rn ": @unchecked Sendable" Sora/StreamFrameOwner.swift Sora/MediaStream.swift Sora/VideoRenderer.swift` の結果が型宣言 2 件 (`StreamFrameOwner` / `StreamOwnedFrame`) と型 doc の説明文だけで、新しい型の宣言が増えていないことを確認する。`grep -n "VideoRendererFrameEvent\|VideoRendererSizeEvent\|TODO(zztkm)" Sora/VideoRenderer.swift` が 0 件であることも確認する。
- 型 doc: `Sora/StreamFrameOwner.swift` の `StreamFrameOwner` / `StreamOwnedFrame` の型 doc が「StreamFrameOwner」と「frame の ingress と所有表現」の記載と一致し、`retain` を寿命の根拠として書いていないことを目視で確認する。
- 公開 protocol の互換: `git diff -- Sora/MediaStream.swift` に `MediaStream` protocol の requirement の追加が無いこと、`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の executor の記述を変更していないことを確認する。
- `transportEpoch` を frame 破棄に使っていないこと: `grep -n "transportEpoch\|dataChannelGeneration" Sora/MediaStream.swift Sora/StreamFrameOwner.swift` が 0 件であることを確認する。
- ビルド: `xcodebuild build-for-testing -scheme Sora-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6` (`.github/workflows/ci.yml:53-62`) が成功し、変更したファイルに新しい `#SendableClosureCaptures` warning が出ないことを、`xcodebuild ... 2>&1 | grep -c SendableClosureCaptures` の結果で確認する (CI は warnings-as-errors ではない)。
- テスト: 同じ `xcodebuild test-without-building` の実行 (`.github/workflows/ci.yml:83-89`) で全テストが成功すること。
- format / lint: `make fmt-lint` と `make lint` が違反 0 であること。
- 公開契約の記載: `git diff` で `Sora/MediaStream.swift`、`Sora/VideoFrame.swift`、`Sora/VideoCapturer.swift`、`Sora/VideoRenderer.swift`、`Sora/VideoView.swift`、`Sora/CameraVideoCapturer.swift`、`Sora/ScreenCapture.swift`、`Sora/MediaChannel.swift`、`skills/sora-ios-sdk/SKILL.md`、`CHANGES.md` の doc と記載を確認する。
- `SenderStreamBox` を変更していないこと: `git diff -- Sora/VideoMute.swift` に `SenderStreamBox` の変更が無いことを確認する。
- 実機確認: 「実機で手動確認する」の各項目をサンプルアプリで実施し、未検証項目を区別する。

## 解決方法

### 実装

`BasicMediaStream` ごとに frame 処理の owner を 1 つ置き、映像 frame の受理から `VideoFilter` の実行、`RTCVideoSource` への配送までを owner queue へ集約した。

- `Sora/StreamFrameOwner.swift` (新規): `StreamFrameOwner` と ingress payload の `StreamOwnedFrame`。ingress は `submitIngressFrame(_:videoSource:retaining:)` の 1 経路であり、無効化 (条件 4)、video source なし (条件 2)、未処理上限 `maxPendingFrameCount = 4` (条件 3) の判定、`sequence` の採番、未処理数の加算、payload の生成、owner queue への投入を同じ lock 区間で行う。`nil` frame (条件 1) は `send` の入口で破棄し、`sequence` も `discardedFrameCount` も消費しない。`process` は owner queue 上で filter を実行して `RTCVideoSource.capturer(_:didCapture:)` を呼び、無効化済みなら配送せず破棄する。
- renderer の配送は `added` / `removed` / `frame` / `size` / `switch` / `disconnect` を owner queue で順序付け、`generation` の照合で古い adapter からの frame / size / switch を破棄して main queue へ FIFO 配送する。renderer 経由の frame の配送待ちは `maxPendingRendererFrameCount = 4` で制限する。
- `Sora/MediaStream.swift`: `streamOwner` を保持し、`send(videoFrame:)` は `send(videoFrame:retaining:)` 経由で ingress へ投入して戻る。`videoFilter` は owner へ委譲し、`videoRenderer` の get / set は `rendererLock` で直列化する。`terminate()` は owner を無効化し、無効化時の renderer へ `onDisconnect` を 1 回だけ配送する。
- `Sora/VideoRenderer.swift`: `VideoRendererAdapter` が `setRenderer` の戻り値の世代を保持し、adapter の event box と `TODO(zztkm)` を削除した。
- `Sora/VideoView.swift`: `start()` は main queue 上で `isRendering` を同期設定し、設定直後の frame が破棄されないようにした。
- `Sora/ScreenCapture.swift`: `processOwnedFrame` は internal な `send(videoFrame:retaining:)` で画素データの所有権ごと ingress へ渡す。`0104` が委譲した「`ScreenCaptureOwnedFrame` を ingress へ接続する」は、この経路で配送完了まで所有権を保つこととして実現した。`senderStream` が `BasicMediaStream` でない場合は public `send(videoFrame:)` へフォールバックし、到達を debug ログで観測できるようにした。
- `transportEpoch` は frame の破棄判定に使っていない。音声の送受信経路と audio sink、`SenderStreamBox`、`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の executor は変更していない。
- doc (`MediaStream` / `VideoFrame` / `VideoCapturer` / `VideoRenderer` / `VideoView` / `CameraVideoCapturer` / `ScreenCapture` / `MediaChannel`)、`skills/sora-ios-sdk/SKILL.md`、`CHANGES.md` を更新した。

### 検証

- `make fmt-lint` と `make lint` (SwiftLint 56 files) は違反 0。
- `xcodebuild build-for-testing -scheme Sora-Package -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6` が成功し、`test-without-building` で E2E 以外の 332 tests が 0 failures (6 skipped)。`SoraTests/StreamFrameOwnerTests.swift` と `SoraTests/VideoViewStartTests.swift` は 5 回反復して 135 tests 0 failures。
- `SoraTests/StreamFrameOwnerTests.swift` を追加し、`SoraTests/ScreenCaptureFrameGenerationTests.swift` に owner の drain を追加した。

### 実機で確認した項目

`sora-ios-sdk-samples` のサンプルアプリを Debug + Address Sanitizer で実機 (iPhone14,7 / iOS 26.6.1) にインストールして確認した。`SamplesApp` は `../../sora-ios-sdk` をローカルパッケージとして参照しており、実機用バイナリに本 issue で追加した全ログ文字列が含まれることを確認した (ビルド取り違えの防止)。

- VideoChat サンプル: 実カメラの frame が owner queue 経由で `RTCVideoSource` へ配送され、送信と `VideoView` の preview が継続した。`media-source` の frames が 29 (30.4 fps) と 12 (38.6 fps)、`outbound-rtp` の framesSent / framesEncoded が増加し、サーバーの `network.status` は 10 秒間で 248646 bytes の RTP 送信を報告した。preview は目視でも表示され続けた。
- VideoChat サンプル: flip (1 回目 2 回、2 回目 1 回) と映像・音声のミュート切り替えを跨いで、破棄ログ、異常ログ、assertion、crash、Address Sanitizer のレポートはいずれも 0 件だった。切断 2 回でも同様である。
- ScreenCast サンプル: ReplayKit の画面キャプチャ (`ScreenCaptureSettings(targetFPS: 15)`) を 45 秒間送信した。`processOwnedFrame` のフォールバック ログは 0 件であり、画素データの所有権を ingress が保持する経路が使われた。破棄ログと Address Sanitizer のレポートは 0 件である。停止直前の `VideoSendStream stats` は 2 本で、`input_fps: 21 / encode_fps: 21 / media_bps: 443872` と `input_fps: 31 / encode_fps: 31 / media_bps: 439088` であり、画面キャプチャ側も停止まで連続して符号化されていた。
- ScreenCast サンプル: `videoRenderer = nil` (カメラサムネイルの teardown) と `VideoView.start()` (手動接続モード) を含む経路で異常はなかった。
- VideoFilter の実行 executor と順序: VideoChat サンプルへ一時的な `VideoFilter` 実装 (実行 queue、同時実行数、timestamp、frame サイズを記録) を追加し 3 回実行した。全ログが `queue=jp.shiguredo.sora.mediaStream.frameOwner` かつ `mainThread=false`、`maxInFlight=1`、`concurrencyViolations=0`、`timestampRegressions=0`、`duplicateTimestamps=0` であり、`concurrent filter entry` は 0 件だった。1 回目は 953 frame (filter A 429 / filter B 524) を観測し、frame が流れている状態で filter を交換 (2 回)・解除・再設定した。A は 270 frame で停止し、再設定後に 271 から連番で継続した (欠落も二重処理も無い)。カメラ (1280x720=485) と画面キャプチャ (888x1920=39) が同じ owner queue の同じ filter を通った。2 回目と 3 回目 (redirect の確認を兼ねる) は 527 frame と 349 frame で、すべての集計が同じ不変条件を満たした。
- redirect: VideoChat サンプルで `wss://sora-node1.tmiya83.com/signaling` から `{"type":"redirect","location":"wss://sora-node2.tmiya83.com/signaling"}` を受理し、`redirect: invalidating old transport (generation => 1)` の後に node2 へ再接続して、以降のカメラ・画面キャプチャ・filter が正常に動作した。crash / assertion / Address Sanitizer のレポートは 0 件である。
- 上限超過の破棄: 初回接続の 12:54:47 に `discard video frame: pending frame count reached 4, discarded 1` から `3` までが 1 回だけ発生した。同時刻に `thread.cc:551 Message to signaling_thread ... took 169ms to dispatch` と `AVAudioSession` の設定があり、接続直後の高負荷 (Address Sanitizer 有効) で owner queue が 4 frame 分遅れたもの。設計どおりの上限破棄であり、以降 135 秒間は再発せず配送は継続した (他の 3 回の実行では 0 件)。

画面キャプチャ (`ScreenCaptureSettings(targetFPS: 15)`) の供給レートは実測で約 1.6〜2.9 fps だった (3 回の実行すべて)。SDK の間引きは「直前の送信から 1/15 秒以上経過した frame を通す」だけなので、ReplayKit が渡す buffer 数が少ないことになる。画面がアニメーションしていた ScreenCast サンプルでは同じ経路で 21 fps だったため、画面の更新が少ないことによる供給減と推定するが、ReplayKit のコールバック数を計測していないため断定はしない。

実機で観測した本 issue と無関係な警告は 2 件である。`video_stream_encoder.cc:1646 Same/old NTP timestamp ... Dropping.` が 1 件 (カメラ再起動直後に同一 timestamp の frame が届いたもの。ingress は timestamp を変更せず frame も複製しないため、AVFoundation の再起動由来) と、`video_render_frames.cc:75 Frame scheduled out of order` が 2 件 (受信側の render scheduler で、ずれは 14 ms と 25 ms。ネットワーク揺らぎ由来) である。

### redirect と frame 経路

redirect は Sora の仕様上 `connect` への応答としてのみ送信され、WebRTC 接続確立後にサーバーからクライアントへ送信して別のノードへリダイレクトさせることはできない。redirect の時点で `MediaStream` はまだ生成されておらず、実機でも `redirect: terminated N streams` は出力されなかった (該当時点で `streams` が空)。したがって `PeerChannel` の redirect 処理にある `streams.terminate()` は frame 経路へ影響せず、「旧 stream の frame が新しい接続へ混入する」状況は redirect では発生しない。frame の破棄と renderer event の抑止は切断経路 (`terminate()`) で確認している。

`ScreenCaptureController.senderStream` は開始時に固定されるため、仮に接続確立後に redirect が発生した場合は画面キャプチャが旧 stream へ送り続けて復帰しない。ただしその状況は上記のとおり仕様上発生しないため、本 issue では変更しない。

`PeerChannel` の redirect 処理にある旧 transport の無効化 (`streams.terminate()` を含む) は、この前提では対象が常に空で到達しない。この防御コードを残すか削除するかは `0164` で扱う。

### 未検証項目

- 無効化の判定後から `nativeChannel.close()` までに実行中の `RTCVideoSource.capturer(_:didCapture:)` が並行する 1 frame 分の窓。今回のログでは無効化時点の未処理 frame が 0 件であり、この窓を踏んだ証拠は無い。Address Sanitizer では data race を検出できないため、Thread Sanitizer (`0119` の CI 整備待ち) での確認が残る。
- Release 構成での単体テスト。`processedSequencesForTesting` が `#if DEBUG` のため、CI と同じ Debug 構成でのみ実行している。
