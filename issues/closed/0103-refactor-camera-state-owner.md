# CameraVideoCapturer のカメラ状態の所有者を単一化する

- Created: 2026-08-27
- Completed: 2026-09-16
- Priority: Medium
- Branch: feature/refactor-camera-state-owner
- Polished: 2026-09-16

## 優先度根拠

- `CameraVideoCapturer` は class 全体が `@unchecked Sendable` で、`current` / `handlers` / `isFlipping` が `nonisolated(unsafe)` のまま残っている。Swift 6 の isolation が型でも実行経路でも保証されていない。
- 公開 API の変更を伴わない内部構造の整理であり、`0116` の前提になるため Medium とする。

## 目的

`CameraVideoCapturer` のカメラ状態の所有者を process-wide に 1 つだけ存在する owner (`CameraStateOwner`) へ集約し、`@unchecked Sendable` と `nonisolated(unsafe)` を除去する refactor とする。カメラの観測挙動と公開 API は変えない。ただし `CameraVideoCapturer.stream` は owner が弱参照で保持するため、利用者が `MediaStream` を保持しない場合は解放される (観測挙動の変更として `CHANGES.md` に記載する)。

カメラは「プロセスに 1 つしかない物理資源」と「その資源をどの接続が所有するか」の二層構造になっている。本 issue は二層を分けたまま物理資源側の所有者を 1 つにする。接続所有の識別は引き続き `VideoHardMuteLease` / `VideoSourceCoordinator.Reservation` / `CameraCaptureOwnership` が担い、owner の状態機械には持ち込まない。物理資源側の instance は `CameraCapturerID` で識別し、owner は接続ごとに生成しない。

owner の状態機械 (`CameraState` / `CameraEvent`) と effect は Sendable な値だけで構成する。non-Sendable な `AVCaptureDevice` / `AVCaptureDevice.Format` / `RTCCameraVideoCapturer` / `MediaStream` は owner の resource テーブルまたは capturer instance の lock 付き storage が保持し、reducer の入出力には含めない。

対象は `CameraVideoCapturer` 内部の mutable state と、それを読み書きする公開 API (`start` / `stop` / `restart` / `change` / `flip`) および SDK 内部 API (`*ForSDK`) である。`CameraVideoCaptureCoordinator` / `VideoSourceCoordinator` / `CameraCaptureOwnership` / `VideoHardMuteLease` / `SerializedAsyncOperationQueue` は 2026.3.0 の実装を正とし、再設計しない。

## 現状

`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturer` は class 全体が `@unchecked Sendable` で、状態は static と instance に分かれている。

static state:

- `front` / `back`: `public static let CameraVideoCapturer?` の固定 instance
- `current`: `public private(set) nonisolated(unsafe) static var`
- `isFlipping`: `nonisolated(unsafe) private static var`
- `handlers`: `public nonisolated(unsafe) static var`

instance state:

- `stream`: `public var`。利用者が直接代入する
- `isRunning` / `device` (ともに `public var` 系) / `frameRate` / `format`
- `native` / `nativeDelegate` / `captureSession` (545 行) / `position` (768 行)

`front` / `back` 以外にも `public init(device:)` で任意個の instance が生成される (`Sora/PeerChannel.swift`、`Sora/VideoMute.swift`)。536 行の `TODO(zztkm)` (共有状態を actor へ移す) が本 issue の解消対象である。削除した。763 行の handler 側 `TODO(zztkm)` も本 issue で削除した (handler の `@Sendable` 化は `0110` が扱う)。

### 書き手と読み手

- 書き手: `startUncoordinated` / `stopUncoordinated` / `flipUncoordinated` / `changeUncoordinated` (camera queue 上)。
- 読み手: `CameraVideoCapturerDelegate.capturer(_:didCapture:)` (libwebrtc の capture callback)、`PeerChannel.initializeCameraVideoCapture` / `terminateSenderStream`、`MediaChannel.setVideoHardMute` / `isCameraVideoCaptureRunning`。
- 公開 API は任意の executor から呼べる。`PeerChannel` と `stop` / `restart` は「current と一致しない capturer の running」を検出して quarantine し、`flip` / `start` / `restart` / `change` は `hasScreenReservation` で画面共有との交差を拒否する。
- `PeerChannel.initializeCameraVideoCapture` / `terminateSenderStream` は状態の書き手でもあり、「予約確定 → 直列化 → 所有情報設定 → start / stop」の順序を owner 導入後も維持する。

### 直列化と executor

- 外側: `CameraVideoCaptureCoordinator` の `SerializedAsyncOperationQueue` (`enqueue` / `perform`)。公開 API と SDK 内部 API はここを通る。
- 内側: `SoraDispatcher.async(on: .camera)` (`Sora/SoraDispatcher.swift` が `RTCDispatcher.dispatchAsync(on: .typeCaptureSession)` へ写像する)。native 操作と delegate callback は libwebrtc の capture session queue 上で動く。

`SoraDispatcher` の production 利用は `Sora/CameraVideoCapturer.swift` の 6 箇所 (644 / 1079 / 1093 / 1115 / 1130 / 1153 行) のみである。

### 本 issue の動機となるコンパイル制約

`SerializedAsyncOperationQueue` の `enqueue` / `perform` は `operation: @escaping @Sendable () async -> T` を取り、戻り値型に `T: Sendable` を要求する。capturer を capture・返却している次の 8 箇所が `CameraVideoCapturer: Sendable` の要件源である。

- `CameraVideoCapturer.swift` 622 (flip) / 814 (start) / 892 (stop) / 929 (restart) / 1012 (change)
- `Sora/PeerChannel.swift` 966
- `Sora/VideoMute.swift` の `stopCameraVideoCapture` / `restartCameraVideoCapture`

