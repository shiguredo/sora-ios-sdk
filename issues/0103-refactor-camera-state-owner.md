# CameraVideoCapturer のカメラ状態の所有者を単一化する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-camera-state-owner
- Polished: 2026-09-16

## 優先度根拠

- `CameraVideoCapturer` は class 全体が `@unchecked Sendable` で、`current` / `handlers` / `isFlipping` が `nonisolated(unsafe)` のまま残っている。Swift 6 の isolation が型でも実行経路でも保証されていない。
- 公開 API の変更を伴わない内部構造の整理であり、`0116` の前提になるため Medium とする。

## 目的

`CameraVideoCapturer` のカメラ状態の所有者を process-wide に 1 つだけ存在する owner (`CameraStateOwner`) へ集約し、`@unchecked Sendable` と `nonisolated(unsafe)` を除去する refactor とする。カメラの観測挙動と公開 API は変えない。

カメラは「プロセスに 1 つしかない物理資源」と「その資源をどの接続が所有するか」の二層構造になっている。本 issue は二層を分けたまま物理資源側の所有者を 1 つにする。接続所有の識別は owner の command 引数として渡す `VideoHardMuteLease` / `VideoSourceCoordinator.Reservation` / `CameraCaptureOwnership` / `CameraCapturerID` で表現し、owner は接続ごとに生成しない。

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

`front` / `back` 以外にも `public init(device:)` で任意個の instance が生成される (`Sora/PeerChannel.swift`、`Sora/VideoMute.swift`)。536 行の `TODO(zztkm)` (共有状態を actor へ移す) が本 issue の解消対象である。763 行の handler 側 `TODO(zztkm)` は `0110` が扱う。

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
- `Sora/VideoMute.swift` 399 / 431

`perform<T: Sendable>` の戻り値型は `Sora/VideoMute.swift` 362 / 376 / 466 でも capturer を返す。`VideoHardMuteActor.StoredCapturer.capturer` も `CameraVideoCapturer` を型付きで保持する。

### stream の書き込み箇所

`stream` の書き込みは 7 箇所ある。`flipUncoordinated` の 716 (退避は 715) と失敗時の rollback 725 / 736、`startForSDK` の 1097 (設定) / 1101 (rollback、退避は 1095)、`restartForSDK` の 1133 (設定) / 1137 (rollback、退避は 1131)。716 は dispatch closure 直下、725 / 736 は stop / start の完了 callback 内で実行される。

unchecked box は `CameraCaptureFormatBox` (non-Sendable な `AVCaptureDevice.Format`)、`CameraOperationCompletionBox` (非 `@Sendable` closure)、`SenderStreamBox` (non-Sendable な `MediaStream`) の 3 つである。

## 前提となる issue

- `0136` (hard mute の rollback) / `0142` (出力サイズと contain / cover) / `0143` (外部カメラ) は `Sora/CameraVideoCapturer.swift` / `Sora/VideoMute.swift` の同一経路を変更する。3 つを先に完了させてから着手する。
- `0028` (open): `VideoHardMuteActor` の保存状態のクリア意味論を扱う。`0028` を本 issue の前提にはしない。未完了でも `StoredCapturer.capturer` の `CameraCapturerID` 化は行い、クリア条件そのものは変更しない。
- `0051` (open): flip の目標解像度維持を扱う。先に完了した場合は `targetResolution` の挙動を owner の format / frame rate state へ引き継ぎ、未完了の場合は現行の flip の挙動を維持する。前提にはしない。
- `0098` (完了): `0098` が「`0103` の owner への集約で解決する」と記録した `PeerChannel` の第 3 経路を本 issue で owner の command 経由にし、既存の lease / 予約 / 所有情報による保証の対象にする (混線防止の可否判定そのものは変えない)。
- `0099` (完了): flip の stream 設定順と rollback を修正する。`isFlipping` は削除し phase `.flipping` と進行中 command へ移す。`0099` が「`0103` の owner への移植時に実装する」と先送りした start 失敗後の完全復旧は、観測挙動を変えるバグ修正のため本 issue には含めず、新規の bug issue として起票する。
- `0102` (完了): 接続設定を immutable な Sendable snapshot へ変換する。`MediaChannel` / `PeerChannel` の init が受け取る `videoHardMuteLease` / `cameraCaptureCoordinator` / `cameraCaptureOwnership` / `videoSourceCoordinator` を経由する。

## 後続 issue

