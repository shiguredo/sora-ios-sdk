# ScreenCapture の sample buffer 所有境界を明確にする

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-screen-capture-buffer-ownership
- Polished: 2026-09-17

## 目的

ReplayKit callback が渡す non-Sendable な `CMSampleBuffer` を `DispatchQueue` の escaping closure へそのままキャプチャする構造をなくす。

sample buffer と backing pixel buffer の lifetime / alias を明確にし、executor を越えて渡す値を SDK が所有権を持つ表現へ限定する。公開 API と観測挙動は変えず、内部の所有境界だけを変更する refactor とする。

## 現状

`Sora/ScreenCapture.swift` の `ScreenCaptureController.handleSampleBuffer(sampleBuffer:sampleBufferType:error:)` (510-573 行目) は、ReplayKit から受け取った `CMSampleBuffer` を `sendVideoFrameQueue.async` (539 行目) の closure へそのままキャプチャする (548 行目)。

同じ closure は次の non-Sendable な値も扱う。

- `sampleBuffer` を包む `CaptureContext` (128-134 行目)。`senderStream: MediaStream` と `videoSampleBufferTransformer` を保持する
- closure 内で生成する `VideoFrame` (555 行目)。`RTCCVPixelBuffer` は `CVPixelBuffer` を alias する (`Sora/VideoFrame.swift:52-63`)
- `context.senderStream.send(videoFrame:)` (571 行目)

`Sora/MediaStream.swift` の `MediaStream` は `Sendable` に準拠せず、`Sora/VideoFrame.swift` の `VideoFrame` も `RTCVideoFrame` を保持するため `Sendable` ではない。`CMSampleBuffer` と `CVPixelBuffer` も `Sendable` ではない。

Swift 6 言語モード (`SWIFT_VERSION=6`。`Makefile:22` / `.github/workflows/build.yml:35` / `.github/workflows/ci.yml:62`) では、この capture が `build/typecheck.log:424,438` に `#SendableClosureCaptures` warning として現れる (`build/tsan-test.log:549,555` にも同じ warning がある)。warning のため CI のビルドは成功しており、型としての契約にはなっていない。

`ScreenCaptureController: @unchecked Sendable` (118 行目) と `NSLock` は controller の可変 stored property を保護するが、closure にキャプチャされた sample buffer の executor 越境と backing storage の不変性は保証しない。

Core Foundation object の retain により参照寿命は延長できるが、ReplayKit callback を抜けた後の buffer 再利用、pixel buffer の alias、別 queue からの安全な読み取りはコード上の契約になっていない。

## 前提となる issue

- `0097` (完了): capture ID を frame context へ含め、停止前の queued frame を送信直前に拒否する。`CaptureContext.captureID` と `isActiveCaptureID(_:)` として実装済み。本 issue はこの世代照合を維持する。
- `0100` / `0101` / `0102` (完了) / `0103` (完了): 接続状態 / signaling / 接続設定 / カメラ状態の owner 化。`0103` は `Sora/CameraStateOwner.swift` で「lock 下でのみ読み書きする `@unchecked Sendable` の resource table」方式を確立し、`CameraVideoCapturer.stream` を弱参照で保持する。本 issue はこの方式と矛盾しない範囲で画面共有側の buffer 所有を定義する。
- `0103` の「画面共有側の状態所有は `0104` で扱う」という委譲は、本 issue の「`ScreenCaptureController` の state lock と `@unchecked Sendable` の扱い」で受ける。
- `0137` (open): `Sora/ScreenCapture.swift` の start 失敗時の `recordRecorderStart` / `captureState` / `finishStop` を変更する。本 issue は buffer の所有境界のみを対象とし、`captureState` の遷移と recorder ownership には踏み込まない。両 issue は同じファイルの別関数を対象とするため、`0137` が先行しても `handleSampleBuffer` の入り口は変わらない。

## 設計方針

### 対象範囲

ReplayKit callback から `sendVideoFrameQueue` へ渡る sample buffer の所有境界だけを変更する。変換処理の実行順序、`isReadyToSend()` の判定位置、`videoSampleBufferTransformer` を実行する executor は現行のまま維持する。

