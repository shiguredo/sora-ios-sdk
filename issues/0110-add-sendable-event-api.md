# executor 契約を持つ Sendable event API を追加する

- Created: 2026-08-27
- Completed:
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