- `0116` (open): `SoraDispatcher` を非推奨にする。本 issue の完了後に着手する。`0117` は `0116` 経由の間接依存とする。

## 設計方針

### CameraStateOwner

- process-wide に 1 つだけ存在する internal な owner (`CameraStateOwner`) を導入する。`CameraVideoCaptureCoordinator.shared` と同じ寿命とし、`MediaChannel` / `PeerChannel` は owner を保持しない。
- owner は `0100` (完了) の `ConnectionStateOwner` / `ConnectionSnapshotStorage` (`Sora/ConnectionLifecycle.swift`) と同じ方式とする。serial `DispatchQueue` でイベントを直列化し、`NSLock` で保護した immutable snapshot storage を同期 getter が読む。actor を採用すると `current` / `isRunning` / `stream` の同期 getter が維持できず、公開 API の source compatibility を壊すため採用しない。
- `CameraState` の mutate は owner の serial queue 上の `handle(_:)` のみで行う。command は `CameraVideoCaptureCoordinator.perform` から owner へ event を渡して state を直接触らない。owner の直列化は coordinator の注入に依存せず、owner は coordinator を参照しない。
- **初期化順**: owner の `init` では `CameraVideoCapturer` を生成しない。`front` / `back` は owner の固定ストレージ (`frontID` / `backID` と instance) への初回アクセス時に遅延生成し、`register` を経由せず owner 内部で固定 ID を割り当てる。これにより `CameraStateOwner.shared` の初期化中に `CameraVideoCapturer.init` が owner を再入参照しない。
- **ID 採番**: `CameraVideoCapturer` は `let id = CameraCapturerID()` を自身で採番し、`owner.register(id:instance:)` に渡す (owner は採番しない)。`init` の全 stored property を初期化した後に登録する。owner の instance テーブルは弱参照とし、ID → instance 解決専用とする。
- **instance の生存**: owner は active capturer と `front` / `back` を専用の強参照ストレージに保持する。`VideoHardMuteActor` の `storedCapturer` (ID 化後は ID) が指す instance の生存は owner の強参照が保証する。これにより `PeerChannel` / `VideoMute` の `@unknown default` で生成した instance が command 終了後に解放されない。
- owner は 2 つの層を持つ。(1) Sendable な値だけの状態機械 (`CameraState`)、(2) non-Sendable な実資源 (`AVCaptureDevice.Format` / `MediaStream`) を `CameraCapturerID` ごとに保持する resource テーブル。resource テーブルの読み取りは `NSLock` 保護で任意スレッドから行い、libwebrtc の capture session queue 制約は native 呼び出しと Format の差し替えにのみ課す。
- `CameraCapturerID` / `CameraFormatID` は `UUID` を包む `Hashable` / `Sendable` な値型とする。`CameraFormatID` は resource テーブルが `AVCaptureDevice.Format` と対応付ける。

#### 状態機械の型

- `CameraState`: `activeCapturerID: CameraCapturerID?`、`phase: CameraPhase` (`idle` / `starting` / `running` / `stopping` / `flipping` / `quarantined`)、`formatIDs: [CameraCapturerID: CameraFormatID]`、`frameRates: [CameraCapturerID: Int]`、`runningCapturers: Set<CameraCapturerID>`、`activeLeaseID: UUID?`、`operationGeneration: UInt64`、`inFlightCommand: CameraCommand?`。`stream` の値と世代は resource テーブルが同一 lock 下で保持し、state には含めない (`CameraState` を Sendable に保つため)。
- `CameraCommand`: start / stop / restart / change / flip を持ち、対象 `CameraCapturerID`、切り替え先 `CameraCapturerID` (flip)、lease の UUID を associated value に持つ enum。
- `CameraEvent` の payload は UUID / `CameraCapturerID` / `CameraFormatID` / `UInt64` / `Bool` などの値トークンに限定し、`VideoHardMuteLease` / `CameraCaptureOwnership` などの参照型を含めない。`VideoHardMuteLease` は UUID へ落とす (`VideoHardMuteLease` に internal な `id` accessor を追加する)。`0098` が記録した論理接続 ID への移行はこの UUID で行う。
  - `.startRequested(id:leaseID:generation:)` / `.startCompleted(id:generation:success:)` / `.formatResolved(id:formatID:frameRate:generation:)` / `.stopRequested(id:generation:)` / `.stopCompleted(id:generation:success:)` / `.restartRequested(id:generation:)` / `.restartCompleted(id:generation:success:)` / `.changeRequested(id:generation:)` / `.changeCompleted(id:generation:success:)` / `.flipRequested(sourceID:targetID:leaseID:generation:)` / `.flipCompleted(sourceID:targetID:generation:success:)` / `.revoked(leaseID:)` / `.quarantined(id:)` / `.quarantineCleared(id:)` / `.disconnected(id:)` / `.inconsistencyDetected(id:)`