`perform<T: Sendable>` の戻り値型は `Sora/VideoMute.swift` の `currentCameraVideoCapturer` / `currentCameraVideoCapturerAndCompleteStart` / `startCameraVideoCapture` でも capturer を返す。`VideoHardMuteActor` の保存状態も `CameraVideoCapturer` を型付きで保持していた (現在は `CameraCapturerID`)。

### stream の書き込み箇所

`stream` の書き込みは 7 箇所ある。`flipUncoordinated` の 716 (退避は 715) と失敗時の rollback 725 / 736、`startForSDK` の 1097 (設定) / 1101 (rollback、退避は 1095)、`restartForSDK` の 1133 (設定) / 1137 (rollback、退避は 1131)。716 は dispatch closure 直下、725 / 736 は stop / start の完了 callback 内で実行される。

unchecked box は `CameraCaptureFormatBox` (non-Sendable な `AVCaptureDevice.Format`)、`CameraOperationCompletionBox` (非 `@Sendable` closure)、`SenderStreamBox` (non-Sendable な `MediaStream`) の 3 つである。

## 前提となる issue

- `0136` (hard mute の rollback) は完了済み。`0142` (出力サイズと contain / cover) / `0143` (外部カメラ) は `Sora/CameraVideoCapturer.swift` / `Sora/VideoMute.swift` の同一経路を変更するが、0103 を先行させる方針としたため、本 issue の完了時点では未着手である。
- `0028` (open): `VideoHardMuteActor` の保存状態のクリア意味論を扱う。`0028` を本 issue の前提にはしない。未完了でも `StoredCapturer.capturer` の `CameraCapturerID` 化は行い、クリア条件そのものは変更しない。
- `0051` (open): flip の目標解像度維持を扱う。先に完了した場合は `targetResolution` の挙動を owner の format / frame rate state へ引き継ぎ、未完了の場合は現行の flip の挙動を維持する。前提にはしない。
- `0098` (完了): `0098` が「`0103` の owner への集約で解決する」と記録した `PeerChannel` の第 3 経路を本 issue で owner の command 経由にし、既存の lease / 予約 / 所有情報による保証の対象にする (混線防止の可否判定そのものは変えない)。
- `0099` (完了): flip の stream 設定順と rollback を修正する。`isFlipping` は削除し、owner の state (`phase = .flipping` と `isFlipping` フラグ) へ移す。`0099` が「`0103` の owner への移植時に実装する」と先送りした start 失敗後の完全復旧は、観測挙動を変えるバグ修正のため本 issue には含めず、新規の bug issue として起票する。
- `0102` (完了): 接続設定を immutable な Sendable snapshot へ変換する。`MediaChannel` / `PeerChannel` の init が受け取る `videoHardMuteLease` / `cameraCaptureCoordinator` / `cameraCaptureOwnership` / `videoSourceCoordinator` を経由する。

## 後続 issue

- `0116` (open): `SoraDispatcher` を非推奨にする。本 issue の完了後に着手する。`0117` は `0116` 経由の間接依存とする。

## 設計方針

### CameraStateOwner

- process-wide に 1 つだけ存在する internal な owner (`CameraStateOwner`) を導入する。`CameraVideoCaptureCoordinator.shared` と同じ寿命とし、`MediaChannel` / `PeerChannel` は owner を保持しない。
- owner は `0100` (完了) の `ConnectionStateOwner` / `ConnectionSnapshotStorage` (`Sora/ConnectionLifecycle.swift`) と同じ方式とする。serial `DispatchQueue` でイベントを直列化し、`NSLock` で保護した immutable snapshot storage を同期 getter が読む。actor を採用すると `current` / `isRunning` / `stream` の同期 getter が維持できず、公開 API の source compatibility を壊すため採用しない。
- `CameraState` の mutate は owner の serial queue 上で行う (`handle(_:)` / `nextGeneration()` / `release(id:)` の 3 経路のみ)。command は `CameraVideoCaptureCoordinator.perform` から owner へ event を渡して state を直接触らない。owner の直列化は coordinator の注入に依存せず、owner は coordinator を参照しない。
- **初期化順**: owner の `init` では `CameraVideoCapturer` を生成しない。`front` / `back` は owner の強参照ストレージへの初回アクセス時に遅延生成する。生成した instance は自身で ID を採番し `register` で owner に登録する。同時アクセスでは保持の可否だけを storage の同一 lock 区間で判定し、負けた instance は保持せず先に保持された instance を返すことで、同じ position に 1 つの instance だけが存在することを保証する (生成中の AVFoundation 呼び出しを lock 内に持ち込まないため、生成は lock の外で行う)。これにより `CameraStateOwner.shared` の初期化中に `CameraVideoCapturer.init` が owner を再入参照しない。
- **ID 採番**: `CameraVideoCapturer` は `let id = CameraCapturerID()` を自身で採番し、`owner.register(id:instance:)` に渡す (owner は採番しない)。`init` の全 stored property を初期化した後に登録する。owner の instance テーブルは弱参照とし、ID → instance 解決専用とする。
- **instance の生存**: owner は active capturer と `front` / `back` を専用の強参照ストレージに保持する。加えて `VideoHardMuteActor` が capturer を ID のみで保持している間は `owner.pin(id:instance:)` で強参照を保つ。これにより `PeerChannel` / `VideoMute` の `@unknown default` で生成した instance が、ハードミュート解除の restart まで解放されない。保存状態の破棄と同時に `owner.unpin(id:)` で解除する。
- owner は 2 つの層を持つ。(1) Sendable な値だけの状態機械 (`CameraState`)、(2) non-Sendable な実資源 (`AVCaptureDevice.Format` / `MediaStream`) を `CameraCapturerID` ごとに保持する resource テーブル。resource テーブルの読み取りは `NSLock` 保護で任意スレッドから行い、libwebrtc の capture session queue 制約は native 呼び出しと Format の差し替えにのみ課す。
- `CameraCapturerID` は `UUID` を包む `Hashable` / `Sendable` な値型とする。format は `AVCaptureDevice.Format` のまま resource テーブルが `CameraCapturerID` ごとに保持し、`formatID` のような間接 ID は導入しない (`format` の読み手は capturer instance だけであり、ID を挟む理由がないため)。

