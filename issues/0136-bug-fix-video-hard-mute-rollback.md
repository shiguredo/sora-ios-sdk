# setVideoHardMute(true) の失敗時に videoEnabled を復元する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/fix-video-hard-mute-rollback
- Polished: 2026-09-16

## 目的

`MediaChannel.setVideoHardMute(true)` が失敗した場合に、その呼び出しが設定した黒塗り (ソフトミュート) 状態を呼び出し前の値へ戻す。呼び出し前から黒塗りだった場合 (ソフトミュート済み) は黒塗りのまま維持する。あわせて、所有権を取得できずに拒否された呼び出しが `videoEnabled` を変更しないようにする。

## 優先度根拠

- エラーが利用者へ返るにもかかわらず映像が黒塗りのまま残り、`setVideoHardMute(false)` の再試行などで復旧するまで黒塗りが続く。利用者が観測できる不整合であるため Medium とする。
- クラッシュやデータ破壊ではなく、修正後は失敗時に自動で復元されるため High ではない。

## 現状

- `Sora/MediaChannel.swift` の `setVideoHardMute(true)` は `senderStream.videoEnabled = false` を設定した後に `VideoHardMuteActor.setMute(mute: true, ...)` を await する。throw した場合に `videoEnabled` を呼び出し前の値へ戻す処理がないため、呼び出し前に有効だった映像が黒塗りのまま残る。
- `mute = true` 経路で throw するのは、`operationTracker.begin` の拒否 (`"video hard mute operation is in progress"` / `"video hard mute operation was cancelled"`)、設定後の所有権不一致 (`"camera is owned by another connection"`)、カメラ停止の直前・直後の取消 (`"video hard mute operation was cancelled"`) である。
- `MediaChannel.videoHardMuteActor` は全接続で共有する `static let` であり、`VideoHardMuteOperationTracker` は `activeLease` を 1 つだけ持つ。`operationTracker.begin` は lease を問わず `activeLease == nil` を要求するため、`"video hard mute operation is in progress"` は別接続の操作中でも発生する。
- `videoEnabled = false` の設定が `VideoHardMuteActor` の直列化区間の外にあるため、`"video hard mute operation is in progress"` で拒否される呼び出しも `videoEnabled` を変更する。
- `VideoHardMuteLease.revoke()` は接続終了経路 (`prepareForDisconnect` / `deinit` と、そこから呼ばれる `VideoHardMuteOperationTracker.revokeAndWaitForCompletion`) からのみ呼ばれる。
- `mute = false` の経路には `videoSourceCoordinator.cancelCamera` による予約取消のロールバックがあるが、`mute = true` の経路には `videoEnabled` の復元がない。
- `senderStream.videoEnabled` の setter は値が変化し、かつ映像トラックが存在するときだけ利用者 handler (`MediaStreamHandlers.onSwitchVideo`) と `videoRenderer?.onSwitch(video:)` を呼ぶ。後者は `VideoView.autoStop()` を経由する。
- `SoraTests/` に `MediaChannel.setVideoHardMute` を呼ぶテストは存在しない。既存の `SoraTests/VideoHardMuteActorLeaseTests.swift` は `VideoHardMuteActor` を直接検証しており、`MediaChannel.setVideoHardMute` の `videoEnabled` 復元は対象外である。

## 設計方針

### videoEnabled の設定と復元の配置