- flip の切り替え先は command が request 前に解決して `targetID` として渡す。reducer は `targetID` で `activeCapturerID` と `runningCapturers` を移す。
- `.formatResolved` が `formatIDs` / `frameRates` を更新する唯一の event であり、effect の format 解決後に command が owner へ渡す。`.revoked(leaseID:)` は `activeLeaseID` と一致する場合だけ generation を進めて `inFlightCommand` を無効化する。
- `CameraEffect` は Sendable な値のみで構成し、command が実行する。`.startNative(id:formatID:frameRate:generation:)` / `.stopNative(id:generation:)` / `.completeVideoSourceReservation(id:)` / `.cancelVideoSourceReservation(id:)` / `.updateOwnership(id:)` / `.notifyVideoHardMute(id:event:)` (成功 / 失敗 / 取消を `VideoHardMuteActor` へ通知する) / `.publishSnapshot`。effect は generation を運び、command は native 完了時に自分の generation で `*Completed` event を生成する。予約・所有情報・lease は command 入力が保持する対応物を使う。completion と `handlers.onStart` / `onStop` は command が自分の入力と対応付けて owner の critical section 外で実行し、effect の payload には `Error` などの非 Sendable 値を含めない (`CameraHandlerKind` (`start` / `stop`) を定義し、`CameraEvent` と混同しない)。
- `CameraStateReducer.reduce(state:event:) -> (CameraState, [CameraEffect])` を純粋関数として定義する。
- restart / change の内部 stop → start は 1 つの複合 command として扱い、中間状態を event にしない (phase は `.stopping` → `.starting` を経由し、途中失敗時は `.idle` へ戻して `runningCapturers` から外す)。この規則を reducer の遷移として定義する。

#### generation / re-entrance / completion

- operation generation は「どの command の callback か」を判定し、`VideoSourceCoordinator` の予約世代は「その送信元予約がまだ有効か」を判定する。callback 復帰時は両方を確認し、owner の generation が不一致なら予約確定も行わない。
- re-entrance は generation とは別に、owner が `inFlightCommand` を保持して判定する。実行中の flip に対する 2 回目の flip は `SoraError.cameraError(reason: "camera flip is already in progress")` で拒否する。
- completion の呼び出し回数は現行どおり 1 回から増減させない。stale callback の破棄は operation generation で行う。
- quarantine の真実は owner の phase に置く。`CameraVideoCaptureCoordinator` はキャッシュを持たず、`isAvailable` は owner の snapshot を pull して判定する。`CameraVideoCapturer` への型付き参照を coordinator から除去する。画面共有の予約 (`hasScreenReservation`) は owner の外の guard として維持し、command 開始時に確認する。

### executor と native 操作

- owner の command 直列化は `CameraVideoCaptureCoordinator` の `SerializedAsyncOperationQueue` が担う。隔離の判定は command の開始時に行う。
- native 操作 (`RTCCameraVideoCapturer.startCapture` / `stopCapture` / delegate) は libwebrtc の capture session queue 上でのみ実行する。`Sora/CameraVideoCapturer.swift` 内に internal な camera queue adapter を 1 つ置き、`RTCDispatcher.dispatchAsync(on: .typeCaptureSession)` をこの 1 箇所に閉じ込める。owner は adapter 経由で native を呼び、`SoraDispatcher` への参照を本ファイルから除去する。`currentForSDK()` は owner の同期 snapshot getter に置き換えて削除する。
- `RTCCameraVideoCapturer` が frame callback を発火する executor を upstream libwebrtc の `RTCCameraVideoCapturer.m` または `WebRTC.xcframework` の header で確認し、adapter の不変条件 (どの queue から何を読み書きするか) を型 doc に日本語で記載する。確認できない場合は「現行どおり capture session queue 上で callback が発火する」前提を型 doc に明記する。
- capturer を `enqueue` / `perform` の `@Sendable` closure へ capture・返却している経路 (現状 8 箇所) を `CameraCapturerID` と owner の resource 解決へ置換する。

### static state と公開 API

