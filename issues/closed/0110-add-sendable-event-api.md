# executor 契約を持つ Sendable event API を追加する

- Created: 2026-08-27
- Completed: 2026-10-07
- Branch: feature/add-sendable-event-api
- Polished: 2026-10-07
- Updated: 2026-10-07

## 目的

接続・切断、シグナリング、DataChannel、stream のイベント (映像・音声の有効フラグ変更)、audio session のイベントを、Swift 6 の actor / Task から安全に購読できる、executor 契約付きの Sendable event API を追加する。

既存の mutable handler bag と callback API を維持しながら、新しい API では payload lifetime、配送順序、reentrancy、配送 executor を明示する。

## 現状

次の公開 handler 型は、mutable な optional closure property を保持する class として実装されている。

- `Sora/Sora.swift` の `SoraHandlers`
- `Sora/MediaChannel.swift` の `MediaChannelHandlers`
- `Sora/WebSocketChannel.swift` の `WebSocketChannelHandlers`
- `Sora/MediaStream.swift` の `MediaStreamHandlers`
- `Sora/CameraVideoCapturer.swift` の `CameraVideoCapturerHandlers`

closure に `@Sendable` 制約はない。handler property の読み書きの排他は `0154` (完了 2026-10-02) が `Sora/HandlerStorage.swift` の `HandlerStorage` として実装し、`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` に適用済みである (`SoraHandlers` の排他は `0111` が扱う)。callback の executor や順序などの契約は下記のとおり整備されていない。

呼び出し executor またはスレッドの説明は一部の callback にしかなく、同じ handler bag 内でも次が統一されていない。説明があるのは `MediaChannelHandlers.onDataChannel` / `onDataChannelOpened` のスレッド非保証の注記と `MediaStreamHandlers.onSwitchVideo` の executor 注記などである。

- callback が呼ばれる executor
- callback 間の順序
- callback 中に同期 API を再入できるか
- payload が callback 終了後も利用可能か
- 接続開始後に handler を変更した場合の反映時点

payload には `MediaChannel`、`MediaStream`、`RTCAudioSession`、Signaling object などの mutable reference と raw WebRTC 型が含まれる。既存 closure に直接 `@Sendable` を追加すると、利用者の non-Sendable capture が compile error になる。

## 前提となる issue

- `0100` (完了 2026-09-08): PeerChannel の接続状態フラグの reducer と state snapshot
- `0101` (完了 2026-09-15): signaling event の ordered ingress
- `0102` (完了 2026-09-16): mutable handler bag と設定 snapshot の分離
- `0105` (完了 2026-09-18): stream frame event の順序保証 (ingress の整理と renderer callback の main queue 配送)
- `0163` (完了 2026-10-01): `videoEnabled` / `audioEnabled` の変更の operation 単位の直列化 (stream の有効フラグ event の入力源)
- `0107` (完了 2026-09-24): 外部 consumer package

接続イベントの ordered ingress は、`0010` の `connectionLifecycleLock` (MediaChannel の接続ライフサイクル)、`0100` の `ConnectionStateOwner` (PeerChannel の接続状態フラグ)、`0101` の `SignalingStateOwner` (signaling の phase / URL と delegate callback) が分担する。新 event API の ordered event stream は、この現行実装を入力源とする。

## 設計方針

### event model

- core event を表す public の Sendable enum / struct を追加する。
- payload は connection ID、stream ID、label、immutable state snapshot、`Data`、Sendable error snapshot などに限定する。
- `MediaChannel`、`MediaStream`、raw WebRTC object を event payload として直接渡さない。
- event に論理接続 ID、transport epoch、必要な sequence を含め、stale event を識別できるようにする。
- event 種別は `0035` などの後続作業で追加できる構造にする。利用者側の網羅 switch が壊れない形 (後から event 種別を追加しても利用者の既存コードが compile できなくなる public enum の case 列挙にしない) にする。

### 購読 API