#### 状態機械の型

- `CameraState`: `activeCapturerID: CameraCapturerID?`、`phase: CameraPhase` (`idle` / `starting` / `running` / `stopping` / `flipping` / `quarantined`)、`frameRates: [CameraCapturerID: Int]`、`runningCapturers: Set<CameraCapturerID>`、`isFlipping: Bool`、`operationGeneration: UInt64`。`stream` の値は resource テーブルが同一 lock 下で保持し、state には含めない (`CameraState` を Sendable に保つため)。
- `CameraEvent` の payload は `CameraCapturerID` / `UInt64` / `Int` / `Bool` などの値トークンに限定し、`VideoHardMuteLease` / `CameraCaptureOwnership` などの参照型を含めない。接続所有の識別は event に持ち込まない。
  - `.startRequested(id:generation:)` / `.formatResolved(id:frameRate:generation:)` / `.startCompleted(id:generation:success:)` / `.stopRequested(id:generation:)` / `.stopCompleted(id:generation:)` / `.restartRequested(id:generation:)` / `.restartCompleted(id:generation:success:)` / `.changeRequested(id:generation:)` / `.changeCompleted(id:generation:success:)` / `.flipRequested(sourceID:targetID:generation:)` / `.flipCompleted(sourceID:targetID:generation:success:)` / `.quarantined` / `.quarantineCleared` / `.capturerReleased(id:)`
- flip の切り替え先は command が request 前に解決して `targetID` として渡す。reducer は `targetID` で `activeCapturerID` と `runningCapturers` を移す。
- `activeCapturerID` は native start の成功時に設定し、native stop の完了時に解除する。`CameraVideoCapturer.current` はこの値だけを真実として instance テーブルで解決する。`runningCapturers` は `isRunning` の真実であり、内部 stop の完了までは維持する。
- `.formatResolved` が `frameRates` を更新する唯一の event であり、native start が成功した時点で渡す。`format` は同じ時点で resource テーブルへ同期で書く。失敗時はどちらも更新しない (要求値が残らないようにする)。
- `.stopCompleted` は success を取らない。`RTCCameraVideoCapturer.stopCapture` は失敗を通知しないため、停止完了は常に成功として扱い、停止失敗による隔離は行わない (現行と同じ観測結果)。
- restart / change / flip の内部 stop も `.stopCompleted` として reducer へ通し、内部 stop が完了した時点で `current` / `isRunning` が解除されるようにする (単体の stop と同じ観測結果)。start の完了は `.restartCompleted` / `.changeCompleted` / `.flipCompleted` で返し、成功時に `activeCapturerID` と `runningCapturers` を確定する。
- `.quarantined` は phase を `.quarantined` にし、operation generation を進めて `isFlipping` を解除する。これにより隔離前に開始された command の遅延 callback が隔離を解除しない。
- `CameraEffect` は Sendable な値のみで構成し、owner が `handle` の中で実行する。現在は `.publishSnapshot` のみである (`ConnectionEffect` と同じ。native の開始 / 停止は `CameraVideoCapturer` が直接実行する)。completion と `handlers.onStart` / `onStop` は実行側が自分の入力と対応付けて owner の critical section 外で実行する。
- `CameraStateReducer.reduce(state:event:) -> (CameraState, [CameraEffect])` を純粋関数として定義する。
- restart / change / flip は 1 つの複合 command として扱い、内部 stop の完了と start の完了をそれぞれ event として返す。途中失敗時は `.idle` へ戻して `runningCapturers` から外す。この規則を reducer の遷移として定義する。

#### generation / re-entrance / completion

- operation generation は「どの command の callback か」を判定し、`VideoSourceCoordinator` の予約世代は「その送信元予約がまだ有効か」を判定する。callback 復帰時は両方を確認し、owner の generation が不一致なら予約確定も行わない。
- re-entrance は generation とは別に、owner の state が持つ `isFlipping` で判定する。実行中の flip に対する 2 回目の flip は `SoraError.cameraError(reason: "camera flip is already in progress")` で拒否する。`isFlipping` は `.flipCompleted` と `.quarantined` で解除する (完了 callback を取りこぼしても flip が恒久的に拒否されないようにする)。
- completion の呼び出し回数は現行どおり 1 回から増減させない。stale callback の破棄は operation generation で行う。
- quarantine の真実は owner の phase に置く。`CameraVideoCaptureCoordinator` は owner を保持し (`init` で注入可能とし、テストはテストローカルの owner を使う)、`isAvailable` は owner の snapshot を pull して判定する。停止成功による解除は「隔離した capturer ID の照合」と「解除」を同一 lock 区間で行い、clear が成立した場合だけ owner へ `.quarantineCleared` を送る。`CameraVideoCapturer` への型付き参照を coordinator から除去する。画面共有の予約 (`hasScreenReservation`) は owner の外の guard として維持し、command 開始時に確認する。

### executor と native 操作