現行の実行順序は「ReplayKit callback で `captureContext()` が capture ID / sender stream / transformer を snapshot し、`captureState == .running` でなければ破棄 (525 / 624-641 行目) → `shouldSendVideoFrame` (531 行目) → `sendVideoFrameSemaphore` の即時取得 (536 行目) → enqueue (539 行目) → queue 上で `isReadyToSend()` (544 行目) → transformer (549 行目) → `VideoFrame` 生成 (555 行目) → capture ID 照合 (564 行目) → `markVideoFrameSent` (570 行目) → `send` (571 行目)」である。

`captureContext()` (624-641 行目) は削除し、callback 時の capture 状態確認 / capture ID 取得と、queue 時の sender stream 解決 / transformer 取得へ分割する。

callback 側では `captureState == .running` の確認を現行と同じ位置 (間引き判定より前) に残す。これにより `.starting` の間に到着した frame は現行どおり semaphore を取得せずに破棄され、queue closure へ入らない。`activeCaptureID` は semaphore を取得した後に確認し、`nil` の場合は signal して戻る (取得済みの flight を返却する)。現行は `captureContext()` が `activeCaptureID != nil` も同時に要求して semaphore 取得前に破棄するため、この点だけ挙動が変わる。`.starting` → `.running` の直後に到着する frame が semaphore 取得に失敗し得るのは現行と同じである。

### 新しく導入する所有型

`Sora/ScreenCapture.swift` に internal な 2 つの型を追加する。

- `ScreenCaptureOwnedSampleBuffer`: ReplayKit から受け取った `CMSampleBuffer` を所有する。`init?(_ sampleBuffer: CMSampleBuffer)` で `CMSampleBufferCreateCopy` を呼び、失敗 (`OSStatus != noErr`) は `nil` を返す。`@unchecked Sendable` を付与し、根拠を日本語の型 doc に書く。
- `ScreenCaptureOwnedFrame`: queue closure へ渡す payload。`captureID: UInt64`、`presentationTimestamp: CMTime`、`sampleBuffer: ScreenCaptureOwnedSampleBuffer` を持つ。`@unchecked Sendable` を付与し、根拠を日本語の型 doc に書く。

`@unchecked Sendable` の根拠として書く不変条件は次の 2 点に限定する。これ以外の根拠で `@unchecked Sendable` を正当化しない。

1. Create ルールで得た `CMSampleBuffer` オブジェクトの所有権が単一の所有者に移り、その所有者だけがオブジェクトを読む (コピー元のオブジェクトは参照カウントの増減以外に触らない)。`CMSampleBufferCreateCopy` は +1 の参照を返し、参照カウントの増減は CF が排他する。
2. `ScreenCaptureOwnedFrame` は生成側 (ReplayKit callback の executor) から消費側 (`sendVideoFrameQueue`) へ所有権ごと移動し、移動後は生成側が値を参照しない。移動は 1 回だけで、複数の executor が同じ値を同時に読まない。

`CMSampleBufferCreateCopy` は image buffer (画素データ) を共有するため、backing pixel buffer が immutable であることや ReplayKit が元 buffer を再利用しないことは根拠に含めない。この点は「`CMSampleBufferCreateCopy` を選ぶ理由」と「実機で確認する項目」で扱う。

`SenderStreamBox` (`Sora/VideoMute.swift:26`) と同種の「raw `MediaStream` を移送するための box」、`nonisolated(unsafe)` によるローカル捕捉、non-`@Sendable` closure への捕捉は、raw `MediaStream` の移送手段として使用しない。

### `CMSampleBufferCreateCopy` を選ぶ理由

- deep copy は行わない。`CMSampleBufferCreateCopy` は image buffer を複製せず参照を共有するため、フレームごとの画素データの memcpy と追加の pixel buffer 確保が発生しない。`CVPixelBufferCreate` と plane 単位のコピーは導入しない。
- `CMSampleBufferCreateCopy` は「Create ルールで所有権を得て、queue へ所有権を移す」ための最小の操作である。deep copy と同じ隔離は得られない。
- ReplayKit が callback 後に buffer を再利用するかは一次資料で確認できない (`RPScreenRecorder.h` には handler の executor も buffer lifetime も記載がない)。再利用の有無と再開後の tearing の有無を実機で観測し、必要と判明した場合の deep copy 化は別 issue とする。本 issue では `CVPixelBufferCreate` と plane 単位のコピーを導入せず、完了条件にも含めない。
- 画素データを deep copy しないため、`CVPixelBuffer` を `Sendable` として越境させる必要はない。