- `current` は `public static var current: CameraVideoCapturer? { get }` の get-only computed property とし、owner の snapshot (`activeCapturerID`) を instance テーブルで解決した instance を返す。内部書き込みは owner の強参照ストレージへの publish に一本化するため setter は設けない。get-only のため外部からは従来どおり読み取り専用で、ソース互換を維持する。
- `handlers` は lock で保護した storage から同一インスタンスを返す get / set 付き computed property とする。`public static var` のシグネチャと `CameraVideoCapturer.handlers.onCapture = ...` の in-place 変更を維持する。`CameraVideoCapturer.handlers = ...` の代入は storage の差し替えとして受け付ける。`CameraVideoCapturerHandlers` の closure property 自体の排他は本 issue では行わず、`0154` の対象に加えて行う。
- `device` / `native` / `nativeDelegate` は lock 付きの internal な `@unchecked Sendable` box (`CameraDeviceStorage` / `CameraNativeStorage`) に保持する。`device` の getter / setter と `captureSession` の getter は box の lock 下で同期で読み書きし、owner の queue を同期 wait しない。`position` も同じ box を読む。owner の command は command 開始時 (capture session queue 上) に box から device を読む。box の安全性の根拠を型 doc に記載する。
- `front` / `back` は `public static var CameraVideoCapturer?` の computed property とし、owner の固定ストレージ (`frontID` / `backID`) から instance を返す。computed 化の根拠は「position → instance の解決経路を owner 発行 ID に一本化するため」である。読み取り専用の利用に対してソース互換である。
- `stream` は owner の publish 対象から外し、getter / setter / owner の参照直前読み出しがすべて同一の lock 付き resource テーブルを読み書きする。値の更新と世代の加算を同じ lock 下で行い、所有者の照合は世代ではなく同じ lock 下での実 `MediaStream` の同一性で行う。`stream` の setter は `(CameraCapturerID, MediaStream?)` を同期で書く。owner の command は自分が対象とする `CameraCapturerID` の entry を参照直前に読み直す。これにより `flip` の command 内部で行う `flip.stream = capturer.stream` (716 行) の代入が同じ command 内の start に反映される。外部の setter による割り込みは次の参照から反映され、進行中の command を無効化しない。command が失敗して rollback する場合 (725 / 736 / 1101 / 1137 行) は、command が最後に storage へ書いた値が現在も残っている場合だけ書き戻す (compare-and-swap 相当)。利用者が command 実行中に代入していた場合は利用者の値を保持する。setter から owner の queue を `sync` しない (capture session queue 上からの代入で deadlock するため)。
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

- `Sora/CameraState.swift` (新規): `CameraState` / `CameraEvent` / `CameraEffect` / `CameraCommand` / `CameraPhase` / `CameraHandlerKind` / `CameraStateReducer` / `CameraStateOwner` / `CameraCapturerID` / `CameraFormatID`
- `Sora/CameraVideoCapturer.swift`: owner の導入、`nonisolated(unsafe)` の除去、camera queue adapter、`CameraDeviceStorage` / `CameraNativeStorage`、`stream` / `device` / `current` / `handlers` / `front` / `back` の accessor、`currentForSDK()` の削除、`@Sendable` closure から capturer capture の除去
- `Sora/VideoMute.swift`: `VideoHardMuteActor` から owner の command への接続、`StoredCapturer.capturer` の `CameraCapturerID` 化、`setMute` 内の `currentCapturer` ローカルの ID 化、`CameraStartAuthorization` の写像、`VideoHardMuteLease` への internal な `id` accessor 追加
- `Sora/PeerChannel.swift`: `initializeCameraVideoCapture` / `terminateSenderStream` の owner 経由化
- `Sora/MediaChannel.swift`: owner の command 入力の受け渡しと `isCameraVideoCaptureRunning` の owner 経由化
- `SoraTests/CameraStateReducerTests.swift` (新規): reducer の状態遷移テスト
- `SoraTests/CameraStateOwnerTests.swift` (新規): owner の ID 採番 / generation / `stream` の compare-and-swap のテスト (device 非依存)
- `SoraTests/VideoHardMuteActorLeaseTests.swift`: `CameraStartAuthorization` の写像と coordinator 直接生成テストの更新
- `skills/sora-ios-sdk/SKILL.md`: `@unchecked Sendable` / `nonisolated(unsafe)` の記載を実装後の状態へ更新する
- `issues/0116-change-deprecate-sora-dispatcher.md`: 現状節の `SoraDispatcher` 利用ファイルの記述を実装に合わせて更新する
- `issues/0154-refactor-handler-bag-exclusion.md`: 対象に `CameraVideoCapturerHandlers` を追加する
- `CHANGES.md`: `## develop` へ `[UPDATE]` を追記する (公開 API の変更はない)