- `videoEnabled` の設定と復元の実体を `VideoHardMuteActor.setMute(mute: true, ...)` へ移す。`MediaChannel.setVideoHardMute(true)` からは設定を削除し、doc コメントの更新だけを行う。
- `try operationTracker.begin(lease:)`、`defer { operationTracker.finish(lease: lease) }`、最初の `try checkNotRevoked(lease: lease)` は現行の順序のまま変更しない。この 3 行は `do` の外に置く。
- `let storedCapturer = storedCapturers[lease]` の後、`if mute {` の先頭で `let previousVideoEnabled = senderStream.stream.videoEnabled` を読み、続けて `senderStream.stream.videoEnabled = false` を設定する。`currentCameraVideoCapturer()` はこの設定より後である。
- この配置では、`currentCameraVideoCapturer()` の後の所有権 guard、`stopCameraVideoCapture` 内の所有権 guard、カメラ停止の直前・直後の `checkNotRevoked` がすべて設定より後になる。設定より前の拒否は `operationTracker.begin` と最初の `checkNotRevoked` の 2 つである。
- `operationTracker.begin` が `"video hard mute operation is in progress"` または `"video hard mute operation was cancelled"` で throw した場合は、`videoEnabled` を設定せずに throw する。設定前なので復元も不要であり、拒否された呼び出しは進行中の成功操作の値も利用者 handler の発火も変えない。
- 設定位置を `operationTracker.begin` より後にする理由は、所有権を取得できなかった呼び出しが `videoEnabled` に触れないことを構造的に保証するためである。
- 設定を `operationTracker.begin` より前に置き、失敗時に復元する案は採用しない。取消済み lease では復元の要否が接続終了の有無に依存し、復元する場合は切断中に `onSwitchVideo(true)` を発火させ、復元しない場合は拒否された呼び出しが黒塗りを残すためである。
- 設定位置を `currentCameraVideoCapturer()` の guard より前にする理由は、カメラ未起動で `setMute` が冪等成功する場合も現行どおり `videoEnabled` を false にする必要があるためである。
- `MediaChannel` 側の局所修正 (呼び出し前の値の退避と失敗時復元) は採用しない。退避と設定が `await` をまたがない 2 操作になるため、同時呼び出しで割り込み、拒否された呼び出しが進行中の成功操作の値を上書きし得るためである。`operationTracker.begin` のエラーメッセージで復元要否を分岐する案も、メッセージ文字列への依存を招くため採用しない。

### 復元の条件と同期順序

- `if mute` ブロックの残り全体を `do { ... } catch { ... }` で囲む。設定より後に throw した場合は、`catch` で `lease.isValid` が true のときだけ `previousVideoEnabled` へ復元してから throw する。`mute = false` の分岐は `do` / `catch` の対象外とする。
- 復元の判定は `lease.isValid` だけで行う。`"video hard mute operation was cancelled"` は `lease.isValid` が false になる代表例だが唯一の例ではない。`await` 中に `prepareForDisconnect` が `revoke()` した場合、所有権不一致のエラーでも `lease.isValid` は false になる。エラー種別では分岐しない。
- 設定後に throw し、かつ `lease.isValid` が true になり得るのは所有権不一致の 2 経路 (`currentCameraVideoCapturer()` の後の guard と `stopCameraVideoCapture` 内の guard) である。別接続がカメラを引き継いでもこの接続の `VideoHardMuteLease` は revoke されないため、取消以外の所有権不一致では復元が実行される。
- `lease.isValid` が false のときは復元しない。接続終了中は、カメラが停止済みか quarantine 中かによらず、利用者へ「映像有効」を通知しても回復できないためである。
- `previousVideoEnabled` は `setMute` が実行を開始した時点 (actor の直列化区間へ入った時点) の値である。利用者が `setVideoHardMute` を呼ぶ直前の値と厳密に一致する保証はない。
- 復元は `operationTracker.finish(lease:)` より前に完了させる。`defer { operationTracker.finish(lease:) }` は `operationTracker.begin` の成功直後に置き、復元する `catch` はその `defer` と同じスコープに置く。`defer` を内側の `do` ブロックへ入れると、その `do` ブロックの終了時に `finish` が先に実行される。`catch` 内で `finish` を呼ばない (`defer` が 1 回だけ呼ぶ)。
- `lease.isValid` の判定と `videoEnabled` の書き込みは `VideoHardMuteLease` の同一ロック区間ではない。判定直後に別スレッドの `prepareForDisconnect` が `revoke()` する狭い窓では、切断中でも復元が実行され得る。復元は best-effort であり、この窓を閉じる原子化は本 issue では行わない。
- カメラ未起動で `setMute` が冪等成功する場合は復元しない (成功のため)。この経路でも `videoEnabled` は false になる。
- 早期検証 (`requireSenderStreamForVideoMute` と `cameraSettings.isEnabled`) は `setMute` の呼び出し前に throw するため、`videoEnabled` は変更されず復元も不要である。

### doc コメントに記載する条件