- owner の command 直列化は `CameraVideoCaptureCoordinator` の `SerializedAsyncOperationQueue` が担う。隔離の判定は command の開始時に行う。
- native 操作 (`RTCCameraVideoCapturer.startCapture` / `stopCapture` / delegate) は libwebrtc の capture session queue 上でのみ実行する。`Sora/CameraVideoCapturer.swift` 内に internal な camera queue adapter (`CameraQueueExecutor`) を 1 つ置き、`RTCDispatcher.dispatchAsync(on: .typeCaptureSession)` をこの 1 箇所に閉じ込める。command は adapter 経由で native を呼び、`SoraDispatcher` への参照を本ファイルから除去する。`currentForSDK()` は owner の同期 snapshot getter に置き換えて削除する。
- `RTCCameraVideoCapturer` が frame callback を発火する executor を upstream libwebrtc の `RTCCameraVideoCapturer.m` または `WebRTC.xcframework` の header で確認し、adapter の不変条件 (native start / stop と `AVCaptureDevice` の読み書きは capture session queue 上でのみ行い、同期 getter は owner または lock 付き storage だけを読む) を `CameraVideoCapturer` の型 doc に日本語で記載する。upstream の実装を確認できない場合は現行どおり capture session queue 上で callback が発火する前提を型 doc に明記する。
- capturer を `enqueue` / `perform` の `@Sendable` closure へ capture・返却している経路は、`CameraVideoCapturer: Sendable` の準拠によりそのまま扱えるようにする (ID への置換は行わない)。

### static state と公開 API

- `current` は `public static var current: CameraVideoCapturer? { get }` の get-only computed property とし、owner の snapshot (`activeCapturerID`) を instance テーブルで解決した instance を返す。内部書き込みは owner の強参照ストレージへの publish に一本化するため setter は設けない。get-only のため外部からは従来どおり読み取り専用で、ソース互換を維持する。
- `handlers` は lock で保護した storage から同一インスタンスを返す get / set 付き computed property とする。`public static var` のシグネチャと `CameraVideoCapturer.handlers.onCapture = ...` の in-place 変更を維持する。`CameraVideoCapturer.handlers = ...` の代入は storage の差し替えとして受け付ける。`CameraVideoCapturerHandlers` の closure property 自体の排他は本 issue では行わず、`0154` の対象に加えて行う。
- `device` は lock 付きの private な `@unchecked Sendable` box (`CameraDeviceStorage`) に保持し、`native` / `delegate` / `captureSession` は init で確定して以後差し替えない private な storage (`CameraNativeStorage`) に保持する。`handlers` は型全体で共有する private な storage (`CameraHandlersStorage`) が保持する。`device` の getter / setter と `position`、`handlers` の get / set は lock 下で同期で読み書きし、`captureSession` は不変値をそのまま返す。いずれも owner の queue を同期 wait しない。owner の command は command 開始時 (capture session queue 上) に box から device を読む。box の安全性の根拠を型 doc に記載する。
- `front` / `back` は `public static var CameraVideoCapturer?` の computed property とし、owner の `CameraStrongStorage` が position ごとに強参照で保持する instance を返す (固定 ID は用いない)。computed 化の根拠は「position → instance の解決経路を owner に一本化するため」である。読み取り専用の利用に対してソース互換である。
- `stream` は owner の publish 対象から外し、getter / setter / owner の参照直前読み出しがすべて同一の lock 付き resource テーブルを読み書きする。値の更新と読み出しを同じ lock 下で行い、所有者の照合は世代ではなく同じ lock 下での実 `MediaStream` の同一性で行う。`stream` の setter は `(CameraCapturerID, MediaStream?)` を同期で書く。owner の command は自分が対象とする `CameraCapturerID` の entry を参照直前に読み直す。これにより `flip` の command 内部で行う `flip.stream = capturer.stream` (716 行) の代入が同じ command 内の start に反映される。外部の setter による割り込みは次の参照から反映され、進行中の command を無効化しない。command が失敗して rollback する場合 (725 / 736 / 1101 / 1137 行) は、command が最後に storage へ書いた値が現在も残っている場合だけ書き戻す (compare-and-swap 相当)。利用者が command 実行中に代入していた場合は利用者の値を保持する。setter から owner の queue を `sync` しない (capture session queue 上からの代入で deadlock するため)。
- 既存の同期 / callback ベース公開 API は compatibility wrapper として維持する。公開 API は lease を持たないため、owner の command として直列化と operation generation の対象にするが、接続 lease のチェックは課さない。
- 新しい async API や `@Sendable` handler の公開は `0110` で扱う。本 issue で既存利用者へ新しい isolation 制約を強制しない。

### WebRTC / AVFoundation 境界

- `RTCCameraVideoCapturer` と delegate は adapter が指定する libwebrtc の capture session queue 上でのみ操作する。
- delegate callback では frame と capturer identity を取得し、`0105` が ordered frame ingress を導入済みならそこへ渡す。未導入なら現行どおり `MediaStream.send(videoFrame:)` へ渡す。
- raw capturer を actor 間で `@unchecked Sendable` box に入れて受け渡さない。`CameraCaptureFormatBox` は owner が format を解決する effect の引数としてのみ使い、state / event には含めない。`SenderStreamBox` は `0105` の完了まで維持する。

### callback

- completion と利用者 handler は camera state を確定してから owner の critical section 外で呼ぶ。
- callback から別のカメラ操作が再入しても deadlock しないようにする。

## スコープ外

