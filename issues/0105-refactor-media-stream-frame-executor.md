# MediaStream の映像フレーム処理 executor を単一化する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-media-stream-frame-executor
- Polished: 2026-09-17

## 優先度根拠

- `BasicMediaStream.send(videoFrame:)` は呼び出し元の executor 上で `VideoFilter` を実行し `RTCVideoSource` へ frame を渡す (`Sora/MediaStream.swift:273-287`)。filter の実行順序と交換、`terminate()` 後の破棄がコード上の契約になっていない。
- 公開 API を増やさない内部構造の整理だが、`VideoFilter` と renderer callback の実行 executor という利用者が観測できる契約が変わるため Medium とする。
- `0027` / `0110` / `0122` が本 issue の完了を前提にしており、`0103` / `0104` が frame 経路の未決事項を本 issue へ委譲している。

## 目的

`MediaStream` へ入力される映像 frame の受理から `VideoFilter` の実行、`RTCVideoSource` への配送、renderer への add / frame / size / switch / remove / disconnect の配送までを、stream ごとの 1 つの ordered executor へ集約する。

カメラ、画面キャプチャ、利用者の直接送信が並行しても filter の実行順序が崩れず、`terminate()` または切断の後に到着した frame が `RTCVideoSource` と renderer へ配送されない構造にする。音声の送受信経路と audio sink は変更しない。

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

renderer frame は `RTCVideoTrack.addRenderer` で登録した adapter へ libwebrtc から配送される (`Sora/VideoRenderer.swift:64-96`)。`BasicMediaStream.send(videoFrame:)` はこの経路に関与しないため、SDK 側の ingress の sequence を renderer frame に付与できない。

### frame の所有

`VideoFrame` は `.native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)` の 1 ケースだけである (`Sora/VideoFrame.swift:10-15`)。pixel buffer を保持するケースは無く、`init?(from: CMSampleBuffer)` も `RTCCVPixelBuffer` に包んだ `RTCVideoFrame` を作る (52-63 行)。`VideoFrame` / `RTCVideoFrame` / `RTCCVPixelBuffer` / `RTCVideoCapturer` は `Sendable` ではない (`WebRTC.xcframework` のヘッダに `NS_SWIFT_SENDABLE` はない)。`RTCVideoFrame` の `timeStamp` (90kHz) は assign 可能であり、ヘッダには retain の記載も無い。

既存の unchecked 越境は 2 つある。`VideoRendererFrameEvent: @unchecked Sendable` が `VideoFrame` を main queue へ渡し (`Sora/VideoRenderer.swift:29-37, 93-95`)、`SenderStreamBox: @unchecked Sendable` が `MediaStream` を actor 境界へ渡す (`Sora/VideoMute.swift:22-28`)。

### 終了と再ネゴシエーション

`terminate()` は公開 protocol の要件であり (`Sora/MediaStream.swift:114`)、`PeerChannel` が redirect 受理時 (`Sora/PeerChannel.swift:1691-1701`) と切断時 (`:1834-1837`) に全 stream へ呼ぶ。`0095` (完了) がこの終端を「旧 PeerConnection の frame を新接続へ混入させない」防御として確定している。

`ConnectionLifecycleState.transportEpoch` は redirect 受信時だけ加算され (`Sora/ConnectionLifecycle.swift:14, 104-107`)、`PeerChannel.dataChannelGeneration` (`Sora/PeerChannel.swift:366-369`) としてのみ読める。frame 経路からは参照されていない。

re-offer / re-answer の再ネゴシエーションでは `initialOffer == false` のため `initializeSenderStream` を呼ばず stream を作り直さない (`Sora/PeerChannel.swift:1172-1177`)。`didAdd` は同じ stream ID の stream が既にある場合は無視される (`:2022-2028`)。

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
- `0163` (open): `videoEnabled` / `audioEnabled` の変更を operation 単位で直列化する。本 issue から切り出した作業であり、`0136` が残した排他を扱う。
- `0159` (open): `setVideoHardMute(true)` 失敗時のカメラ予約の扱いを扱う。本 issue では変更しない。
- `0154` (open): `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` の closure 排他を扱う。`MediaStreamHandlers` は対象外のため、本 issue で `0154` の対象に追加する。
- `0027` (open): 「`0105` で frame ownership、stream epoch、sequence、全 renderer callback の ordered ingress を確立する」として本 issue を前提にしている (`:41, :56`)。本 issue は sequence と renderer 配送の順序付けを提供する。
- `0110` (open): stream の frame event の順序保証を本 issue に委ねている (`:41, :86`)。
- `0122` (open): 「`0105` の ordered frame / renderer ingress が実装済みであること」(`:14`) を前提にし、「renderer callback は `0105` の sequence / epoch 付き ordered ingress だけから配送する」(`:36`) としている。
- `0119` / `0151` (open): Thread Sanitizer の CI 基盤は未整備で、手動 TSan 実行は `0151` の競合で失敗する。完了条件に含めない。
- `0107` / `0108` (open): Swift 6 consumer fixture と言語モード。本 issue は `SWIFT_VERSION=6` のビルドで検証する。

## 設計方針

### StreamFrameOwner

`Sora/StreamFrameOwner.swift` を新設し、`BasicMediaStream` ごとに 1 つの owner を持たせる。