- `Sora/MediaChannel.swift` の `setVideoHardMute` の doc コメントへ次の旨を追記する。
  - 設定後に失敗した場合は呼び出し前の `senderStream.videoEnabled` を復元する。ただし接続終了中 (`lease` が無効) の失敗では復元せず、黒塗り (ソフトミュート) のまま終了する。
  - 設定前の拒否 (「操作が実行中」「取消」) では `videoEnabled` を変更しない。
  - 呼び出し前が true の場合、成功時は `onSwitchVideo(false)` が 1 回、復元する失敗時は `onSwitchVideo(false)` と `onSwitchVideo(true)` がこの順に 1 回ずつ (合計 2 回) 発火する。呼び出し前が false の場合は設定も復元も発火しない。
- `Sora/VideoMute.swift` の `VideoHardMuteActor.setMute` の doc コメントに、`SenderStreamBox.stream` の `videoEnabled` を変更することと、失敗時に `lease.isValid` のときだけ復元してから throw することを追記する。

### 境界と後方互換

- `senderStream.stream.videoEnabled` の setter は actor 内で実行するため、`handlers.onSwitchVideo` と `videoRenderer?.onSwitch` の実行 executor が `VideoHardMuteActor` の executor になる。呼び出し側の executor で発火していた場合とは異なるため、`MediaStreamHandlers.onSwitchVideo` の doc に実行 executor を明記する。
- `videoRenderer?.onSwitch(video:)` は `VideoView.autoStop()` を経由して `isRendering` を排他なしで書き換える。executor が変わることによる `isRendering` 更新の競合は自動テストで検出できないため、本変更が新たな危険を増やさないことをコードレビューで確認し、恒久的な main thread 前提の整理は `0027` の対象とする。
- setter は actor が `operationTracker` の lease を保持している区間でも実行される。callback から `setVideoHardMute` を再入するには `await` が必要なため、設定直後の再入は `"video hard mute operation is in progress"` で拒否される。
- `VideoHardMuteActor` は `SenderStreamBox: @unchecked Sendable` 経由で非 Sendable な `MediaStream` を受け取る。actor 境界の受け渡し方法は変えず、`videoEnabled` の書き込みは actor の executor 上で行う。
- `mute = false` の成功経路の `videoEnabled = true` (`Sora/MediaChannel.swift` の `setVideoHardMute` 内) は位置を変えない。このため `mute = true` の callback は `VideoHardMuteActor` の executor、`mute = false` の成功時の callback は呼び出し側の executor で発火する。`mute = false` 側の直列化は本 issue の対象外である。公開 API のシグネチャは変えない。

## スコープ外

- `0028` が扱う `VideoHardMuteActor` の `storedCapturers` のクリア意味論は扱わない。本 issue は `setMute` の `mute = true` 分岐、`0028` は `mute = false` 分岐を変更するため実施順序の依存はないが、同一ファイルのため実装時は変更範囲が重ならないことを確認する。
- `0103` が扱う camera state owner への集約、`VideoHardMuteLease` の ID 化、`CameraStartAuthorization` の写像、`VideoHardMuteActor` のシグネチャ変更は扱わない。`operationTracker` / `VideoHardMuteLease` / `CameraStartAuthorization` の意味論とシグネチャは変更しない。
- `mute = false` の `videoEnabled = true` と、`setVideoHardMute(false)` / `setVideoHardMute(true)` の同時実行時の競合は扱わない。`mute = false` 側の直列化は本 issue の対象外である。
- `setVideoSoftMute` (`Sora/MediaChannel.swift`) と `MediaStream.videoEnabled` への直接代入は `VideoHardMuteActor` で直列化されない。`setVideoHardMute` の実行中にこれらが同じ stream へ書き込む競合は扱わない。復元は、その間に利用者が変更した値を上書きし得る。actor が保証するのは `setVideoHardMute` 呼び出し間の排他だけである。
- 設定後・カメラ未起動の `currentCameraVideoCapturer()` 待機中に取消された場合は、nil の早期 return により冪等成功として戻る (現行挙動)。`videoEnabled` は false のままとなるが、接続終了中のため対象外とする。
- `mute = true` 失敗時に `videoSourceCoordinator.releaseCamera()` を呼ぶかは変更しない (現行どおり成功時のみ)。復元後もカメラは動作継続または quarantine 中であり、予約だけを解放すると予約と実際のカメラ状態が一致しなくなるためである。