- `CameraVideoCaptureCoordinator` / `VideoSourceCoordinator` / `CameraCaptureOwnership` の設計変更 (capturer identity 化と quarantine の pull 化を除く)。
- `VideoHardMuteActor` の保存状態のクリア意味論は `0028`、`setVideoHardMute(true)` 失敗時の `videoEnabled` 復元は `0136` で扱う。`0136` が確定した復元挙動の回帰検証は本 issue のテスト方針で行う。
- flip の start 失敗後の完全復旧 (元 capturer の再起動) は、観測挙動を変えるバグ修正として新規 issue で扱う。
- stream への frame 配送と `VideoFilter` 実行の ordered executor は `0105` で扱う。
- 公開 handler の `@Sendable` / AsyncStream 化と `CameraVideoCapturerHandlers` の排他は `0110` / `0154` で扱う。
- 公開 `SoraDispatcher` の非推奨化は `0116`、削除は `0117` で扱う。
- `CameraSettings` の出力サイズ / contain / cover は `0142`、外部カメラは `0143` で扱う。
- 画面共有側の状態所有は `0104`、MainActor renderer API は `0027`、Media Processors の公開 API は `0057` で扱う。
- raw WebRTC 型を公開 API から除去する作業は `0070` と整合させる。

## 変更対象

- `Sora/CameraState.swift` (新規): `CameraCapturerID` / `CameraPhase` / `CameraState` / `CameraEvent` / `CameraEffect` / `CameraStateReducer`
- `Sora/CameraStateOwner.swift` (新規): `CameraStateOwner` / `CameraSnapshotStorage` / `CameraResourceTable` / `CameraInstanceTable` / `CameraStrongStorage` (instance の pin を含む)
- `Sora/CameraVideoCapturer.swift`: owner の導入、`nonisolated(unsafe)` の除去、`CameraQueueExecutor` (camera queue adapter、新規)、`CameraHandlersStorage` / `CameraDeviceStorage` / `CameraNativeStorage`、`stream` / `device` / `current` / `handlers` / `front` / `back` / `isRunning` / `format` / `frameRate` の accessor、`currentForSDK()` の削除、handler 側 `TODO(zztkm)` の削除、`CameraVideoCaptureCoordinator` への owner 注入と quarantine / clear の原子化、`deinit` からの `CameraStateOwner.release(id:)`
- `Sora/VideoMute.swift`: `VideoHardMuteActor` の保存状態の `CameraCapturerID` 化と `owner.pin(id:instance:)` / `owner.unpin(id:)` の接続、保存状態の上書き前の破棄
- `Sora/PeerChannel.swift`: `initializeCameraVideoCapture` / `terminateSenderStream` の `CameraVideoCapturer.current` / `quarantine(capturerID:)` 経由化
- `Sora/MediaChannel.swift`: `isCameraVideoCaptureRunning` の `CameraVideoCapturer.current` 経由化
- `SoraTests/CameraStateReducerTests.swift` (新規): reducer の状態遷移テスト
- `SoraTests/CameraStateOwnerTests.swift` (新規): owner の ID の値等価性 / generation の採番と直列化 / `stream` の compare-and-swap / capturer の解放 / 隔離のテスト (device 非依存)。実カメラがある環境でのみ、instance テーブルの解決 / `pin` の生存保証と参照カウント / `front` / `back` の単一 instance (同時取得を含む) も検証する (前面 / 背面カメラが無い環境ではそれぞれ skip する)
- `SoraTests/VideoHardMuteActorLeaseTests.swift`: coordinator 直接生成テストでテストローカルの owner を注入し、隔離の照合と解除を owner の snapshot で検証する
- `SoraTests/SendableConformanceTests.swift`: `CameraVideoCapturer` / `CameraCapturerID` / `CameraPhase` / `CameraState` / `CameraEvent` / `CameraEffect` を追加する
- `SoraTests/VideoHardMuteRollbackE2ETests.swift`: skip 条件を `CameraVideoCapturer.current` へ追従する
- `skills/sora-ios-sdk/SKILL.md`: `@unchecked Sendable` / `nonisolated(unsafe)` の記載を実装後の状態へ更新する
- `issues/0116-change-deprecate-sora-dispatcher.md`: 現状節の `SoraDispatcher` 利用ファイルの記述を実装に合わせて更新する
- `issues/0154-refactor-handler-bag-exclusion.md`: 対象に `CameraVideoCapturerHandlers` を追加する
- `CHANGES.md`: `## develop` へ `[UPDATE]` を追記する (`Sendable` 準拠追加と `stream` の生存期間の変更を注記する)

## テスト方針

モックやスタブは使用しない。