- `final class StreamFrameOwner: @unchecked Sendable`。非 Sendable な値は owner queue または lock 区間の中だけで読み、外部の executor へ参照を渡さない。
- serial `DispatchQueue` (`label: "jp.shiguredo.sora.mediaStream.frameOwner"`) を持ち、frame の受理、`VideoFilter` の実行、`RTCVideoSource` への配送、renderer event の配送をこの queue 上で直列に行う。`CameraStateOwner` (`Sora/CameraStateOwner.swift`) と同じ「serial queue + lock 付き storage」方式とし、同期 getter は owner queue を wait しない。
- 保持する状態は次に限定し、すべて `NSLock` で保護する。`let videoSource: RTCVideoSource?` (生成時に 1 回だけ解決)、`var videoFilter: VideoFilter?`、`var renderer: (generation: UInt64, value: VideoRenderer?)`、`var pendingRendererDeliveries: [StreamRendererDelivery]`、`var sequence: UInt64` (frame の ingress 用)、`var rendererDeliverySequence: UInt64` (renderer event の診断用)、`var pendingFrameCount: Int`、`var isInvalidated: Bool`。owner は `MediaStream` / `PeerChannel` を保持しない。
- `onAdded(from:)` / `onRemoved(from:)` に渡す `MediaStream` と `onDisconnect(from:)` に渡す `MediaChannel?` は、配送要素が配送完了まで強参照してから解放する。setter は同期呼び出しの引数として `BasicMediaStream` 自身を渡し、`terminate()` は呼び出し元の executor で `peerChannel.mediaChannel` を読んで引数として渡す。配送時に弱参照を解決し直さないため、`BasicMediaStream` や `MediaChannel` が先に解放されても callback の引数を失わない。
- owner を強参照するのは `BasicMediaStream` だけとする。`VideoRendererAdapter` は owner を弱参照する。owner queue へ投入する block は owner を強参照し、投入済みの event は `BasicMediaStream` の解放後も完了させる。`deinit` では queue へ何も投入しない。
- `BasicMediaStream.init` で `videoSource` を解決して owner を生成する。`lazy var` の初回アクセスを複数スレッドから行わないよう、`init` の最後に一度だけ触れて初期化を確定する。
- API は `submit(_ frame: RTCVideoFrame)` (ingress)、`videoFilter` の get / set、`setRenderer(_ stream: MediaStream, _ renderer: VideoRenderer)` / `clearRenderer(_ stream: MediaStream)`、`submitRendererFrame(_:)` / `submitRendererSize(_:)`、`submitSwitch(video:)` / `submitSwitch(audio:)`、`invalidate(disconnectFrom: MediaChannel?)`、`drainForTesting()`、`lastAcceptedSequenceForTesting` / `lastProcessedSequenceForTesting` (テスト用) とする。
- `internal static let maxPendingFrameCount = 4` を上限とする。画面キャプチャの permit が 1、`targetFPS` の上限が 120、カメラが 30fps 程度であるため、未処理 4 件 (30fps で約 130ms) を超えたら利用者 filter が入力に追従できていないと判断する。処理中の 1 件も未処理数に含める。
- lock を保持したまま利用者 callback (`VideoFilter.filter(_:)`、`VideoRenderer` の各 callback) と native 呼び出し (`RTCVideoSource.capturer(_:didCapture:)`、`RTCVideoTrack.add` / `remove`) を実行しない。lock 区間では参照・世代・sequence・未処理数を読むだけにする。

### frame の ingress と所有表現

- `send(videoFrame:)` は同期 API のまま、frame を owner の ingress へ投入して戻る。filter の実行と `RTCVideoSource` への配送の完了は待たない。待たせると、呼び出し元が camera の capture session queue と screen capture の `sendVideoFrameQueue` であるため、利用者 filter が同じ queue へ hop する API を呼んだ場合に deadlock し得る。受理と破棄は戻り値で示さず、debug ログに出す。
- ingress では lock 区間で「上限判定 → sequence の採番 → 未処理数の加算 → owner queue への投入」をまとめて行う。別区間に行うと、並行する `send` が採番順と実行順で入れ替わる。
- owner queue へ渡す payload は `StreamOwnedFrame` (internal) とする。保持するのは `RTCVideoFrame` と `sequence: UInt64` だけであり、`RTCVideoCapturer` は含めない。`RTCVideoSource` は `RTCVideoCapturerDelegate` に準拠するが (`RTCVideoSource.h`)、ヘッダに capturer 引数を利用する記述は無く、`RTCVideoCapturer` は `weak delegate` を持つ可変オブジェクト (`RTCVideoCapturer.h`) であるため、配送時は現行と同じく不変なダミー instance を使う。ダミー instance は `Sora/StreamFrameOwner.swift` へ移す。
- `StreamOwnedFrame` の `@unchecked Sendable` の根拠は次の 2 点に限定して型 doc に書く。
  1. SDK は `RTCVideoFrame` を書き換えない (`timeStamp` は assign 可能だが SDK は設定しない)。`RTCVideoFrame` の retain はヘッダで保証された契約ではなく実装依存であるため、「retain で寿命が保たれる」ことは根拠に含めない。代わりに `send(videoFrame:)` の doc に「配送が完了するまで呼び出し側が画素データを書き換えず、buffer pool へ返さないこと」を明記し、利用者側の義務とする。
  2. 同時に参照を保持する executor は常に 1 つであり、所有権は「生成側 → owner queue → (renderer 配送時は) main queue」の順に 1 回ずつ移り、移譲元は以後その値を参照しない。