- `AsyncStream` / `AsyncThrowingStream` または明示的な executor と `@Sendable` closure を受け取る購読 API を提供する。
- 複数購読者を許可するか、1 接続 1 stream とするかを API 契約で決める。複数購読者を許可する場合は、購読者ごとに独立した buffer / drop 方針 / 終端を提供し、1 購読者の解除が他の購読者へ影響しないこと。1 接続 1 stream とする場合は、その stream の buffer / drop 方針 / 解除 / 終端の意味を定めること。
- buffer size、overflow 時の drop 方針、購読解除、接続終了時の stream 終端を明示する。
- continuation と購読 state は、`0010` / `0100` / `0101` の ordered ingress と同じ接続単位の owner が管理し、購読者の Task cancellation で確実に解除する。

### executor と順序

- network / connection event は接続単位の ordered event stream から配送する。
- UIKit renderer と UI 専用 event だけを `@MainActor` にする。一般 event を一律 MainActor へ変更しない。
- 利用者 handler は owner の critical section 外で実行する。
- event handler から同期 getter、send、disconnect を呼べるかを明記し、許可する操作では deadlock しないことを保証する。

### legacy handler

- 既存 handler class と property の型は変更しない (`@Sendable` も付けない)。`0102` のスコープ外には handler の `@Sendable` 化を `0110` が扱う旨が書かれているが、これは legacy handler の closure 型を変更せず、Sendable な購読は新 event API で提供するという本 issue の方針を指す。`0154` / `0118` も同じ前提で実装している。
- 既存 handler は内部 event を compatibility adapter から配送する。配送のたびに bag を読み、接続途中の設定が次の配送から反映される既存の配送セマンティクスを維持する。
- compatibility adapter は現行の配送点で呼び、legacy callback の配送 executor は現行のまま維持する (`0105` が `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` の executor を変更しない方針を定め、`onSwitchVideo` の executor を doc 化している)。executor または配送セマンティクスを変更する場合は、変更点を各 handler bag の doc と `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節に記載し、`CHANGES.md` の `[CHANGE]` とする。
- 接続開始時に handler snapshot を取る場合は、開始後の差し替えが反映されるかどうかを既存挙動と照合して明文化する。
- legacy handler bag (`SoraHandlers` / `MediaChannelHandlers` / `WebSocketChannelHandlers` / `MediaStreamHandlers` / `CameraVideoCapturerHandlers`) の doc に、callback の配送 executor / スレッドの契約を明記する。少なくとも「呼び出しスレッドは保証されない」ことと、Swift 6 言語モードで `@MainActor` の文脈から handler を設定する場合の書き方 (closure に `@Sendable` を付けるか `nonisolated` な関数へ分離し、main actor へは `Task { @MainActor in ... }` で渡す) を、handler bag ごとに同じ書式で揃える (現状は `onDataChannel` / `onDataChannelOpened` / `onSwitchVideo` など一部の callback にしか説明がない)。あわせて `Sora.connect(configuration:webRTCConfiguration:handler:)` の引数 handler の executor 契約も対象に含める。反映先は各 handler の API doc と `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節であり、引数 handler は `SKILL.md` の callback 一覧に無いため追加する。
- legacy handler の deprecation と削除は本 issue に含めない。

### 他の open issue との整合