## 再現手順

- 前提: `role = .sendonly`、`videoEnabled = true` (既定)、`cameraSettings.isEnabled = true` (既定)、`initialCameraEnabled = false`、`audioEnabled = false`、sender stream と video track が存在すること。
- テスト所有の `VideoHardMuteLease` を `MediaChannel(configuration:videoHardMuteLease:)` へ渡して `MediaChannel` を直接生成し、`connect` で実 Sora サーバへ接続する。`Sora.connect` は lease を注入できないため使用しない。
- `lease.revoke()` を呼んだ後に `setVideoHardMute(true)` を呼ぶと、`VideoHardMuteActor` の `operationTracker.begin` が取消により throw する。
- 現行実装では先に `videoEnabled = false` を設定するため、throw 後も `senderStream.videoEnabled` が false のまま残る。修正後は `videoEnabled` に触れないため呼び出し前の値のままとなる。
- この再現は所有権取得前の拒否であり復元処理を通らない。

## テスト方針

モックやスタブは使用しない。

- 追加するテストには、`await` をまたぐ `videoEnabled` の書き込みを直列化区間の外に置くと、拒否された呼び出しが進行中の成功操作の値を上書きする理由を日本語コメントで明記する。

### VideoHardMuteActor の単体テスト (`SoraTests/VideoHardMuteActorLeaseTests.swift` へ追加)

- 専用ヘルパを追加し、`peerChannel.nativePeerChannelFactory.createNativeSenderStream(streamId: "test", videoTrackId: "video", audioTrackId: nil, constraints: MediaConstraints())` で video track 付きの native stream を作り、`BasicMediaStream(peerChannel:nativeStream:)` で包む。既存の `makeDependencies()` は video track を持たないため流用しない。
- 検証前に `XCTAssertTrue(stream.videoEnabled, "video track は既定で有効であること")` を置き、前提が崩れたときにテストが空虚化せず失敗するようにする。
- `VideoHardMuteActor(operationTracker:)` を直接生成し、次の 2 条件で `videoEnabled` が true のまま変化しないことを検証する。どちらも実カメラも実サーバも必要とせず Simulator で実行できる。
  - `"video hard mute operation is in progress"`: 占有用と `setMute` 用に別の `VideoHardMuteLease` を使う。占有用 lease を `revoke()` せずに `operationTracker.begin(lease:)` を先に呼び、`setMute` を呼ぶ前に占有を解放しない。検証後は `operationTracker.finish(lease: 占有 lease)` を呼ぶ。throw した reason に `in progress` が含まれることを検証する。
  - `"video hard mute operation was cancelled"`: `setMute` に渡す lease を `revoke()` してから `setMute` を呼ぶ。
- この単体テストは `operationTracker.begin` の拒否 (設定前) を検証する回帰ガードであり、復元分岐は通らない。現行コード (設定が `MediaChannel` 側) でも失敗しないため、実バグの検出は E2E テストが担う。
- クラス doc コメントに、`operationTracker.begin` が throw する経路で `videoEnabled` が変更されないことも検証する旨を追記する。

### E2E テスト (`SoraTests/VideoHardMuteRollbackE2ETests.swift` を新規作成)