- `ScreenCaptureOwnedFrame` (`Sora/ScreenCapture.swift:203-216`) の移動は変更しない。`processOwnedFrame` が `sendVideoFrameQueue` 上で作った `VideoFrame` を、`send` が `StreamOwnedFrame` へ詰め替える。0104 が定めた「callback → 送信キューへの 1 回の移動」は維持され、owner queue へ移るのは `StreamOwnedFrame` である。`sendVideoFrameQueue` と `videoSampleBufferTransformer` の executor は現行のまま維持する。
- 「広域の `@unchecked Sendable` wrapper」を新設しない。本 issue で新設する `@unchecked Sendable` 型は `StreamFrameOwner` と `StreamOwnedFrame` の 2 つだけであり、それぞれの根拠を型 doc に書く。`SenderStreamBox` のような複数の呼び出し元で共有する箱は追加しない。

### VideoFilter

- legacy `VideoFilter` は owner queue 上でだけ実行する。同一 stream で同時に 2 つの frame が filter に入ることはない。同じ `VideoFilter` instance を複数の stream で共有した場合は owner queue が別であるため直列化されず、その排他は利用者の責任であることを `Sora/VideoCapturer.swift` の doc に書く。
- `videoFilter` の get / set は owner の lock 付き storage で排他する。owner queue は frame の配送直前に同じ lock 区間で filter を読む。各 frame が使う filter は「owner が読み取った時点の値」として一意に決まり、交換と frame 入力が競合しても 1 つの frame が 2 つの filter を通ることはない。交換自体を owner queue の event にしないため、非 Sendable な `VideoFilter` を `@Sendable` closure へ持ち込まない (`0103` が `stream` の setter から owner queue を `sync` しないと決めたのと同じ理由)。交換は受理済み frame の実行順とは同期しないことを doc に書く。
- `VideoFilter` に `Sendable` を要求せず、既存 conformer を壊さない。
- frame 加工フックは `VideoFilter.filter` の他に `CameraVideoCapturerHandlers.onCapture` (`Sora/CameraVideoCapturer.swift:1622`) と `ScreenCaptureSettings.videoSampleBufferTransformer` (`Sora/ScreenCapture.swift:29`) がある。どちらも実行 executor を変更しない。`onCapture` は capture session queue 上で ingress の前に、`videoSampleBufferTransformer` は `sendVideoFrameQueue` 上で ingress の前に実行される (現行どおり)。それぞれの doc にこの位置関係を追記する。

### RTCVideoSource への配送

- owner queue 上で `RTCVideoSource.capturer(_:didCapture:)` を呼ぶ。入力元ごとに配送 executor を分けない。filter の実行と配送を同じ直列 executor で行わないと、3 入力元をまたいだ順序を保証できないためである。
- `RTCVideoSource` は `RTCVideoCapturerDelegate` を実装し、ヘッダに thread 契約の記載はない (`RTCVideoSource.h`)。`RTCCameraVideoCapturer` の native 操作と delegate callback を capture session queue 上で行う制約 (`Sora/CameraVideoCapturer.swift:645-676`) は維持し、変更するのは「delegate が受け取った frame を source へ転送する executor」だけである。画面キャプチャ経路と public send 経路は現行でも capture session queue 以外から source を呼んでいる (`dummyCapturer` を使う `Sora/MediaStream.swift:281-283`、`Sora/ScreenCapture.swift:727`)。
- `RTCVideoSource` の呼び出しは owner の中の 1 箇所に閉じ、`0070` の Phase 3 / Phase 4 (`issues/0070-change-migrate-to-webrtc-c-xcframework.md:86, 342-343`) で置き換える対象をこの 1 箇所にする。
- 実機で次を確認する。(1) owner queue から source を呼んでも debug / release の両構成で frame が encoder へ到達し続けること。(2) 数分間の連続送信で frame 到達数の低下、preview の停止、assertion が発生しないこと。配送を `CameraQueueExecutor` (`Sora/CameraVideoCapturer.swift:648-653`) 経由へ戻す fallback を採る場合は、「owner queue は配送待ちの間、ingress の lock と filter の lock を保持しない」ことを実装制約とし、owner queue を同期 wait する経路が無いことを確認する。fallback は CI では検証できないため、採る場合は未検証項目として区別する。

### renderer への配送