- `CameraStateReducerTests.swift`: 純粋な `CameraStateReducer` に native 非依存の `CameraEvent` を入力し、start / stop / restart / change / flip の phase 遷移、`activeCapturerID` の設定 (start 成功時) と解除 (stop 完了時)、複合 command の内部 stop 完了、flip の `sourceID` → `targetID` の移動、`frameRates` の更新、generation 照合、隔離後の stale callback 破棄、restart / change の中間失敗時の `.idle` 復帰を検証する。返る effect が `.publishSnapshot` であることを確認し、native 呼び出しの中身には踏み込まない。
- `CameraStateOwnerTests.swift`: owner をテスト用 init でインスタンス生成し (process-wide の `shared` に依存しない)、`CameraCapturerID` の一意性、generation の採番と並行呼び出しの直列化、snapshot の publish、`stream` の compare-and-swap (一致 / 不一致 / nil 境界 / 利用者の代入を破壊しないこと) を検証する。実 `AVCaptureDevice` と instance テーブル / pin を伴う検証は実機で行う。
- flip の phase 遷移と `isFlipping` の設定 / 解除を reducer テストで検証し、re-entrance 拒否は owner の snapshot を読む command のガードで行う。「start より前に stream を設定する」順序は command の実行順であり reducer では表現できないため、実機で確認する。
- command 実行中に外部 setter で `stream` を差し替えた場合に、失敗時の rollback が利用者の値を破壊しないことを `CameraStateOwnerTests.swift` の compare-and-swap テストで検証し、実 command 経由の差し替えは実機で確認する。
- 実カメラが必要な項目は Simulator では実行できないため実機で確認し、未検証項目として区別する。front / back の実カメラで start、stop、restart、change、flip を連続・並行実行する。
- `MediaChannel.setVideoHardMute` 経由で 2 つの実 `MediaChannel` の connection lease を交差させ、別接続の操作が拒否されることを確認する。拒否する主体は `VideoHardMuteActor` と lease であり、owner 単体では lease 拒否を検証しない。`0098` の回帰確認として、実カメラを共有する 2 接続を同一プロセスで動かす構成 (sender role の接続 2 本、`initialCameraEnabled`、接続ごとの `channelId`) を実機で用意する。
- owner の device 非依存 seam を使い、`setVideoHardMute(true)` の失敗 (別接続がカメラを所有している場合) で `videoEnabled` が呼び出し前の値へ復元されることを検証する。これは `0136` が確定した復元挙動の回帰検証であり、復元の可否は `VideoHardMuteLease.isValid` のみで分岐する。実カメラが必要な経路は実機で確認する。
- callback 内から次のカメラ操作を開始し、deadlock と二重 completion がないことを確認する。stop または flip 中に disconnect し、古い callback が `current` / stream / `isRunning` を復元しないことを確認する。
- `SoraTests/VideoHardMuteActorLeaseTests.swift` を維持する。`CameraVideoCaptureCoordinator` を直接生成するテストではテストローカルの `CameraStateOwner` を注入し、`quarantine()` / `clearQuarantineAfterSuccessfulStop()` / `isQuarantined` の検証対象に owner の snapshot を含める (process-wide の `shared` を汚染せず、テストの実行順に依存しない)。DummyVideoCapturer を使う E2E (`SendonlyE2ETests` など) は本 issue の対象外とする。
- Thread Sanitizer は `0119` の基盤が利用可能になった時点で補助的に実行する。`0151` が未完了の間は完走しないため、完了条件には含めない。
- 最低 iOS 14 世代と現行 iOS の実機で検証する。
- テストには、`await` または callback 復帰後に generation を再確認する理由を日本語コメントで明記する。

## 完了条件

- `CameraVideoCapturer` から `isFlipping` が削除され (owner の state へ移し)、`current` / `handlers` から `nonisolated(unsafe)` が除去されていること。
- `CameraVideoCapturer` から `@unchecked Sendable` が除去されていること。`device` は lock 付きの `@unchecked Sendable` box に、`native` / `nativeDelegate` / `captureSession` は init で確定して以後差し替えない storage に閉じ込め、それらの型と、`AVCaptureDevice` / `RTCCameraVideoCapturer` を保持する型について、残す stored property の一覧と libwebrtc の capture session queue 上でのみアクセスされる不変条件、その不変条件を破る公開経路がないことを型 doc に記載していること。
- `CameraStateReducer` が Sendable な値だけで構成され、native 操作に依存せず、`CameraStateReducerTests.swift` でモックやスタブを使わずに検証できること。
- `CameraStateOwner` が process-wide に 1 つであり、接続所有の識別を event の payload に含めず、`init` 中に `CameraVideoCapturer` を生成しないこと。
- owner が所有する状態 (active capturer、format、frame rate、stream、isRunning、phase、isFlipping、operation generation) が `CameraState` と resource テーブルに集約され、capturer instance の stored property が `id` / `deviceStorage` / `nativeStorage` の 3 つだけであること。`device` / `position` / `captureSession` は computed getter で、`native` / `delegate` は `CameraNativeStorage` の内部に閉じていること。
- owner が active capturer と `front` / `back` を強参照で保持し、加えて `VideoHardMuteActor` が capturer を ID のみで保持している間は `pin` で instance の生存を保証すること。command 終了後と pin 解除後に、不要な instance が保持されないこと。
- `current` / `isRunning` / `stream` / `device` / `format` / `frameRate` / `position` / `captureSession` の同期 getter が owner の同期 wait を行わず、owner の snapshot / resource テーブルまたは box の lock 保護値から読むこと。
- `stream` の setter が resource テーブルへ、`device` の setter が box へ同期で書き、owner の queue を同期 wait しないこと。`flip` の「start より前に stream を設定する」順序と、`flip` / `start` / `restart` の失敗時の rollback が compare-and-swap で、利用者の代入を破壊しないこと。
- restart / change / flip の内部 stop 完了で `current` / `isRunning` が解除され、start 成功時に再設定されること (単体の stop / start と同じ観測結果)。
- `.quarantined` で operation generation が進み、隔離前に開始された command の遅延 callback が隔離を解除しないこと。
- `Sora/CameraVideoCapturer.swift` から `SoraDispatcher` への参照が除去され、libwebrtc の capture session queue への hop が adapter 1 箇所に閉じていること。
- `CameraVideoCapturer` が `Sendable` に準拠したため、`enqueue` / `perform` の `@Sendable` closure と `perform<T: Sendable>` の戻り値で capturer instance を扱えること。coordinator は capturer instance ではなく `CameraCapturerID` で扱い、`quarantine(capturerID:)` / `clearQuarantineAfterSuccessfulStop(capturerID:)` が ID を取ること。
- `CameraVideoCaptureCoordinator` / `VideoSourceCoordinator` / `CameraCaptureOwnership` の不変条件と、`PeerChannel` の「予約確定 → 直列化 → 所有情報設定 → start / stop」順序が維持されていること。
- `CameraEvent` / `CameraEffect` の payload が Sendable な値のみであり、flip の event が `sourceID` と `targetID` を運び、`CameraEffect` が `.publishSnapshot` のみであること。
- 既存公開 API の source compatibility が維持されること (`front` / `back` の `let` → `var` と `current` の computed 化は source 互換として許容し、`git diff` と目視で他の破壊的変更がないことを確認する)。
- `Sora/CameraVideoCapturer.swift` の 536 行の `TODO(zztkm)` を削除していること。
- `skills/sora-ios-sdk/SKILL.md` の `@unchecked Sendable` / `nonisolated(unsafe)` の一覧が実装後の状態と一致し、`CHANGES.md` の `## develop` へ `[UPDATE]` (`CameraVideoCapturer` の `Sendable` 準拠追加と `front` / `back` / `current` の computed 化を含む互換性の注記) が追記されていること。
- `SoraTests/CameraStateOwnerTests.swift` で owner の ID 一意性 / generation の採番と直列化 / `stream` の compare-and-swap が検証され、`CameraVideoCaptureCoordinator` を直接生成するテストがテストローカルの owner を使い、`SoraTests/VideoHardMuteActorLeaseTests.swift` と `CameraStateReducerTests.swift` を含む全テストが成功すること。