- `E2ETestBase` を継承し、`var config = try buildConfiguration(role: .sendonly)`、`config.channelId = buildChannelId(unique: true)`、`config.initialCameraEnabled = false`、`config.audioEnabled = false` とする。
- `let channel = try MediaChannel(configuration: config, videoHardMuteLease: lease)` を生成し、テストメソッドを `async throws` にして `channel.connect(webRTCConfiguration: WebRTCConfiguration()) { error in ... }` の完了を `await fulfillment(of: [connected], timeout: 30)` で待つ。
- `connect` の完了 handler は SignalingChannel の専用 queue 上で呼ばれ、MainActor 上ではない。接続結果の記録は `DispatchQueue.main.async` を挟んでから行う。
- 接続結果として `error == nil`、`channel.state == .connected`、`channel.senderStream != nil` を検証する。あわせて `config.cameraSettings.isEnabled` と `config.videoEnabled` を検証し、前提が崩れた場合は `XCTFail` のうえ後始末をして早期 return する。接続失敗と検証対象の assertion 失敗を切り分けるためである。
- 検証前に `XCTAssertTrue(stream.videoEnabled, "video track は既定で有効であること")` と `XCTAssertTrue(stream.hasVideoTrack)` を置く。
- `stream.handlers.onSwitchVideo` に発火値の配列を記録するクロージャを設定する。handler は `await setVideoHardMute` の完了前に同期で発火するため、closure 内で直接配列へ追加し (`DispatchQueue.main.async` を挟まない)、`await` の戻り直後に配列を読む。接続完了後に handler を設定するため、設定前の発火は記録されない。
- 取消経路: `lease.revoke()` の後に `setVideoHardMute(true)` を呼ぶ。throw は `do` / `catch let error as SoraError` で捕捉し、`case .mediaChannelError(let reason)` の `reason` に `"cancelled"` が含まれることを検証し、throw しなかった場合は `XCTFail` にする。あわせて `senderStream.videoEnabled` が変更されないこと、`onSwitchVideo` の記録配列が空であることを検証する。これは `operationTracker.begin` による設定前の拒否であり、設定後の取消 (`checkNotRevoked`) とは別事象である。
- 成功経路: lease を revoke せずに `setVideoHardMute(true)` を呼ぶ。throw は握りつぶさず、throw した場合はテストを失敗させる。カメラ未起動のため冪等成功して `senderStream.videoEnabled` が false になることと、`onSwitchVideo` が `[false]` の 1 回だけ発火することを検証する。lease は一度 revoke すると戻せないため、取消経路とは別のテストメソッドにする。この経路は `CameraVideoCapturer.current` が nil であることを前提とする。テスト冒頭で `CameraVideoCapturer.current` を確認し、非 nil なら `XCTSkip` するか、テスト間で実カメラを起動しない。
- `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` 未設定時は XCTSkip とする。
- 直接生成した `MediaChannel` は `sora.mediaChannels` に登録されないため `E2ETestBase.tearDown` では切断されない。`addTeardownBlock` で `state != .disconnected` のときだけ `onDisconnect` を設定して `channel.disconnect(error: nil)` を呼び、`await fulfillment(of:timeout: 10)` で待つ。前提 assertion で早期 return した場合も後始末が走るようにする。`E2ETestBase.disconnectAndVerify` は正常切断コードを検証して handler を上書きするため、本テストでは使わない。

### 実機で確認する項目

- 別接続がカメラを所有している場合の復元: 実機で 2 つの `MediaChannel` を接続し、一方を `initialCameraEnabled = true`、もう一方を `false` にして後者から `setVideoHardMute(true)` を呼ぶ。`"camera is owned by another connection"` の throw 後に `senderStream.videoEnabled` が呼び出し前の値へ戻り、`onSwitchVideo` が false → true の順に発火することを確認する。

### 現状の seam では検証できない項目

- 復元分岐に到達する失敗は、設定後の所有権不一致 (`currentCameraVideoCapturer()` 後の guard と `stopCameraVideoCapture` 内の guard) である。いずれも起動済みの `CameraVideoCapturer.current` を必要とし、Simulator では `current` が nil のため `currentCameraVideoCapturer()` の早期 return で復元分岐に到達しない。
- 設定後に取消 (`checkNotRevoked`) による復元しない分岐は、カメラ停止完了のタイミングに `revoke()` を差し込む決定的な手順がないため未検証とする。
- 復元分岐を通る自動テストは存在しない。復元そのものは実機確認のみで、完了条件でも CI 対象外として区別する。

## 変更対象