- owner は renderer event を owner queue 上で順序付け、internal な enum `StreamRendererDelivery` (`added` / `removed` / `frame(StreamOwnedFrame?)` / `size(CGSize)` / `switchVideo(Bool)` / `switchAudio(Bool)` / `disconnect`) として配送する。renderer event の順序は owner queue への投入順で確定し、診断用に `rendererDeliverySequence` を採番する。frame の ingress の `sequence` とは共有しない。
- legacy `VideoRenderer` への最終配送 executor は main queue に統一する。現行で main queue なのは `render` / `onChange(size:)` だけであり (`Sora/VideoRenderer.swift:74-96`)、`VideoView` の `start()` / `stop()` / `clear()` (`Sora/VideoView.swift:145-234`) が main 以外から呼ばれる経路をなくす。この変更は利用者が観測できる契約変更であり、`CHANGES.md` と doc に記載する。
- `onAdded` / `onRemoved` は「配送先の renderer を event ごとに固定する」。`videoRenderer` の setter と `nil` 代入は、lock 区間で世代を進め、`pendingRendererDeliveries` に `.added(新しい renderer)` / `.removed(以前の renderer)` を追加してから owner queue へ投入する。pending は配送が完了するまで renderer とその時点の `MediaStream` を強参照する。世代一致の判定対象は `frame` / `size` / `switch` だけとし、`added` / `removed` は世代が進んでいても失わない。これにより、`onAdded` を受け取った renderer は必ず `onRemoved` を 1 回受け取る。
- `onAdded(from:)` / `onRemoved(from:)` の `MediaStream` 引数と `onDisconnect(from:)` の `MediaChannel?` 引数は非 Sendable であるため、`@Sendable` closure の payload に載せない。main queue 上の block は owner を強参照し、owner が配送要素として保持している `MediaStream` / `MediaChannel?` を main queue 上で取り出して渡す。配送要素から取り出した後に解放する。
- `frame` / `size` / `switch` は、main queue 上で「現在の世代と renderer」を同一 lock 区間で読み、世代が一致する場合だけ配送する。owner queue での判定だけに依存しない。
- `VideoRendererAdapter` は `setSize` / `renderFrame` を main queue へ直接渡さず owner へ渡す。adapter は owner を弱参照し、自分の世代を保持する。native track への `add(adapter)` は `.added` を owner へ投入した後、`remove(adapter)` は `.removed` を投入した後に行い、新 adapter の frame が `onAdded` より先に届かないようにする。既存の `VideoRendererFrameEvent` / `VideoRendererSizeEvent` は削除する。
- main queue 上で `VideoView.start()` の `DispatchQueue.main.async` を経由すると、`onAdded` の直後に配送された frame が `isRendering == false` で破棄される。`Sora/VideoView.swift` を変更対象に加え、main queue 上での呼び出しでは `isRendering` を同期で更新する。
- ingress の sequence は renderer frame へ伝播しない。frame ごとの対応は配送順で表し、診断には `RTCVideoFrame.timeStampNs` と `VideoFrame.timestamp` (`Sora/VideoFrame.swift:36-41`) を使う。renderer 経路の `StreamOwnedFrame` は `rendererDeliverySequence` を `sequence` として持つ。
- `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` は本 issue では executor を変更しない。`0136` が確定した「`setVideoHardMute(true)` の経路では `VideoHardMuteActor` の executor、それ以外は呼び出し元」を維持し、`0136` の executor 記録のうち `VideoRenderer.onSwitch` 側だけを本 issue が main queue へ変える。両者の executor が異なること、handler と renderer の相対順序を保証しないことを doc に明記する (`Sora/MediaStream.swift:15-23`、`Sora/MediaChannel.swift:1404-1414`、`CHANGES.md:63` は `onSwitchVideo` のみの記載のため維持する)。
- MainActor 前提の新しい renderer protocol、`@preconcurrency` の除去、非 UI renderer の custom queue は `0027` / `0060` で扱う。配送の順序は owner が決め、`0060` が追加する利用者の queue は最終配送先としてだけ使う (順序と drop の判断を利用者 queue へ委ねない)。本 issue は配送先を選択する公開 API を追加しない。
- `StreamFrameOwner` の `drainForTesting()` は `queue.sync {}` とする。テストの executor からのみ呼び、owner queue 自身の executor から呼ぶと自己デッドロックする (0104 の `drainSendVideoFrameQueue()` と同じ制約)。`lastAcceptedSequenceForTesting` は最後に受理した frame の `sequence`、`lastProcessedSequenceForTesting` は最後に `VideoFilter` を実行した frame の `sequence` を返す。
- `pendingRendererDeliveries` は配送が完了した要素から順に解放する。配送は owner queue と main queue の 2 段であるため、owner queue が停止した場合は pending と、それに強参照された renderer / `MediaStream` が解放されない。owner queue の処理は利用者 callback の完了に依存しないため、この保留は高々 1 バッチである。

### frame 破棄の判定

owner が frame を破棄する条件を次に固定する。

1. `videoFrame` が `nil` (`send(videoFrame: nil)`)。ingress では `StreamOwnedFrame` を作らないため、受理時だけ判定する。現行実装と同じく何もしない。
2. 解決済みの `RTCVideoSource` が `nil` (video track を持たない stream)。source は生成時に 1 回だけ解決するため、実行時の再確認は行わない。
3. ingress の未処理数が `maxPendingFrameCount` に達している。上限に達した場合は新しく到着した frame を破棄し、debug ログ (英語) を出し、破棄件数を internal なカウンタで数える。
4. owner が無効化されている (`terminate()` 済み)。受理時と実行時の両方で確認する。
5. `nativeStream` が解放済み、または video track が無い場合は 2 と同じ (source が `nil` になる) として扱う。

- `transportEpoch` による照合は行わない。redirect と切断では `PeerChannel` が全 stream を `terminate()` して `streams` を破棄し、新しい接続では新しい `BasicMediaStream` が生成されるため (`Sora/PeerChannel.swift:1691-1701, 1834-1837, 720-746, 2016-2057`)、生存中の owner に古い transport の frame が届く経路が無い。`0027` / `0122` が前提にしている「stream epoch」は本 issue では導入しない (「変更対象」で前提を更新する)。
- re-offer / re-answer では owner を無効化せず sequence 順の維持だけを保証する。
- `terminate()` は ingress と同一の lock 区間で `isInvalidated` を立て、owner queue を待たずに戻る。`invalidate(disconnectFrom:)` の引数として呼び出し元の executor で `peerChannel.mediaChannel` を読み、配送要素として保持する。owner queue は無効化以降、未処理の frame を filter にも `RTCVideoSource` にも渡さず、renderer の `frame` / `size` / `switch` も配送しない。`pendingRendererDeliveries` の `added` / `removed` は配送してから `onDisconnect` を 1 回配送する。`terminate()` は冪等とし、2 回目以降は `onDisconnect` を再配送しない。
- `terminate()` は `nativeChannel` の close より前に呼ばれる (`Sora/PeerChannel.swift:1691-1703, 1834-1853`) が、無効化以降は source へ配送しないため、close 後に source を呼ぶ経路を作らない。
- `terminate()` の `onDisconnect` は owner → main の非同期配送である。stream をまたぐ renderer callback の順序 (旧 stream の `onDisconnect` と新 stream の `onAdded`) は保証しないことを doc と `CHANGES.md` に書く。