### 検証手段

- `current` / `handlers` に `nonisolated(unsafe)` が付与されていないこと: `grep -n "nonisolated(unsafe)" Sora/CameraVideoCapturer.swift` が 0 件であること
- `SoraDispatcher` への型としての依存が無いこと: `grep -rn "SoraDispatcher\." Sora/CameraVideoCapturer.swift` が 0 件であること (doc コメントでの言及は許容する)
- `@unchecked Sendable` の除去と `perform<T: Sendable>` の整合: `SWIFT_VERSION=6` (`.github/workflows/build.yml` / `ci.yml` / `Makefile`) または `-strict-concurrency=complete` でのビルド成功 (SwiftPM の既定 `-swift-version 5` では検出できない)
- flip の `sourceID` / `targetID` 遷移、`isFlipping` の設定 / 解除、request 系 event の世代ガード、quarantine の世代前進と stale callback 破棄、restart / change の中間失敗: reducer テスト
- `isFlipping` が `CameraVideoCapturer` の static フラグとして残っていないこと: `grep -n "isFlipping" Sora/CameraVideoCapturer.swift` の結果が owner の snapshot を読む 1 件のみで、フラグの実体は `Sora/CameraState.swift` にあること
- コンパイラ警告: `xcodebuild build-for-testing` の warning に、変更したファイルの未使用 binding / 未使用変数が無いこと (swift-format / SwiftLint では検出できない)
- coordinator の `CameraCapturerID` 化: `CameraVideoCaptureCoordinator` クラス定義内に `CameraVideoCapturer` への型付き参照が無いことを `grep -n "CameraVideoCapturer" Sora/CameraVideoCapturer.swift` の該当範囲で確認し、ビルドが通ること
- 公開 API の互換、型 doc の条件: `git diff` とレビュー時のチェックリスト
- `PeerChannel` の第 3 経路: 実機チェックリスト

## 解決方法

カメラの共有状態を process-wide な `CameraStateOwner` へ集約し、`CameraVideoCapturer` は instance ごとの資源と ID だけを持つ `Sendable` な型にした。

- `Sora/CameraState.swift` (新規): `CameraCapturerID` / `CameraPhase` / `CameraState` / `CameraEvent` / `CameraEffect` / `CameraStateReducer` を定義した。reducer は Sendable な値だけを扱い、effect は `.publishSnapshot` のみとした。`activeCapturerID` は native start の成功時に設定し native stop の完了時に解除し、restart / change / flip の内部 stop も `.stopCompleted` として通すことで単体の stop と同じ観測結果にした。`.quarantined` は operation generation を進め、隔離前に開始された command の遅延 callback を破棄し、request 系 event にも世代の単調性ガードを入れた。`.quarantineCleared` は隔離中のときだけ解除し、capturer の解放 (`.capturerReleased`) で `frameRates` と `runningCapturers` を破棄する。最終的に `CameraFormatID` / `CameraCommand` / `CameraHandlerKind` / lease 関連 event / `.disconnected` / `.inconsistencyDetected` は採用しなかった。
- `Sora/CameraStateOwner.swift` (新規): serial `DispatchQueue` と `NSLock` 保護の snapshot storage を持つ owner を実装した。`CameraResourceTable` (format / stream) と `CameraInstanceTable` (弱参照) を持ち、`CameraStrongStorage` が active / `front` / `back` と `pin` した instance を強参照で保持する。`front` / `back` の遅延生成は lock の外で instance を作り、lock 内では保持の可否だけを判定して二重生成を防ぐ。`stream` は弱参照で保持し (process-wide な owner が `PeerChannel` ごと保持し続けないため)、capturer の `deinit` から `release(id:)` で format / instance / state を破棄する。storage 型は owner 専用のため `private` とし、`init` は差し替え用の引数を持たない。
- `Sora/CameraVideoCapturer.swift`: `Sendable` に準拠し、`@unchecked Sendable` / `nonisolated(unsafe)` / `isFlipping` を除去した。`current` / `front` / `back` / `handlers` / `isRunning` / `format` / `frameRate` を owner または lock 付き storage から読む accessor にした。camera queue adapter を `CameraQueueExecutor` として本ファイルに追加し、`SoraDispatcher` への型としての依存を除去した。`format` / `frameRate` は native start が成功した場合にだけ記録し、失敗時に要求値が残らないようにした。restart / change / flip の `handlers.onStart` / `onStop` を native stop / start と同じ位置で呼び直し、`start` / `restart` の stream rollback を compare-and-swap にした。`CameraStrongStorage` の `pin` は参照カウント方式とし、複数の lease が同じ capturer を保持しても先の `unpin` で解放しない。flip / start / restart / change に重複していた隔離と画面共有の guard を 1 つの helper へ集約した。停止失敗による隔離は `RTCCameraVideoCapturer.stopCapture` が失敗を通知しないため削除した。`device` を含む同期 accessor の不変条件を型 doc に記載した。
- `Sora/CameraVideoCapturer.swift` (`CameraVideoCaptureCoordinator`): owner を `init` で注入できるようにし、隔離の照合・フラグ更新・ owner への通知を同一 lock 区間で行い、隔離の真実を owner の phase へ移した。
- `Sora/VideoMute.swift`: `VideoHardMuteActor` の保存状態は `[VideoHardMuteLease: CameraCapturerID]` とし、保存中は `CameraStateOwner.pin(id:instance:)` で instance の生存を保証し、破棄時に `unpin` する。同じ lease の保存状態を上書きする場合は先に旧 ID を破棄する。
- `Sora/PeerChannel.swift` / `Sora/MediaChannel.swift`: `CameraVideoCapturer.current` と `quarantine(capturerID:)` / `clearQuarantineAfterSuccessfulStop(capturerID:)` へ置換した。
- `SoraTests/CameraStateReducerTests.swift` (新規 32 件) / `SoraTests/CameraStateOwnerTests.swift` (新規 20 件): reducer の遷移、request 系 event の世代ガード、`isFlipping` の設定 / 解除、隔離後の stale callback 破棄、capturer 解放、ID の値等価性、generation の直列化、`stream` の compare-and-swap、隔離の操作拒否を検証する。
- `SoraTests/VideoHardMuteActorLeaseTests.swift`: coordinator を直接生成するテストへテストローカルの owner を注入した。
- `SoraTests/SendableConformanceTests.swift`: `CameraVideoCapturer` / `CameraCapturerID` / `CameraPhase` / `CameraState` / `CameraEvent` / `CameraEffect` を追加した。
- `skills/sora-ios-sdk/SKILL.md` / `issues/0116` / `issues/0154` / `CHANGES.md`: 実装に合わせて更新した。