### queue 境界へ渡す値

- `sendVideoFrameQueue` の closure がキャプチャする値は `ScreenCaptureOwnedFrame` と `self` だけにする。`self` は `ScreenCaptureController: @unchecked Sendable` であり、`[weak self]` で弱参照する (現行 539 行目と同じ)。`CaptureContext` は削除し、closure へ渡さない。
- `ScreenCaptureOwnedFrame.captureID` には、callback 時に lock 区間で取得した `activeCaptureID` を入れる。`captureContext()` が 1 つの lock 区間で capture ID と sender stream を snapshot していた性質を、capture ID は callback 時の payload、sender stream は queue 時の解決として引き継ぐ。
- `senderStream` と `videoSampleBufferTransformer` は、queue 上で `ScreenCaptureController` の lock 付き state から読む。callback 側では transformer を解決しない。`settings` は `beginStartCapture` (469 行目) が世代ごとに上書きするため、queue 上で読む transformer は「queue 実行時点の世代の設定」になる。capture ID の照合を transformer の実行より後に行うことで、旧世代の frame に新世代の transformer が適用された場合も送信されないようにする。
- 送信先 `MediaStream` の解決と capture ID の照合は同一の lock 区間で行う。`activeCaptureID` と `senderStream` を原子的に取得し、payload の `captureID` がその `activeCaptureID` と一致しない場合は送信しない。`scheduleStopCapture` は `activeCaptureID = nil` と `senderStream = nil` を同期的に確定する (370-373 行目) ため、停止後に queue 側で解決すると両方が `nil` になり、`0097` で修正した「restart 後に旧 frame × 新 stream の組み合わせが成立する」経路は復活しない。
- `Sendable` でない値を closure へ渡す必要が生じた場合は、`nonisolated(unsafe)` や型の unchecked 化で回避せず、payload 型を `Sendable` にして型で強制する。

### transformer の 3 経路

queue 上の transformer の扱いは現行 (549-553 行目) と同じ 3 経路を維持する。既定の `ScreenCaptureSettings()` は transformer が `nil` であるため、経路 2 を「破棄」と読み違えると既定の画面キャプチャが全フレーム破棄になる。

1. `videoSampleBufferTransformer` が `nil` の場合は、元の sample buffer をそのまま `VideoFrame` へ変換して送信する。
2. transformer があり `nil` を返した場合は、その frame を破棄する。`Logger.debug` は出さない (現行どおり)。
3. transformer があり `CMSampleBuffer` を返した場合は、返された buffer を `VideoFrame` へ変換して送信する。

### queue 上の処理順

queue closure の処理順を次に固定する。この順序は `0097` が確定した不変条件の維持を目的とする。

1. `captureState == .running` の内部述語を確認する (現行 `isReadyToSend()` の 544 行目のうち capture state の判定)。失敗した場合も signal する (step 7)。`.connected` の判定は `isReadyToSend()` に残り、`processOwnedFrame` からは行わない (テストが接続なしで queue 上の処理を駆動できるようにするため)。
2. transformer を実行する (現行 549 行目と同じ executor)。これには「transformer が未設定なら元の buffer をそのまま使う」「設定済みで `nil` を返したら破棄する」の両方を含む (前節の 3 経路)。
3. `VideoFrame(from:)` で frame を生成する。失敗時は `Logger.debug` のログだけを出して戻る (現行 556 行目と同じ)。
4. lock 区間で `activeCaptureID` と `senderStream` を取得し、payload の `captureID` が `activeCaptureID` と一致する場合だけ送信対象にする。不一致、`activeCaptureID` が `nil`、`senderStream` が `nil` のいずれかなら戻る。これにより、queue の実行待ちの間に stop または stop → restart が完了した旧世代の frame は送信されない。
5. 4 の capture ID 照合を通過した後にだけ `markVideoFrameSent` を呼ぶ。`lastSentVideoPresentationTimestamp` と `lastSentVideoUptime` の更新は送信が確定した frame に限定する。4 の照合の後に stop が確定する競合は現行と同じであり、本 issue では変更しない。
6. `senderStream.send(videoFrame:)` を呼ぶ。
7. 1 から 6 のどの経路で戻っても、`sendVideoFrameSemaphore` を signal する。signal は `defer` で 1 回だけ行い、step 1 の capture state 述語の失敗も含める。現行の `defer` (541 行目) は closure 先頭にあり、すべての return で signal している。