- `0035` が追加する audio session event も新 event API の購読対象に含めるが、raw `RTCAudioSession` を新 Sendable event payload に含めない。入力源は既存の `SoraHandlers.onChangeAudioRoute` (`.audioRouteChanged`) とし、`0035` が追加する handler も同じ event model へ追加できる構造にする。本 issue は `0035` の完了を待たずに着手できる。
- `0035` が追加する audio session handler の doc も本 issue の書式 (配送 executor と Swift 6 言語モードでの書き方) に揃える。`0035` の完了条件 (UI 操作は `DispatchQueue.main.async` で束ねる旨の注記) は変更せず、`0035` が先行して完了した場合も本 issue の実装時に `SoraHandlers` の doc をまとめて本 issue の書式へ揃える。
- `0126` の切断クリーンアップ完了保証とタイムアウトは、接続終了 event の順序と exactly-once 契約へ統合できる構造にする。`onDisconnect` はクリーンアップ完了後に発火する状態が `0010` で実装済みであり、新 event API の接続終了 event はこのタイミングと 1 回性を前提とする (旧 `0047` は対応不要として closed 済み)。
- `0154` (完了 2026-10-02) が `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の closure property の排他を実装済みである。残る `0162` が扱う `Configuration.mediaChannelHandlers` の接続間共有は、legacy handler の互換配送と接続ごとの購読に影響するため、実装順序を整合させる。
- `0027` の renderer event は MainActor 専用経路として一般 event stream と分離する。

## 変更対象

- `Sora/`: public な Sendable event model (enum / struct) と購読 API の追加 (新規ファイル。ファイル名は実装時に `Sora/` の既存の命名に合わせる)
- `Sora/Sora.swift` / `Sora/MediaChannel.swift` / `Sora/WebSocketChannel.swift` / `Sora/MediaStream.swift` / `Sora/CameraVideoCapturer.swift`: 内部 event から legacy handler への compatibility adapter の追加、handler bag の doc への配送 executor / 配送セマンティクス / Swift 6 言語モードでの書き方の追記、`Sora.connect(configuration:webRTCConfiguration:handler:)` の引数 handler の executor 契約の追記
- `SoraTests/`: event ordering、buffer / drop 方針、購読解除、reentrancy、2 接続の混線のテスト (新規ファイル。ファイル名は実装時に `SoraTests` の既存の命名に合わせる) と、`SoraTests/SendableConformanceTests.swift` への公開 Sendable 型の表明の追加
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/`: 新しい event API の compile scenario (nonisolated actor と `@MainActor` の両方からの購読。`@MainActor` 側は `@MainActor` 注記付きの scenario として同じ target に置く) の追加
- `TestConsumers/Swift6Consumer/README.md`: 追加した scenario、公開 closure の表、負例と担当表の更新
- `TestConsumers/Swift6Consumer/NegativeChecks/`: 購読 API が `@Sendable` closure を受け取る形になる場合の負例 (non-Sendable な capture が診断で失敗すること) の追加 (`0107` の負例の追加手順と `EXPECT-DIAGNOSTIC` の規約に従う。`AsyncStream` のみで `@Sendable` closure を取らない場合は追加せず、その理由を `README.md` の公開 closure の表に記載する)
- `TestConsumers/Swift6Consumer/ApiBaseline/`: `make api-baseline` による再生成
- `skills/sora-ios-sdk/SKILL.md`: `### Sendable 準拠` の一覧への event 型の追加、`## Swift 6 と並行性` の「現状の制約」と `@preconcurrency import Sora` の説明から event (未提供である旨) を外す更新、「コールバックのスレッド」節への legacy handler と `Sora.connect(...)` の引数 handler の契約の追記、legacy handler と新 event API の対応表の追加
- `CHANGES.md`: `## develop` への `[ADD]` の追記 (executor または配送セマンティクスを変更する場合は `[CHANGE]`)

## スコープ外

- legacy handler API の削除は次期 major version の別 issue とする。
- `CameraVideoCapturerHandlers` の `onCapture` / `onStart` / `onStop` は、新しい event API の対象としない。カメラ状態の所有は `0103` (完了 2026-09-16)、frame の lifetime と順序保証は `0105` (完了 2026-09-18) が扱っている。
- `SoraHandlers` の closure property の読み書き排他は `0111` で扱う。新 event API は `SoraHandlers` のイベントも購読対象にするが、排他は `0111` の範囲とする。
- MainActor renderer protocol の追加は `0027` で扱う。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。
- RPC response API は `0109` (完了 2026-09-30) で追加済み。

## テスト方針

モックやスタブは使用しない。

- 実 Sora 接続と実 WebRTC event を、新しい event API と legacy handler の両方で購読する。
- connect、stream add、DataChannel open、message、redirect、disconnect の event 順序を記録する。
- event handler 内から同期 getter、send、disconnect を呼び、deadlock しないことを確認する。
- 購読 Task を cancel し、continuation と購読者が残留しないことを確認する。
- buffer overflow を実 event の連続発生で再現し、定義した drop / backpressure 方針どおりになることを確認する。
- 2 接続の event が connection ID / epoch で混線しないことを確認する。
- `0107` (完了 2026-09-24) の consumer package から nonisolated actor と MainActor の両方で購読できることを確認する。
- テストには、event ordering、buffer 方針、reentrancy の期待を日本語コメントで明記する。