### 検証

- ビルド: `xcodebuild build-for-testing` (SWIFT_VERSION=6, iphonesimulator26.5) 成功。
- テスト: 314 件実行 / 失敗 0 (スキップ 29 の内訳は、環境変数未設定時の E2E 23 件と、Simulator に実カメラが無いため skip する 6 件)。
- コンパイラ警告: 変更前から存在する `@Sendable` closure の capture 警告のみで、新規の未使用 binding / 未使用変数は無い。
- swift-format `lint --strict` と SwiftLint (`make lint`) は指摘なし。

### 実機での検証

iPhone 14 / iOS 26.6.1 の samples アプリで、一時的な 2 接続ハーネスと `CameraVideoCapturerHandlers` の一時ログを使って確認した (確認後に一時コードは削除した)。

- start / stop / restart (ハードミュートの ON / OFF を 2 サイクル) / change (720p と 480p の切り替え) / flip (front と back の両方向) が成功すること
- restart / change / flip のいずれでも `handlers.onStart` / `onStop` が `onStop` → `onStart` の順に各 1 回呼ばれること。`onStop` の時点で `isRunning` が false かつ `CameraVideoCapturer.current` が nil、`onStart` の時点で `isRunning` が true であること
- restart / change では同じ instance が使われ、flip では切り替え元と切り替え先で instance が異なること
- flip / change の前後で sender stream が維持されること (encoder が停止・suspend せず、frame の dimensions が切り替え後の解像度に追従する)
- `CameraVideoCapturer.current` が ID から instance を解決できること (handler に渡された instance と `current` が一致する)
- `owner.pin` / `owner.unpin`: ハードミュートで保存した capturer が、別接続が同じ物理カメラを開始・停止した後も生存し、`succeeded to restart` で元の接続の stream へ復帰できること (`stored capturer is no longer available` は発生しない)
- 2 接続の交差: 別接続が使用中のカメラに対する `setVideoHardMute` が `camera is owned by another connection` で拒否され、拒否された呼び出しが `videoEnabled` を変更しないこと。別接続の操作が進行中の間は `video hard mute operation is in progress` で拒否されること
- flip で back の capturer が遅延生成され、そのまま start できること
- 異常系ログ (`camera capture is quarantined after a cleanup failure` / `stored capturer is no longer available` / `CameraVideoCapturer.start failed` / `did not stop capture` / `is not the current camera`) が発生しないこと

実機確認の過程で、次の 2 件は 0103 が変更していない既存の挙動であることを確認し、別 issue として起票した。

- `0160`: `PeerChannel.initializeCameraVideoCapture` の接続時カメラ起動が、別接続が使用中のカメラを無通知で停止して奪う
- `0161`: `Configuration.mediaChannelHandlers` が接続間で共有され、ある接続の handler が別の接続でも発火する (`0161` は 2 接続検証で実際に別接続を切断させた)

### 未検証

- front / back の実カメラで start / stop / restart / change / flip を並行実行すること (個別経路と 2 接続の交差は確認したが、同一 capturer への複数操作の並行実行は未確認)
- `front` / `back` の遅延生成が同時アクセスでも同じ position に 1 つの instance を返すこと (実機では flip による遅延生成のみ確認した)
- `owner.pin` / `owner.unpin` のリークなし (Instruments の Allocations で `RTCCameraVideoCapturer` / `AVCaptureSession` が増え続けないこと)
- `CameraVideoCapturer.stream` は弱参照で保持するため、利用者が `MediaStream` を保持しない場合に解放されること (テストでは解放時期を決定的にできないため実機で確認する)
- 実機での `SoraTests` device-gated 6 件 (`CameraStateOwnerTests` の実カメラ依存テスト)
- `0119` の Thread Sanitizer による検証は本 issue の完了条件に含めていない。