## テスト方針

モックやスタブは使用しない。

- `CameraStateReducerTests.swift`: 純粋な `CameraStateReducer` に native 非依存の `CameraEvent` を入力し、start / stop / restart / change / flip の phase 遷移、flip の `sourceID` → `targetID` の移動、`.formatResolved` による format / frame rate の更新、generation 照合、re-entrance 拒否、restart / change の中間失敗時の `.idle` 復帰、不整合検出時の quarantine 遷移を検証する。effect の一覧までを検証し、native 呼び出しの中身には踏み込まない。一致する generation で完了 effect が 1 回だけ、stale generation では 0 回であることも検証する (continuation の resume 1 回は command の構築で保証する)。
- `CameraStateOwnerTests.swift`: owner をテスト用 init でインスタンス生成し (process-wide の `shared` に依存しない)、device 非依存の登録 seam で `CameraCapturerID` を登録して ID 採番、instance テーブル、generation の照合、`stream` の compare-and-swap を検証する。実 `AVCaptureDevice` を使う instance の検証は実機で行う。
- flip の phase 遷移と re-entrance 拒否を reducer テストで新規に追加し、本 issue の自動回帰基準とする。「start より前に stream を設定する」順序は effect の実行順であり reducer では表現できないため、owner の command 実行順のテストまたは実機で確認する。
- owner の command 実行中に外部 setter で `stream` を差し替え、(i) 成功時は command の値が、(ii) 失敗時は利用者の値が最終値になることを `CameraStateOwnerTests.swift` で検証し、実 command 経由の差し替えは実機で確認する。
- 実カメラが必要な項目は Simulator では実行できないため実機で確認し、未検証項目として区別する。front / back の実カメラで start、stop、restart、change、flip を連続・並行実行する。
- `MediaChannel.setVideoHardMute` 経由で 2 つの実 `MediaChannel` の connection lease を交差させ、別接続の操作が拒否されることを確認する。拒否する主体は `VideoHardMuteActor` と lease であり、owner 単体では lease 拒否を検証しない。`0098` の回帰確認として、実カメラを共有する 2 接続を同一プロセスで動かす構成 (sender role の接続 2 本、`initialCameraEnabled`、接続ごとの `channelId`) を実機で用意する。
- owner の device 非依存 seam を使い、`setVideoHardMute(true)` の失敗 (別接続がカメラを所有している場合) で `videoEnabled` が呼び出し前の値へ復元されることを検証する。これは `0136` が確定した復元挙動の回帰検証であり、復元の可否は `VideoHardMuteLease.isValid` のみで分岐する。実カメラが必要な経路は実機で確認する。
- callback 内から次のカメラ操作を開始し、deadlock と二重 completion がないことを確認する。stop または flip 中に disconnect し、古い callback が `current` / stream / `isRunning` を復元しないことを確認する。
- `SoraTests/VideoHardMuteActorLeaseTests.swift` を維持する。`CameraStartAuthorization` を owner の command 入力へ写す場合、同テストが直接構築している箇所 (234-246 / 537-545 行) を新しい入力型へ更新する。同テストは `CameraVideoCaptureCoordinator` を直接生成して `quarantine()` / `clearQuarantineAfterSuccessfulStop()` / `isQuarantined` を検証しているため (224 / 260 / 518 行)、quarantine の真実を owner phase へ移す変更に合わせて、検証対象を owner の snapshot へ切り替える。DummyVideoCapturer を使う E2E (`SendonlyE2ETests` など) は本 issue の対象外とする。
- Thread Sanitizer は `0119` の基盤が利用可能になった時点で補助的に実行する。`0151` が未完了の間は完走しないため、完了条件には含めない。
- 最低 iOS 14 世代と現行 iOS の実機で検証する。
- テストには、`await` または callback 復帰後に generation を再確認する理由を日本語コメントで明記する。

## 完了条件