## 完了条件

- Sendable な event model と購読 API が公開されていること。
- event payload に mutable `MediaChannel`、`MediaStream`、raw WebRTC object が含まれないこと。
- event の配送 executor、順序、lifetime、buffer、購読解除、購読者数契約 (複数購読者 / 1 接続 1 stream) が API documentation に記載されていること。
- legacy handler bag の doc に callback の配送 executor / スレッドの契約、配送セマンティクス、Swift 6 言語モードでの書き方が、handler bag ごとに同じ書式で記載されていること (`Sora.connect(configuration:webRTCConfiguration:handler:)` の引数 handler も含む)。
- `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節に `Sora.connect(configuration:webRTCConfiguration:handler:)` の引数 handler を追加し、`### Sendable 準拠` の一覧・`## Swift 6 と並行性` の「現状の制約」・`@preconcurrency import Sora` の説明を event API の追加に合わせて更新していること。
- Task cancellation と接続終了で購読が確実に終端すること。
- 利用者 callback を内部 owner の critical section 外で実行すること。
- UIKit 専用 event 以外を一律 MainActor へ隔離していないこと。
- legacy handler API の source compatibility が維持されること。
- legacy handler と新 event API の event 内容・順序の対応表が `skills/sora-ios-sdk/SKILL.md` に記載されていること。
- `0035`、`0126`、`0027` の event 設計と矛盾しないこと。
- legacy handler の配送 executor と配送セマンティクス (配送のたびに bag を読み、接続途中の設定が次の配送から反映される) が現行のまま維持されていること (変更する場合は各 handler bag の doc と `SKILL.md` の「コールバックのスレッド」節を更新し、`CHANGES.md` を `[CHANGE]` としていること)。
- `0107` の consumer package へ新しい event API の compile scenario (nonisolated actor と `@MainActor`) を追加し、`make consumer-build` (ConsumerCore / ConsumerUI / ConsumerLegacy / ConsumerSwift5) が成功すること。
- 購読 API が `@Sendable` closure を受け取る形になった場合は、`0107` の負例の規約に従って `TestConsumers/Swift6Consumer/NegativeChecks/` の負例を追加し、`make consumer-check-negative` が成功すること (追加しない場合はその理由が `README.md` の公開 closure の表に記載されていること)。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること (公開 API の追加は `make api-check` では検出できず、`api-check-fresh` が検出する。`CODEBASE.md` の規約)。
- `CHANGES.md` の `## develop` に `[ADD]` を追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

### 実装