`sendVideoFrameSemaphore` は「送信処理中に到着したフレームを待たずに破棄する」単発 flight の契約を維持する。callback 側で enqueue 直後に signal してはならない。

### callback 側の処理

1. `captureState == .running` を確認する (現行 `captureContext()` の guard と同じ位置)。`.running` でなければ semaphore を取得せずに戻る。
2. `shouldSendVideoFrame` で間引き判定を行う (現行 531 行目と同じ位置)。送信対象でなければ戻る。
3. `sendVideoFrameSemaphore` を即時取得する (現行 536 行目と同じ)。取得できなければ戻る。
4. lock 区間で `activeCaptureID` を取得する。`activeCaptureID` が `nil` の場合は、取得済みの `sendVideoFrameSemaphore` を signal して戻る。
5. `CMSampleBufferCreateCopy` で `ScreenCaptureOwnedSampleBuffer` を生成し、`ScreenCaptureOwnedFrame(captureID:presentationTimestamp:sampleBuffer:)` に詰めて enqueue する。
6. コピーの失敗時は queue へ enqueue せず、取得済みの `sendVideoFrameSemaphore` を signal して戻る。
7. コピーは浅いコピーであり、callback の実行時間は現行 (間引き判定と semaphore 取得のみ) から大きく増えない。transform と `VideoFrame` 生成は現行どおり queue 上で行う。

### テスト用の internal seam

`handleSampleBuffer` は private のまま維持する。内部を次の 3 つに分け、テストは接続を行わずに「queue 上の処理」と「callback の破棄判断」を決定的に駆動する。名称は実装時に `beginStartCapture` / `completeStartCapture` / `isActiveCaptureID` と同じ方針で決める。

- `processOwnedFrame(_ ownedFrame: ScreenCaptureOwnedFrame)`: queue 上の処理 (queue 上の処理順の 1 から 7) を行う internal メソッド。`sendVideoFrameSemaphore` は取得せず、queue closure の `defer` と同じ位置で signal する。本番の queue closure はこのメソッドを呼ぶ。
- `performSend(ownedFrame: ScreenCaptureOwnedFrame) -> Bool`: テスト用の取得 wrapper。`tryAcquireSendFlight()` が `true` を返した場合だけ `processOwnedFrame` を呼び、`false` の場合は何もせず `false` を返す (permit を二重に増やさない)。取得に失敗した場合は `isReadyToSend()` と同じ扱いで frame を破棄する。
- `enqueueOwnedFrame(sampleBuffer:presentationTimestamp:) -> Bool` (callback 側): 間引き判定、`sendVideoFrameSemaphore` の即時取得、`activeCaptureID` の確認、`CMSampleBufferCreateCopy`、enqueue を行い、enqueue した場合だけ `true` を返す。`handleSampleBuffer` は ReplayKit の `RPSampleBufferType` と `Error?` を処理した後、このメソッドへ実 buffer を渡す。

`sendVideoFrameSemaphore` は private のため、`tryAcquireSendFlight()` を internal に追加する。テストはこれを直接呼んで permit を保持し、その状態で `enqueueOwnedFrame` を呼ぶことで「即時取得に失敗して破棄される frame」を再現できる。

enqueue 後に queue の処理完了を待つため、`drainSendVideoFrameQueue()` を internal に追加する。中身は `sendVideoFrameQueue.sync {}` と、その直後に 1 回だけ `sendVideoFrameSemaphore.wait()` を呼んで `defer` の signal を回収する処理とする。`enqueueOwnedFrame` が `false` を返した場合 (permit を取得していない場合) は wait せずに戻る。これにより、テストは enqueue の有無にかかわらず permit 数を元に戻せる。

`isReadyToSend()` と `shouldSendVideoFrame(presentationTimestamp:)` を private から internal に変更する。`performSend` は接続の有無を判定しない (`mediaChannel.state` を見ない) ため、テストは未接続のまま queue 上の処理を駆動できる。`.connected` の判定は `isReadyToSend()` の中だけに残し、`performSend` は `captureState == .running` の判定のみを行う。`isReadyToSend()` 自体の挙動 (`.disconnected` で `false`) は internal 化してテストする。