- `CameraVideoCapturer` から `isFlipping` が削除され、`current` / `handlers` から `nonisolated(unsafe)` が除去されていること。
- `CameraVideoCapturer` から `@unchecked Sendable` が除去されていること。`device` / `native` / `nativeDelegate` は lock 付きの `@unchecked Sendable` box に閉じ込め、box と、`AVCaptureDevice` / `RTCCameraVideoCapturer` を保持する型について、残す stored property の一覧と libwebrtc の capture session queue 上でのみアクセスされる不変条件、その不変条件を破る公開経路がないことを型 doc に記載していること。
- `CameraStateReducer` が Sendable な値だけで構成され、native 操作に依存せず、`CameraStateReducerTests.swift` でモックやスタブを使わずに検証できること。
- `CameraStateOwner` が process-wide に 1 つであり、接続所有の識別を command 引数で受け取り、`init` 中に `CameraVideoCapturer` を生成しないこと。
- owner が所有する状態 (active capturer、format、frame rate、stream、isRunning、phase、operation generation) が `CameraState` と resource テーブルに集約され、capturer instance に残るのは `id` / lock 付き box の `device` / `native` / `nativeDelegate` / `position` / `captureSession` の getter だけであること。
- owner が active capturer と `front` / `back` を強参照で保持し、command 終了後に実行中 instance が解放されないこと。
- `current` / `isRunning` / `stream` / `device` / `format` / `frameRate` / `position` / `captureSession` の同期 getter が owner の同期 wait を行わず、owner の snapshot / resource テーブルまたは box の lock 保護値から読むこと。
- `stream` の setter が resource テーブルへ、`device` の setter が box へ同期で書き、owner の queue を同期 wait しないこと。`flip` の「start より前に stream を設定する」順序と、失敗時の rollback が利用者の代入を破壊しないこと。
- `Sora/CameraVideoCapturer.swift` から `SoraDispatcher` への参照が除去され、libwebrtc の capture session queue への hop が adapter 1 箇所に閉じていること。
- `enqueue` / `perform` の `@Sendable` closure と `perform<T: Sendable>` の戻り値に capturer instance を渡しておらず、coordinator の `perform` / `quarantine(capturer:)` / `clearQuarantineAfterSuccessfulStop(capturer:)` / `quarantinedCapturer` が `CameraCapturerID` で扱われていること。
- `CameraVideoCaptureCoordinator` / `VideoSourceCoordinator` / `CameraCaptureOwnership` の不変条件と、`PeerChannel` の「予約確定 → 直列化 → 所有情報設定 → start / stop」順序が維持されていること。
- `CameraEvent` / `CameraEffect` の payload が Sendable な値のみであり、flip の event が `sourceID` と `targetID` を運ぶこと。
- 既存公開 API の source compatibility が維持されること (`front` / `back` の `let` → `var` と `current` の computed 化は source 互換として許容し、`git diff` と目視で他の破壊的変更がないことを確認する)。
- `Sora/CameraVideoCapturer.swift` の 536 行の `TODO(zztkm)` を削除していること。
- `skills/sora-ios-sdk/SKILL.md` の `@unchecked Sendable` / `nonisolated(unsafe)` の一覧が実装後の状態と一致し、`CHANGES.md` の `## develop` へ `[UPDATE]` (公開 API の変更はない) が追記されていること。
- `SoraTests/CameraStateOwnerTests.swift` で owner の ID 採番 / generation / `stream` の compare-and-swap が検証され、`SoraTests/VideoHardMuteActorLeaseTests.swift` と `CameraStateReducerTests.swift` を含む全テストが成功すること。

### 検証手段

- `current` / `handlers` に `nonisolated(unsafe)` が付与されていないこと: `grep -n "nonisolated(unsafe)" Sora/CameraVideoCapturer.swift` の結果が残す box の宣言のみであること
- `SoraDispatcher`: `grep -rn "SoraDispatcher" Sora/CameraVideoCapturer.swift` が 0 件
- `@unchecked Sendable` の除去と `perform<T: Sendable>` の整合: `SWIFT_VERSION=6` (`.github/workflows/build.yml` / `ci.yml` / `Makefile`) または `-strict-concurrency=complete` でのビルド成功 (SwiftPM の既定 `-swift-version 5` では検出できない)
- flip の `sourceID` / `targetID` 遷移、re-entrance、quarantine 遷移、completion effect の回数、restart / change の中間失敗: reducer テスト
- coordinator の `CameraCapturerID` 化: `CameraVideoCaptureCoordinator` クラス定義内に `CameraVideoCapturer` への型付き参照が無いことを `grep -n "CameraVideoCapturer" Sora/CameraVideoCapturer.swift` の該当範囲で確認し、ビルドが通ること
- 公開 API の互換、型 doc の条件: `git diff` とレビュー時のチェックリスト
- `PeerChannel` の第 3 経路: 実機チェックリスト

## 解決方法