### 公開 API の契約

- `send(videoFrame:)` の「ingress へ投入して戻る」契約、破棄条件、`nil` の扱い (何もしない)、画素データを配送完了まで書き換えない義務を doc に明記する。
- `nativeVideoSource` が `nil` の stream では現行と異なり filter が呼ばれなくなる。この挙動変更を `send` の doc と `CHANGES.md` に記載する。
- `videoFilter` / `videoRenderer` に `@Sendable` や actor 隔離を要求しない。実行 executor の契約を protocol の doc と `skills/sora-ios-sdk/SKILL.md` に記載する。
- 上限を超えた frame の破棄、`terminate()` 後の破棄、`terminate()` の冪等性を doc に記載する。

## スコープ外

- `videoEnabled` / `audioEnabled` の書き込みの直列化 (operation 単位の排他と、失敗時の復元の原子性) は `0163` で扱う。本 issue は renderer の `onSwitch` の配送順序だけを担い、`MediaStreamHandlers.onSwitchVideo` の executor と `0136` が `VideoHardMuteActor` の executor へ置いた書き込みは変更しない。
- `setVideoHardMute(true)` 失敗時のカメラ予約の扱い (`0159`) は変更しない。
- `SenderStreamBox` (`Sora/VideoMute.swift:22-28`) の置き換えは行わない。これは actor 境界へ `MediaStream` を渡すための箱であり、置き換えると `CameraStateOwner` の `WeakStream` / `compareAndSetStream` (`Sora/CameraStateOwner.swift:50-115`)、`CameraCaptureOwnership` / `VideoSourceCoordinator` の弱参照と同一性比較 (`Sora/CameraVideoCapturer.swift:36-59, 100-166, 326-366`)、`CameraVideoCapturer.startForSDK(senderStream:)` (`:1385-1447`) まで波及する。frame の ingress には必要ないため別 issue とする。
- 新しい Media Processors API と frame の drop 契約は `0057` で扱う。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。`StreamOwnedFrame` は internal に閉じ、`VideoFrame` の public case は変更しない。
- audio sink の executor 再設計は本 issue に含めない。
- `MediaStreamHandlers` の closure property の読み書き排他は、現時点でどの issue の対象でもない。本 issue では配送 executor だけを変更し、closure の排他は `0154` の対象に追加する (「変更対象」)。
- `CameraVideoCapturerHandlers` / `MediaChannelHandlers` / `WebSocketChannelHandlers` の closure 排他は `0154` で扱う。
- Thread Sanitizer による検証は `0119` の CI job が整った時点で補助的に行い、`0119` / `0151` が未完了の間は完了条件に含めない。

## 変更対象