`lastSentVideoPresentationTimestamp` / `lastSentVideoUptime` は private のため、timestamp の確認には既存の `isActiveCaptureID` と同じ方針で internal な読み出し用アクセサを追加する。テストはアクセサで値の更新有無を直接確認する。

`CaptureState` は `enqueueOwnedFrame` の引数に取らず、controller の lock 付き state を `handleSampleBuffer` と同じ経路で読む。そのため `CaptureState` の internal 化は行わない。

テストは `beginStartCapture` で `.starting` にした後 `completeStartCapture(captureID:error: nil)` を呼んで `.running` にする (`beginStartCapture` だけでは `.starting` のままで `.running` にならない。455-503 行目)。世代を進める場合は `ScreenCaptureController.stopCapture()` (internal、275 行目) を `await` して停止を確定させ、その後に次の capture を開始する。`completeStopCapture` は private で `recorderStopped: Bool` を取るため、テストからは呼ばない。

`MediaChannel` を `.connected` にするには実 Sora サーバーとの接続が必要で、ReplayKit の画面共有も Simulator では動作しない。そのため未接続で実行できる `performSend` と `enqueueOwnedFrame` を使い、`isReadyToSend()` の `.connected` ゲートは「本 issue で変更しない既存挙動」として実機確認に回す。

### 送信の観測方法

`performSend` は接続の有無を判定しないため、未接続でも送信経路の観測ができる。

- sender stream は `NativePeerChannelFactory.createNativeSenderStream(streamId:videoTrackId:audioTrackId:constraints:)` (`Sora/NativePeerChannelFactory.swift:265-298`) で生成し、`videoTrackId` を渡す。既存テストの `makeSenderStream` (94-98 行目) が使う `createNativeStream` は video track を作らないため `nativeVideoSource` が `nil` になり、WebRTC の video source へ frame が到達しない (`send` は `videoFilter` を呼んだ後に `nativeVideoSource` を optional chaining する)。
- `VideoFilter` 実装は `filter(videoFrame:)` の呼び出し回数を記録する。WebRTC の video source への到達は実 `RTCVideoSource` を持つ sender stream の `videoTrackId` で確認する。どちらも実 API の組み合わせであり、モックは使わない。
- `sendVideoFrameSemaphore` の回復は、早期 return となる frame (capture state 不一致 / transformer の nil / `VideoFrame` 生成失敗 / capture ID 不一致) を処理した直後に `performSend` が `true` を返し、次に送信される frame が `VideoFilter` へ到達することで観測する。
- `lastSentVideoPresentationTimestamp` / `lastSentVideoUptime` の更新有無は、internal な読み出し用アクセサで直接確認する。

### 公開 API の契約

- `ScreenCaptureSettings.videoSampleBufferTransformer` が呼ばれる executor と、返した `CMSampleBuffer` の所有契約は現行から変更しない。現行は `sendVideoFrameQueue` 上であり、本 issue でも同じ executor のままとする。この契約を `ScreenCaptureSettings` (16-18 行目) と `MediaChannel.startScreenCapture` (`Sora/MediaChannel.swift:1476-1485`) の doc コメントへ明記する。
- transformer が返す `CMSampleBuffer` は、同じ queue closure 内で `VideoFrame` へ変換される。`VideoFrame` が保持する `RTCCVPixelBuffer` が pixel buffer を retain するため、pixel buffer の寿命は WebRTC の video source が frame を解放するまで延びる。利用者側で「返した buffer を後から書き換えないこと」と「buffer の寿命を SDK に委ねること」を doc に書く。
- `onRuntimeError` の配送 executor とタイミングは変更しない。配送契約の統一は `0110` で扱う。

### `@unchecked Sendable` の扱い

`ScreenCaptureRecorderCoordinator` (49 行目) と `ScreenCaptureController` (118 行目) の `@unchecked Sendable` は本 issue では除去しない。除去には `settings` / `recorder` / `mediaChannel` の隔離先を決める設計変更が必要で、buffer 所有境界の変更とは独立している。

代わりに、両型について「どの stored property がどの lock / executor に保護されているか」と「不変条件を破る公開経路がないこと」を日本語の型 doc に記載する。記載の粒度は `0103` が `Sora/CameraStateOwner.swift` で確立した方式 (`CameraResourceTable` の型 doc) に揃える。

## スコープ外