- `Sora/VideoMute.swift`: `mute = true` 分岐で `if mute {` の先頭に `videoEnabled` の退避と設定を移し、`if mute` ブロックの残りを `do` / `catch` で囲んで `lease.isValid` のときだけ復元する。`setMute` の doc コメントを更新する。
- `Sora/MediaChannel.swift`: `setVideoHardMute(true)` から `videoEnabled = false` の設定と、それに対応する順序コメントを削除する。`setVideoHardMute` の doc コメントに復元条件を追記する。
- `Sora/MediaStream.swift`: `MediaStreamHandlers.onSwitchVideo` の doc に、`setVideoHardMute` 経由では `VideoHardMuteActor` の executor で発火し、`setVideoSoftMute` と `videoEnabled` への直接代入では呼び出し側で発火することを追記する。
- `SoraTests/VideoHardMuteActorLeaseTests.swift`: 拒否された操作が `videoEnabled` を変更しないことを検証するテストとクラス doc の更新
- `SoraTests/VideoHardMuteRollbackE2ETests.swift` (新規): 取消経路と成功経路を検証する E2E テスト
- `CHANGES.md`: `## develop` の `### misc` より前 (種別順) の `[FIX]` 群の末尾へ追記する

## 完了条件

- `operationTracker.begin` が `"video hard mute operation is in progress"` または `"video hard mute operation was cancelled"` で throw した場合、`senderStream.videoEnabled` が変化せず、`onSwitchVideo` が発火しない。単体テスト (in progress / cancelled) と E2E (cancelled) で検証する (Simulator)。
- カメラ未起動で `setMute` が冪等成功する経路でも、`setVideoHardMute(true)` 成功後の `videoEnabled` が false になり、`onSwitchVideo` が `[false]` の 1 回発火する。E2E で検証する (Simulator)。
- `setVideoHardMute(true)` の成功時の `videoEnabled` の値と callback の発火回数を変えない。callback の実行 executor は `VideoHardMuteActor` の executor に変わる。
- 設定後に lease が有効なまま失敗した場合、`senderStream.videoEnabled` が呼び出し前の値に戻り、`onSwitchVideo` が false → true の順に発火する。復元分岐を通る自動テストはないため、実機で確認する (CI 対象外)。
- 設定後に `lease` が無効になっている失敗では `videoEnabled` を復元せず、`onSwitchVideo(true)` を発火しない。検証手段がないため未検証として区別する。
- `setVideoHardMute` の doc コメントに、復元条件 (`lease.isValid` のみで分岐し、エラー種別では分岐しない)、接続終了中は復元しないこと、設定前の拒否では変更しないことが書かれている。`MediaStreamHandlers.onSwitchVideo` の doc に executor が書かれている。
- 設定前の拒否 (`"video hard mute operation is in progress"` / `"video hard mute operation was cancelled"`) および早期検証の失敗では、`videoSourceCoordinator.releaseCamera()` が呼ばれない (成功時のみ呼ばれる)。
- 拒否された操作が `videoEnabled` を変更しないことを検証するテストを追加すること。
- `CHANGES.md` の `## develop` の `### misc` より前の `[FIX]` 群の末尾に次を追記すること。
  - 内容行: `- [FIX] MediaChannel.setVideoHardMute(true) の失敗時に videoEnabled を呼び出し前の値へ復元する`
  - 次の行に補足: `  - setVideoHardMute 経由の onSwitchVideo は VideoHardMuteActor の executor で発火する`
  - 最後に担当者行 (`  - @ユーザー名`) を置く。
- 追加したテストと既存テストがすべて成功すること。

## 関連 issue

- `0098`: `"camera is owned by another connection"` / `"video hard mute operation was cancelled"` の throw 経路を導入した。
- `0028`: 同じ `VideoHardMuteActor.setMute` の `mute = false` 経路 (`storedCapturers` のクリアと解除失敗時の保持) を扱う。
- `0103`: camera state owner を導入する refactor。本 issue を前提 issue としており、`VideoHardMuteActor` の `videoEnabled` の扱いは本 issue で確定させて引き継ぐ。
- `0142` / `0143`: `0103` は `0136` / `0142` / `0143` が `Sora/CameraVideoCapturer.swift` / `Sora/VideoMute.swift` の同一経路を変更するとして 3 つを前提 issue に挙げている。
- `0105`: `MediaStream` の `videoEnabled` / `audioEnabled` の変更を stream 単位の executor へ集約する計画。本 issue は `videoEnabled` の書き込み 1 つを `VideoHardMuteActor` の executor へ移す限定変更であり、callback の executor と順序の全体設計は `0105` が扱う。

## 解決方法