- `Sora/StreamFrameOwner.swift` (新規): `StreamFrameOwner` / `StreamOwnedFrame` / `StreamRendererDelivery`、`dummyCapturer`
- `Sora/MediaStream.swift`: `BasicMediaStream` への owner の追加 (`init` の最後で初期化) と `streamOwner` の internal 化 (テストが `@testable import` で参照する)、`send(videoFrame:)` の ingress 投入への変更と doc の修正 (`nil` の扱い、画素データの義務、`nativeVideoSource` が `nil` のときの filter 非実行)、`videoFilter` の owner 委譲、`videoRenderer` setter の `.added` / `.removed` 投入への変更、`videoEnabled` / `audioEnabled` setter の `videoRenderer?.onSwitch` の owner 委譲、`terminate()` の無効化 (無効化時に読んだ `peerChannel.mediaChannel` を渡す) と doc、`dummyCapturer` の削除、`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の doc の更新、`videoRendererAdapterForTesting` (internal) の追加
- `Sora/VideoRenderer.swift`: `VideoRendererAdapter` の `setSize` / `renderFrame` を owner への投入に変更、owner の弱参照と世代の保持、`VideoRendererSizeEvent` / `VideoRendererFrameEvent` の削除、`VideoRenderer` protocol の callback の executor 契約を doc に追記
- `Sora/VideoView.swift`: main queue 上での `start()` / `clear()` の `isRendering` 更新を同期化 (main 統一による frame 取りこぼしの回避)
- `Sora/VideoCapturer.swift`: `VideoFilter.filter` の executor 契約と、複数 stream で共有した場合の利用者責任を doc に追記
- `Sora/CameraVideoCapturer.swift`: delegate の doc に「frame は `send` の ingress へ渡す」ことを追記。`onCapture` の doc に実行 executor と ingress との位置を追記 (処理は変更しない)
- `Sora/ScreenCapture.swift`: `processOwnedFrame` の doc と flight permit の説明を「ingress への投入で返却する」へ更新、`targetFPS` が上限であり上限破棄された frame も `markVideoFrameSent` の基準に残ることを doc に追記、`videoSampleBufferTransformer` の doc に ingress との位置を追記 (処理は変更しない)
- `Sora/MediaChannel.swift`: `setVideoHardMute` の doc を「handler は `VideoHardMuteActor` の executor、`VideoRenderer` は main queue」に更新 (処理は変更しない)
- `Sora/PeerChannel.swift`: `terminate()` 呼び出し箇所の doc に executor の無効化を追記 (処理は変更しない)
- `SoraTests/StreamFrameOwnerTests.swift` (新規): 直列化 / sequence / filter 実行順序 / 交換との競合 / 上限での破棄 / 無効化後の破棄 / renderer event の順序と `onAdded` → `onRemoved` の対
- `SoraTests/ScreenCaptureFrameGenerationTests.swift`: owner の drain を追加し、`VideoFilter` の到達回数の検査前に owner の処理完了を待つ
- `SoraTests/DummyVideoCapturer.swift`: `frameCount` の意味 (ingress へ投入した frame 数) を doc に追記
- `SoraTests/SendableConformanceTests.swift`: `StreamOwnedFrame` を `requireSendable` で追加する (実 frame を生成しない)
- `skills/sora-ios-sdk/SKILL.md`: 映像節に `VideoFilter` / renderer callback の executor 契約、`send` の配送契約、無効化後の破棄を追記
- `CHANGES.md`: `## develop` へ本 issue の `[UPDATE]` を追記 (renderer callback の executor が main queue に統一されること、`send` が配送完了を待たないこと、上限超過の frame が破棄されること、`nativeVideoSource` が `nil` の stream では filter が呼ばれないこと、`terminate()` が冪等で以降 frame を配送しないこと、stream をまたぐ renderer callback の順序を保証しないこと)
- `issues/0027-refactor-videorenderer-mainactor-migration.md`: 前提 (`:41`) と payload / 順序の方針 (`:56`) から epoch を削除し、現状の event box の記述を「`0105` が削除し、adapter は owner queue → main queue の配送になった」へ更新し、`VideoRendererAdapter` の native track からの除去 (本 issue が `0027` へ委譲する) を設計方針と完了条件に追記する
- `issues/0122-remove-legacy-video-renderer.md`: 設計方針の「sequence / epoch 付き」を「sequence 付き」へ直し、event box を前提にした記述を削除する
- `issues/0057-add-media-processors.md`: `## 方針` の後に `## 前提となる issue` を新設し、本 issue の ingress と processor 契約の責務境界、raw WebRTC 型を新しい公開 API に出さない方針 (`0070` と整合) を書く
- `issues/0060-add-videorenderer-custom-queue.md`: 順序は owner が決め、利用者 queue は最終配送先であることを追記し、「常にメインキュー」と `renderFrame(_ frame: RTCVideoFrame?)` の記述を現行の protocol に合わせる
- `issues/0110-add-sendable-event-api.md`: 前提となる issue を、frame event の順序保証 (`0105`) と有効フラグの直列化 (`0163`) に更新し、`0154` の対象列挙に `MediaStreamHandlers` を加える
- `issues/0154-refactor-handler-bag-exclusion.md`: タイトル・目的・現状・設計方針・完了条件に `MediaStreamHandlers` を加え、前提に「`0105` が closure 排他を本 issue へ委ねている」を追記する

## テスト方針

モックやスタブは使用しない。テスト用の `VideoFilter` / `VideoRenderer` 実装は実 protocol に対する観測用の実装とし、既存の `CountingVideoFilter` (`SoraTests/ScreenCaptureFrameGenerationTests.swift:71-89`) と同じ方針で作る。

### Simulator (CI の unit test) で実行する

`SoraTests/StreamFrameOwnerTests.swift` を新設する。`ScreenCaptureFrameGenerationTests.swift` の `private` ヘルパー (`ScreenCaptureTestGate` / `makeSenderStream` / `makeSenderStreamWithVideoTrack` / `makeSampleBuffer`) は再利用できないため、同種のヘルパーを次の名前でこのファイルに定義する。

- `RecordingVideoFilter`: 呼び出し順と、同時実行の有無 (実行中フラグ) を記録する実 `VideoFilter`
- `SynchronousFilterGate`: `VideoFilter.filter` が同期メソッドであるため、actor ではなく `DispatchSemaphore` で filter を停止・再開するゲート
- `RecordingVideoRenderer`: 7 種類の callback の順序を記録する実 `VideoRenderer`
- `makeSenderStreamWithVideoTrack(mediaChannel:)`: 既存テストと同じ構成を再定義する
- `ownerForTesting(_ stream: MediaStream) -> StreamFrameOwner`: `BasicMediaStream` へ downcast して owner を取得する