- `0105` が扱う MediaStream / VideoFilter の ordered frame processing と `0105` の ingress への最終接続。本 issue は `0105` の確定を待たず、`MediaStream.send(videoFrame:)` を末端とする範囲で完結させる。`0105` が内部 handle を導入した場合は、`ScreenCaptureOwnedFrame` を `0105` の ingress へ接続する変更を `0105` で行う。
- capture ID の不一致による旧 frame 送信は `0097` で修正済み。本 issue は `0097` の不変条件を回帰させないことだけを対象とする。
- `ScreenCaptureController` の `@unchecked Sendable` の除去と、`settings` / `onRuntimeError` / `MediaStream` の executor 契約の統一。`ScreenCaptureSettings` の `Sendable` 化は `0123` が「未起票」と記録しており受け皿が無いため、必要になった時点で別 issue とする (本 issue では扱わない)。
- カメラ経路の `SenderStreamBox` の移送と置き換え。`0103` が「`0105` の完了まで維持する」と確定しており、本 issue では変更しない。
- `MediaStream` / `VideoFrame` への `Sendable` 準拠追加。公開 API の破壊的変更になるため、`0105` の internal handle 方式で扱う。
- `MediaChannel.state` (`Sora/MediaChannel.swift:253`) の同期。`isReadyToSend()` からの非同期読み出しは現行のまま維持する。
- 利用者が返す `CMSampleBuffer` の deep copy と buffer pool の導入。実機で ReplayKit の buffer 再利用や tearing が観測された場合に別 issue とする (本 issue では実測だけを行い、対処はしない)。
- raw WebRTC frame の公開 API からの撤去は `0070` と整合させる (`0070` は libwebrtc_c への移行全体を保持する親 issue であり、Phase 4 で `ScreenCapture.swift` の送信経路も置き換え対象になる。その際に本 issue の `ScreenCaptureOwnedFrame` も `0070` の方式へ追従する)。
- Thread Sanitizer による検証は `0119` の基盤が利用可能になった時点で補助的に行い、`0119` / `0151` が未完了の間は完了条件に含めない。

## 変更対象

- `Sora/ScreenCapture.swift`: `ScreenCaptureOwnedSampleBuffer` / `ScreenCaptureOwnedFrame` の追加、`CaptureContext` と `captureContext()` の削除、`handleSampleBuffer` の内部メソッド (`enqueueOwnedFrame` / `processOwnedFrame` / `performSend`) への分割、queue closure のキャプチャ対象の変更、`activeCaptureID` / `senderStream` の原子的な取得、`tryAcquireSendFlight()` / `drainSendVideoFrameQueue()` / timestamp 読み出しアクセサの internal 追加、`isReadyToSend()` / `shouldSendVideoFrame(presentationTimestamp:)` の internal 化、`ScreenCaptureSettings.videoSampleBufferTransformer` と `ScreenCaptureController` / `ScreenCaptureRecorderCoordinator` の doc コメントの追記
- `Sora/MediaChannel.swift`: `startScreenCapture` の doc コメントに transformer の executor 契約と返却 buffer の所有契約を追記する (シグネチャは変更しない)
- `SoraTests/ScreenCaptureFrameGenerationTests.swift`: 実 `CMSampleBuffer` を生成して `enqueueOwnedFrame` / `processOwnedFrame` / `performSend` へ投入するテストの追加
- `skills/sora-ios-sdk/SKILL.md`: 画面キャプチャ節に transformer の executor 契約と所有契約を追記する
- `CHANGES.md`: `## develop` の `### misc` に refactor として追記
- 変更対象外: `Sora/MediaStream.swift`、`Sora/VideoFrame.swift`、`Sora/VideoMute.swift`、`Sora/CameraVideoCapturer.swift`、`Sora/ScreenCapture.swift` の `captureState` の値遷移と recorder ownership (`0137` の対象)。`captureContext()` の削除に伴い callback 側の frame 破棄条件は semaphore 取得後の signal を追加するが、`captureState` の遷移そのものは変更しない

## テスト方針

モックやスタブは使用しない。

### Simulator (CI の unit test) で実行する

新規の `ScreenCaptureFrameGenerationTests` では `MediaChannel` を接続しないため、`isReadyToSend()` の `.connected` ゲートは通らない。`performSend` は `.connected` を判定しないので queue 上の処理は駆動でき、`.connected` ゲート自体は本 issue で変更しない既存挙動として実機で確認する。