- `Sora/SoraEvent.swift` (新規) に公開型を追加した。イベント値 `SoraEvent` (`Sendable`)、種別 `SoraEventKind` (`RawRepresentable` な struct)、エラー snapshot `SoraEventError`、音声入出力ルートの `SoraAudioRouteEvent` / `SoraAudioRouteSnapshot` / `SoraAudioPortSnapshot` で、payload から `MediaChannel` / `MediaStream` / raw WebRTC object を排除した。種別を enum の case 列挙にしないため、後続 issue が種別を追加しても利用者の既存コードは compile でき続ける (`switch` に `default` が必要であることは API doc と `SKILL.md` に記載)。
- `Sora/SoraEventPublisher.swift` (新規、internal) に購読者の管理を追加した。購読者ごとに continuation を保持して独立した `AsyncStream` を返し、`publish` は lock 内で通し番号を採番して購読者を取り出したあと lock を解放して `yield` する。`finish` も lock を解放してから continuation を終端し、購読の解除は `onTermination` から `removeSubscription` を呼ぶ (`[weak self]` のため storage を延命しない)。
- `Sora/Sora.swift` に `Sora.subscribeEvents(bufferingPolicy:)` を、`Sora/MediaChannel.swift` に `MediaChannel.subscribeEvents(bufferingPolicy:)` を追加した。既定は `.bufferingNewest(SoraEvent.defaultBufferSize)` (256 件) で、buffer の件数と drop 方針は購読者ごとに指定できる。
- 配送点は既存 handler の呼び出しの直後に追加した。`Sora` 側は `mediaChannelAdded` / `mediaChannelRemoved` / `audioRouteChanged` と接続の `connected` / `connectFailed` / `disconnected`、`MediaChannel` 側は `connected` / `connectFailed` / `streamAdded` / `streamRemoved` / `videoEnabledChanged` / `audioEnabledChanged` / `signalingReceivedJSON` / `dataChannelOpened` / `dataChannelAvailable` / `disconnected` で、`DataChannel` のメッセージ受信と `MediaStream` の有効フラグ確定も含む。すべて owner の排他区間外で呼び、`connected` / `connectFailed` は接続の完了と同じ配送点とした。
- `Sora` 側の接続イベントには `connectionId` と `transportEpoch` を載せ、redirect で世代が進んだことをイベントから識別できるようにした。`transportEpoch` は `PeerChannel.dataChannelGeneration` の lock 付き snapshot を読む。
- 既存 handler API の型、配送 executor、配送順序、発火回数は変更していない。既存 callback の呼び出しの後ろにイベント配送を追加しただけで、配送のたびに bag を読む既存セマンティクスも維持している。

### 契約の明文化

- 購読 API の doc に、配送 executor (イベントの発生元により異なり、購読者のコードは購読している `Task` の executor 上で動く)、配送順序 (同時に配送されたイベントは `sequence` の順序と一致しない場合がある)、payload lifetime (値として確定し配送後も保持できる)、buffer と drop、購読解除の 4 経路 (`Task` の cancel / `AsyncStream` の解放 / 接続の終了 / `Sora` インスタンスの解放)、購読者ごとの独立性、購読開始前のイベントは届かないこと、購読 loop から同期 API を呼べることを記載した。
- 5 つの handler bag (`SoraHandlers` / `MediaChannelHandlers` / `WebSocketChannelHandlers` / `MediaStreamHandlers` / `CameraVideoCapturerHandlers`) の doc を「呼び出し元のスレッドは保証されない」「配送のたびにプロパティを読むため接続途中の設定が次の配送から反映される」「Swift 6 言語モードで `@MainActor` の文脈から設定する場合の書き方」の 3 段落で揃え、payload に合わせて非 `Sendable` な型を書き分けた (`CameraVideoCapturerHandlers.onCapture` は返した `VideoFrame` の所有権が SDK へ移るため、frame を `Task` へ運ばず返却前に処理を終えることを明記)。
- `skills/sora-ios-sdk/SKILL.md` に「イベントの購読」節、legacy handler とイベントの対応表、`Sora.connect(configuration:webRTCConfiguration:handler:)` の引数 handler の executor 契約を追加し、`### Sendable 準拠` の一覧・「現状の制約」・`@preconcurrency import Sora` の説明を event API の追加に合わせて更新した。
- `CHANGES.md` の `## develop` に `[ADD]` を追記した (executor と配送セマンティクスを変更していないため `[CHANGE]` は無し)。

### 追加した test