- 公開 `send(videoFrame:)` を複数スレッドから並行に呼び、`RecordingVideoFilter` で「同一 stream で同時に 2 つの frame が filter に入らないこと」と「filter へ到達した順序が `lastProcessedSequenceForTesting` の昇順と一致すること」を検査する。
- filter の交換と frame 入力を競合させ、各 frame が使った filter の instance を記録して、frame ごとに filter が一意に決まること (同じ frame が 2 つの filter を通らないこと) を検査する。`SynchronousFilterGate` で「停止 → 投入 → 交換 → 再開」と「交換 → 投入 → 再開」の 2 ケースを決定的に実行する。
- ingress の上限: `SynchronousFilterGate` で filter を停止し、`maxPendingFrameCount` を超える frame を投入して、受理された frame だけが filter へ到達し、`lastAcceptedSequenceForTesting` と破棄件数が期待どおりであることを検査する。
- `terminate()` の後に投入した frame が filter へ到達しないこと、`terminate()` を 2 回呼んでも `onDisconnect` が 1 回であること、`terminate()` 以降に `RTCVideoSource` へ配送されないことを検査する。
- renderer の順序: `RecordingVideoRenderer` で `onAdded` / `render` / `onChange(size:)` / `onSwitch` / `onRemoved` / `onDisconnect` の呼び出し順序を記録し、owner の順序と一致することを `XCTestExpectation` で検査する。frame と size は `makeSenderStreamWithVideoTrack` が作る sender stream へ公開 `send(videoFrame:)` で実 frame を流し、`nativeVideoTrack` の renderer 経由で観測する (実カメラは不要)。main queue の配送は expectation で待つ。
- `videoRenderer` の交換と `nil` 代入で、`onAdded` を受け取った renderer が必ず `onRemoved` を 1 回受け取ること、交換前の adapter から届いた frame / size が新しい renderer へ配送されないことを、`videoRendererAdapterForTesting` を保持して検査する。
- `videoFilter` / `videoRenderer` の get / set を並行実行し、実行が完了して値が一意に定まること (data race が無いこと) を検査する。
- 破棄条件を個別に検査する。`nil` frame は filter が呼ばれないこと、video track を持たない stream (`makeSenderStream`) では source が `nil` のため filter が呼ばれないことを確認する。
- `SoraTests/ScreenCaptureFrameGenerationTests.swift` は owner の drain を挟んだうえで、既存の期待値 (filter 到達回数 / permit の会計 / 間引きと drop の条件) を維持する。
- `DummyVideoCapturer` を使う E2E (`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `RpcE2ETests`) は待ち方を変更せずに成功することを確認する。`frameCount` の `> 0` の比較 (4 箇所) は意味が「ingress へ投入した frame 数」に変わっても成立する。
- camera 経路と screen capture 経路は「3 入力元が同じ `send` を通ること」をコードで確認する。`CameraVideoCapturerDelegate` は private であり、Simulator に実カメラと実 ReplayKit が無いため、入力元ごとの並行入力は自動テストの対象にしない。
- テストには、入力元ごとの event sequence と期待する破棄条件を日本語コメントで明記する。

### 既存テストへの影響

- `SoraTests/ScreenCaptureFrameGenerationTests.swift` の `VideoFilter` 到達回数の assert は `send` の同期性に依存する。owner の drain seam を追加して待つ。
- `Sora/ScreenCapture.swift` の flight permit は `send` から戻った時点で返却される。filter と source への配送の実質的な上限制約は owner の `maxPendingFrameCount` になり、`markVideoFrameSent` が `send` の前に走るため、上限で破棄された frame も `targetFPS` の間引き基準に残る。`targetFPS` は上限であり保証値ではない。
- `SoraTests/SendableConformanceTests.swift` に `StreamOwnedFrame` を `requireSendable` で追加する。

### テストで再現できない防御経路

次の経路は決定的に再現する手段が無いため、テスト対象に含めず、コードで確認する。

- `RTCVideoSource` が owner queue からの配送を受け付けない場合の fallback (`CameraQueueExecutor` 経由)。実カメラとそれに依存する vendor の挙動が必要であり、Simulator では再現できない。実機確認で判定する。
- owner queue が停止した状態で `terminate()` が呼ばれ、`pendingRendererDeliveries` が解放されない経路。owner queue の停止を外部から作る手段が無い。
- `nativeStream` が video track を持たない場合の source の `nil` は再現できる (`makeSenderStream`) が、`nativeStream` が途中で解放される経路は再現できない。破棄条件 2 と 5 は同じ判定に統合されているため、条件 2 のテストで代表させる。

### 実機で手動確認する (CI では未検証として区別する)

実機確認は `sora-ios-sdk-samples` のサンプルアプリで行う (SwiftPM のテストは tool-hosted のため実機で実行できない)。debug ログを有効化して破棄の発生を観測する。

- 実カメラの frame が owner queue 経由で `RTCVideoSource` へ配送され、送信と `VideoView` の preview が継続すること。frame が破棄されて送信が止まらないこと。
- 実 ReplayKit の画面キャプチャ送信が継続すること。
- カメラと画面キャプチャを切り替えても filter の順序が崩れないこと。
- fallback (`CameraQueueExecutor` 経由) を採る場合は、その構成でのみ未検証項目として区別する。
- Thread Sanitizer は `0119` の CI job が整うまで完了条件に含めない。

## 完了条件

- `BasicMediaStream` ごとに frame 処理の owner が 1 つ存在し、frame の受理、`VideoFilter` の実行、`RTCVideoSource.capturer(_:didCapture:)` の呼び出し、renderer event の配送が同じ owner queue 上で直列に行われること。
- camera、screen capture、public send の 3 入力元が同じ ingress を経由すること (コードで確認する)。受理順に `sequence` が採番され、採番と owner queue への投入が同一 lock 区間で行われること (テストで検証する)。
- legacy `VideoFilter` が owner queue 上でだけ実行され、同一 stream で同時に 2 つの frame が filter に入らず、filter の交換と frame 入力が競合しても各 frame が使う filter が一意に決まること (テストで検証する)。
- ingress の未処理 frame の上限が実装され、超過した frame が `RTCVideoSource` と renderer へ配送されないこと (テストで検証する)。
- `terminate()` 以降に到着した frame と renderer の frame / size / switch event が配送されず、`terminate()` が冪等で、`onDisconnect` が 1 回だけ配送されること (テストで検証する)。
- `transportEpoch` を frame の破棄判定に使っていないこと。
- 本 issue で新設した `@unchecked Sendable` 型が `StreamFrameOwner` と `StreamOwnedFrame` の 2 つだけで、それぞれの根拠が型 doc に書かれていること。`StreamOwnedFrame` の根拠が「SDK が `RTCVideoFrame` を書き換えないこと」と「同時に参照を保持する executor が常に 1 つであること」に限定され、retain をヘッダ保証として書いていないこと。`SenderStreamBox` を置き換えていないこと。
- 公開 protocol `MediaStream` に requirement を追加していないこと。`VideoRendererAdapter` の既存 event box が削除されていること。
- legacy `VideoRenderer` の 7 種類の callback (`onAdded` / `render` / `onChange(size:)` / `onSwitch(video:)` / `onSwitch(audio:)` / `onRemoved` / `onDisconnect`) が owner の順序で main queue へ FIFO 配送されること。`onAdded` を受け取った renderer が必ず `onRemoved` を 1 回受け取り、交換前の adapter から届いた frame / size が配送されないこと (テストで検証する)。
- `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の executor が現行のまま (`VideoHardMuteActor` または呼び出し元) であり、renderer の `onSwitch` とは executor が異なることが doc に書かれていること。
- `send(videoFrame:)` の doc に「ingress へ投入して戻る」契約、破棄条件、`nil` の扱い (何もしない)、画素データを配送完了まで書き換えない義務が書かれ、doc と実装が一致していること。
- `CameraVideoCapturerHandlers.onCapture` と `ScreenCaptureSettings.videoSampleBufferTransformer` の実行 executor と、ingress に対する位置が doc に書かれていること。
- `skills/sora-ios-sdk/SKILL.md` の映像節に `VideoFilter` / renderer callback の executor 契約、`send` の配送契約、無効化後の破棄が書かれていること。
- `CHANGES.md` の `## develop` に本 issue の `[UPDATE]` が追加されていること。
- `SoraTests/StreamFrameOwnerTests.swift` の追加テストと、owner の drain を追加した `SoraTests/ScreenCaptureFrameGenerationTests.swift` を含む既存テストがすべて成功すること。
- 実カメラ経由の配送は実機で確認され、未検証項目として区別されていること。

### 検証手段

- 直列化 / sequence / 交換の境界 / 上限 / 無効化 / renderer 順序: `SoraTests/StreamFrameOwnerTests.swift` の各テストで検査する (「Simulator (CI の unit test) で実行する」の項目と 1 対 1 に対応する)。
- 入力元の統一: `grep -rn "send(videoFrame:" Sora/` で、frame を投入する経路が `Sora/MediaStream.swift` の定義と、`Sora/CameraVideoCapturer.swift` の delegate と `Sora/ScreenCapture.swift` の送信箇所だけであることを確認する。
- owner の一意性: `grep -n "StreamFrameOwner(" Sora/MediaStream.swift` が 1 件であり、他のソースファイルに owner の生成が無いことを確認する (`grep -rn "StreamFrameOwner(" Sora/` の結果が `Sora/MediaStream.swift` の 1 箇所だけ)。
- `@unchecked Sendable` の限定: `grep -rn "class StreamFrameOwner: @unchecked Sendable\|struct StreamOwnedFrame: @unchecked Sendable" Sora/` が 2 件であること、および `grep -rn "@unchecked Sendable" Sora/StreamFrameOwner.swift Sora/MediaStream.swift Sora/VideoRenderer.swift` の結果が型宣言 2 行と型 doc の説明文だけで、新しい型の宣言が増えていないことを確認する。`grep -n "VideoRendererFrameEvent\|VideoRendererSizeEvent" Sora/` が 0 件であることも確認する。
- 公開 protocol の互換: `git diff -- Sora/MediaStream.swift` に `MediaStream` protocol の requirement の追加が無いことを確認する。
- `transportEpoch` を frame 破棄に使っていないこと: `grep -n "transportEpoch\|dataChannelGeneration" Sora/MediaStream.swift Sora/StreamFrameOwner.swift` が 0 件であることを確認する。
- ビルド: `xcodebuild build-for-testing -scheme Sora-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6` (`.github/workflows/ci.yml:53-62`) が成功し、変更したファイルに新しい `#SendableClosureCaptures` warning が出ないことを、`xcodebuild ... 2>&1 | grep -c SendableClosureCaptures` の結果で確認する (CI は warnings-as-errors ではない)。
- テスト: 同じ `xcodebuild test-without-building` の実行 (`.github/workflows/ci.yml:83-89`) で全テストが成功すること。
- format / lint: `make fmt-lint` と `make lint` が違反 0 であること。
- 公開契約の記載: `git diff` で `Sora/MediaStream.swift`、`Sora/VideoCapturer.swift`、`Sora/VideoRenderer.swift`、`Sora/VideoView.swift`、`Sora/CameraVideoCapturer.swift`、`Sora/ScreenCapture.swift`、`Sora/MediaChannel.swift`、`skills/sora-ios-sdk/SKILL.md`、`CHANGES.md` の doc と記載を確認する。
- `SenderStreamBox` を変更していないこと: `git diff -- Sora/VideoMute.swift` に `SenderStreamBox` の変更が無いことを確認する。
- 実機確認: 「実機で手動確認する」の各項目をサンプルアプリで実施し、未検証項目を区別する。

## 解決方法