- `CMVideoFormatDescriptionCreateForImageBuffer` と `CMSampleBufferCreateReadyWithImageBuffer` で image buffer を持つ実 `CMSampleBuffer` を生成し、internal 化した `performSend(ownedFrame:)` へ投入する。`ScreenCaptureOwnedSampleBuffer` はその実 buffer から生成する。
- transformer が未設定 (既定の `ScreenCaptureSettings()`)、元の buffer を返す、別の buffer を返す、nil を返す各経路を実 buffer で検証する。transformer 未設定では frame が破棄されず送信され、nil を返した場合だけ破棄されることを、`VideoFilter` の到達回数と transformer の呼び出し回数で区別して確認する。
- image buffer を持たない `CMSampleBufferCreate` の buffer を投入し、`VideoFrame(from:)` の生成失敗経路で送信 timestamp が更新されないこと (internal なアクセサで確認) と semaphore が回復することを確認する。
- `targetFPS` による間引きで破棄される frame では、`enqueueOwnedFrame` が `false` を返して enqueue されず、`drainSendVideoFrameQueue()` 後も transformer が実行されないことを確認する。
- `tryAcquireSendFlight()` で permit を保持したまま `enqueueOwnedFrame` を呼び、即時取得に失敗した frame が enqueue されないこと (`false` が返る) を確認する。保持した permit は別の internal な解放メソッドで返す。
- `beginStartCapture` で capture A を開始し `completeStartCapture(captureID:error: nil)` で `.running` にした後、`stopCapture()` を `await` して停止を確定させる。停止後は `enqueueOwnedFrame` が `captureState` の述語で `false` を返すことを確認する。世代照合そのものは、capture A の `ScreenCaptureOwnedFrame` を `performSend` へ投入して送信されないことと、現在の capture の frame は送信されることの対比で確認する (`0097` の回帰確認)。停止の確定を待ってから投入し、`send` が lock 外であることによる非決定性を持ち込まない。
- `isReadyToSend()` が `mediaChannel.state == .disconnected` のときに `false` を返すことを確認する。
- semaphore の回復は、早期 return となる frame (capture state 不一致 / transformer の nil / `VideoFrame` 生成失敗 / capture ID 不一致) を処理した直後に `performSend` が `true` を返し、次に送信される frame が `VideoFilter` へ到達することで確認する。
- テストには、どの時点で sample buffer の所有表現へ移すか (callback でのコピー生成、queue 上での変換、送信確定後の timestamp 更新) を日本語コメントで明記する。

### 実機で手動確認する (CI では未検証として区別する)

- 実 ReplayKit から受け取った sample buffer を transformer、変換、送信まで処理する。
- 連続キャプチャ時のメモリ使用量 (Instruments Allocations) と frame latency を計測し、`CMSampleBufferCreateCopy` の影響を記録する。合否基準は設けない。
- ReplayKit が渡した buffer の再利用と、それによる画素データの tearing が発生しないことを確認する。発生した場合の deep copy 化は別 issue とする。
- `MediaChannel` を実接続して画面共有を開始し、`.connected` のゲートと実 ReplayKit の frame 送信を確認する。Simulator では動作しないため実機のみとする。
- Thread Sanitizer は `0119` の基盤が利用可能になるまで完了条件に含めない (`0105` と同じ扱い)。
- 実 ReplayKit は Simulator で動作しないため、上記は実機で確認し、未検証項目として区別する。

## 完了条件