- `SoraTests/SoraEventTests.swift` (新規): 複数の購読者が同じイベントをそれぞれ受け取ること、購読者がいない間も通し番号が進むこと、buffer の drop と `sequence` による欠落検出、購読者ごとの buffer 方針の独立、`Task` の cancel と `AsyncStream` の解放で購読者数が減ること、`.disconnected` の配送後に終端すること、payload と接続 ID / 世代、`Sora` 側の配送点 (`add` / `remove`) とインスタンス単位のイベント、`MediaChannel` の解放で終端すること、設定エラー経路の `connectFailed`、購読 loop からの同期 API 呼び出し、redirect による世代更新、`SoraEventKind` の拡張性、`DataChannel` のメッセージ配送点を検証する。buffer の drop は `publishEvent` を連続して呼んで再現し、redirect は実サーバーから起こせないため signaling の受信ハンドラーへ直接渡して検証した。モックやスタブは使用していない。
- `SoraTests/SoraEventE2ETests.swift` (新規): 実 Sora 接続で、接続ライフサイクル・シグナリング・切断と購読の終端を legacy handler と対応付けて検証する test と、2 接続の stream / DataChannel イベントが混線しないことを検証する test を追加した。購読は接続の開始前 (`SoraHandlers.onAddMediaChannel`) に開始し、`connected` や DataChannel の open を取り逃さないようにしている。
- `SoraTests/MediaStreamEnabledOperationTests.swift`: 有効フラグの確定がイベントとして配送され、同値の再代入では配送されないことを検証する test を追加した。
- `SoraTests/SendableConformanceTests.swift`: 追加した公開型 6 種の `Sendable` 準拠表明と、actor 境界を越える assertion を追加した。
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/SoraEventScenario.swift` (新規): nonisolated な文脈、`@MainActor`、nonisolated な actor からの購読と `Task` 境界への受け渡しの compile scenario を追加した。`AsyncStream` を返して closure を取らない API のため `NegativeChecks` の負例は追加せず、その理由を `README.md` の公開 closure の表に記載した。

### 公開 API baseline の再生成

公開型 6 種と `subscribeEvents(bufferingPolicy:)` の追加に伴い `make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を再生成した。追加のみ (+2641 / -0) で、internal な `SoraEventPublisher` とテスト用アクセサは baseline に現れない。`make api-check-fresh` が成功することを確認した。

### 検証結果

検証環境は sandbox のため `~/Library/Caches/org.swift.swiftpm` などへの書き込みが拒否される。`CFFIXED_USER_HOME="$PWD/build/home" HOME="$PWD/build/home"` を付けて実行した。

- `make build` (`-warnings-as-errors`): `** BUILD SUCCEEDED **`
- `make fmt-lint`: 成功。`make lint` は検証環境の sandbox が `sandbox-exec` を拒否するため実行できない。`swiftlint` の実体を直接実行して `Found 0 violations, 0 serious in 71 files`
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` / `ConsumerSwift5`: すべて `** BUILD SUCCEEDED **`
- `make consumer-check-negative`: 4 件が期待どおり compile に失敗
- `make api-check-fresh`: `The committed API baseline matches the current Sora module.`
- `xcodebuild test` (iPhone 17 Pro / iOS 26.5): **521 件 / skip 39 / 失敗 0 / exit 0** (`build/0110-polish-r6-tests.log`)。E2E 2 件は `SORA_SIGNALING_URL` 未設定のためローカルでは skip される
- GitHub Actions の `E2E Test` (run 95、`0e62ddf5`): `e2e` job の `Run E2E Tests` が成功し、実サーバー接続で E2E 2 件 (接続ライフサイクルと legacy handler の対応、2 接続の stream / DataChannel の非混線) が成功した。`tsan` job も `Run Thread Sanitizer Tests` と `Check Thread Sanitizer Report` が成功し、TSan レポートは 0 件だった (https://github.com/shiguredo/sora-ios-sdk/actions/runs/37608166419)
- pre-commit フック (`prek`) は全項目 Passed で、`swift format` / SwiftLint による修正は発生しなかった

### 残っている事項

- `.streamRemoved` は libwebrtc の `didRemove stream` からのみ配送され、SDK 自身の解放経路では配送されない。配送の実測ができていないため配送点の test は追加していない
- `.audioRouteChanged` の結線は private な adapter 型を経由するため、test のための公開追加を行っていない
- 購読 loop から `sendMessage` / `disconnect` を呼ぶ test は追加していない (配送が owner の排他区間外であることが deadlock しない根拠)
- `MediaChannel.publishEvent` が読む `PeerChannel.connectionId` は従来どおり lock 非保護であり、本 issue では変更していない (`tsan` job では検出されていない。別 issue 候補)
- 利用者向けドキュメント (`sora-ios-sdk-doc` の `callback.rst`) への追記は別リポジトリで行った