- ReplayKit callback が `sendVideoFrameQueue` へ渡す値が `ScreenCaptureOwnedFrame` だけであり、OS が渡した `CMSampleBuffer` の参照が queue closure にキャプチャされていないこと。`CaptureContext` は削除されていること。
- `sendVideoFrameQueue` の closure がキャプチャまたは直接参照する値が `ScreenCaptureOwnedFrame` payload と `self` だけで、`sampleBuffer` と `CaptureContext` を参照していないこと。
- raw `MediaStream` を移送する box (`SenderStreamBox` と同種のもの) を新設していないこと。新設した `@unchecked Sendable` 型は `ScreenCaptureOwnedSampleBuffer` と `ScreenCaptureOwnedFrame` の 2 つだけで、それぞれの安全性の根拠が型 doc に記載され、その根拠が「Create ルールの所有権」と「1 回の所有権移動」に限定されていること。
- queue 上で `activeCaptureID` と `senderStream` を取得し、payload の `captureID` と比較していること。停止後は `activeCaptureID` が `nil` のため送信されず、stop → restart 後は世代が一致しないため旧世代の frame が送信されないこと (テストで検証する)。
- `isReadyToSend` / transformer / `VideoFrame` 生成 / capture ID 照合 / `markVideoFrameSent` / `send` の順序が現行から変わっていないこと。`activeCaptureID` と `senderStream` は queue 上で 1 つの lock 区間で取得していること。
- transformer 未設定では元の buffer が送信され、transformer が nil を返した場合と `VideoFrame` の生成に失敗した場合には送信 timestamp が更新されず `sendVideoFrameSemaphore` が signal されること。
- `targetFPS` による間引き、semaphore の即時取得失敗、`captureState != .running` の各経路で、`enqueueOwnedFrame` が `false` を返して enqueue せず、queue 側の transformer が実行されないこと。queue 側の transformer は capture ID 照合より前に実行される (現行と同じ順序) ため、旧世代の frame で transformer が呼ばれること自体は現行どおり許容し、送信されないことだけを確認する。
- 世代照合を通過しなかった frame が throttle 状態を更新せず、`0097` の「再開後の先頭フレームが targetFPS で間引かれない」挙動が維持されていること (テストで検証する)。
- `ScreenCaptureSettings.videoSampleBufferTransformer` と `MediaChannel.startScreenCapture` の doc コメントに、呼び出し executor と返した `CMSampleBuffer` の所有契約が明記されていること。
- `skills/sora-ios-sdk/SKILL.md` の画面キャプチャ節に、transformer の呼び出し executor と所有契約が記載されていること。
- `ScreenCaptureController` と `ScreenCaptureRecorderCoordinator` の型 doc に、stored property ごとの保護方法と不変条件が記載されていること。
- `CMSampleBuffer` / `CVPixelBuffer` を deep copy していないこと。`CMSampleBufferCreateCopy` の浅いコピーで queue へ所有権を移していること。
- `CHANGES.md` の `## develop` に `### misc` の追記があること。
- `Sora/ScreenCapture.swift` の `#SendableClosureCaptures` warning が解消されていること。Dispatch の closure は暗黙の `@preconcurrency @Sendable` のため warning に留まる。warning の解消だけで完了とせず、queue closure がキャプチャする型による強制 (上記 1・2 番目) を完了条件の根拠とする。
- 追加したテストと既存テストがすべて成功すること。`.connected` ゲートと実 ReplayKit の frame 送信は実機で確認し、未検証項目として区別されていること。

## 検証手段

- queue closure のキャプチャ: `git diff` で `sendVideoFrameQueue.async` の closure が参照するのが `ScreenCaptureOwnedFrame` と弱参照の `self` だけであり、`captureContext` と `sampleBuffer` への参照が無いことを確認する。
- `#SendableClosureCaptures` warning: `SWIFT_VERSION=6` でビルドし、`Sora/ScreenCapture.swift` に該当 warning が出ないことを確認する。
- 世代照合: `scheduleStopCapture` の `activeCaptureID = nil` / `senderStream = nil` (370-373 行目) と queue 側の取得が同一 lock 区間であることをコードで確認し、テストで旧 capture の frame が送信されないことを検証する。
- transformer 未設定の既定経路: `ScreenCaptureSettings()` を使うテストで `VideoFilter` への到達回数が 1 以上であることを確認する。
- queue 上の処理の駆動: テストは `beginStartCapture` + `completeStartCapture(captureID:error: nil)` で `.running` にし、`performSend` を直接呼ぶ。`performSend` が `.connected` を判定しないことをコードで確認する。
- semaphore の会計: `tryAcquireSendFlight()` / `processOwnedFrame` の signal / `drainSendVideoFrameQueue()` の wait が同じ permit に対して 1 回ずつ対応していることをコードで確認する。
- ドキュメント: `git diff` で `ScreenCaptureSettings` / `MediaChannel.startScreenCapture` / `ScreenCaptureController` / `ScreenCaptureRecorderCoordinator` の日本語 doc と `skills/sora-ios-sdk/SKILL.md` の画面キャプチャ節を確認する。

## 解決方法
