# Sora の共有状態と WebRTC logger lifecycle を同期する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-sora-shared-state
- Polished: 2026-11-18
- Refreshed: 2026-11-18

## 目的

`Sora` の handler、SDK 初期化・終了、WebRTC callback logger の lifecycle を同期し、`Sora: @unchecked Sendable` と `nonisolated(unsafe)` な static state に依存しない構造へ移行する。

複数の `Sora` instance と `Sora.shared` が並行利用されても、handler のデータ競合、logger の start / stop 競合、SDK cleanup 中の再利用が起きないことを保証する。

## 現状

`Sora/Sora.swift` の `Sora` は class 全体が `@unchecked Sendable` である。

`mediaChannels` の配列は `mediaChannelLock` で保護され、add / remove callback も lock 外で呼ばれている。一方、次の状態は同じ同期方針に含まれていない。

- `SoraHandlers` の mutable closure property
- `audioSessionDelegateAdapter` からの handler 呼び出し
- static な SDK initialize / finish lifecycle
- `webRTCCallbackLogger`

`webRTCLoggingDateFormatter` は immutable な `static let` であり、mutable state ではない。`DateFormatter` は iOS 7 以降 thread-safe である Apple の仕様に基づき同期は不要だが、logger callback から任意のスレッドで同時に参照されるため、この扱いの根拠を設計方針に明記する。

`SoraHandlers` は利用者が任意の executor から property を変更できる。add、remove、connect、disconnect、audio route callback は別 executor から handler を読み出すため、Optional closure 自体の読み書きが競合する。

`webRTCCallbackLogger` は `nonisolated(unsafe) static var` である。`setWebRTCLogLevel(_:)` は severity を変更し、stop、start の順で logger を再設定するが、並行呼び出しに対する排他と generation がない。

`Sora.finish()` は global な WebRTC cleanup を実行するが、Sora instance または MediaChannel が存続・接続中かを管理しない。finish と新しい initializer / connect が競合した場合の契約もない。

`Logger.shared` の同期は `0106` (2026-09-18 完了) で対応済みのため、本 issue では `Sora` が所有する state と WebRTC callback logger だけを対象とする。

## 設計方針

### Sora instance state

- `Sora` の可変 state を扱う instance state owner (`SoraInstanceStateOwner`) を導入し、`mediaChannels` と `audioSessionDelegateAdapter` をこの owner の `let` に移す。
- `SoraHandlers` は `public final class SoraHandlers: Sendable` にする。5 つの handler property は source compatibility を維持した computed property とし、内部の `SoraHandlersStorage` (`@unchecked Sendable` の internal final class) が保持する 5 つの `HandlerStorage` 経由で get / set する。`Sora.handlers` は `public let handlers = SoraHandlers()` の宣言形のまま維持する。
- `HandlerStorage` 自体は `0154` の方針どおり `Sendable` に準拠させない。`SoraHandlersStorage` を `@unchecked Sendable` にしてよい根拠は、5 つの handler の get / set がすべて `HandlerStorage` の `NSLock` で排他され、storage 自身が可変の stored property を持たないことである。この根拠と、callback の executor 契約 (呼び出しスレッドを保証しない) を型 doc に日本語で書く。
- audio session delegate の登録は instance state owner が行い、adapter は `Sora` を強参照せず、`SoraHandlers` と `SoraEventPublisher` を参照する。解除は `Sora` の `deinit` で行う。
- callback 呼び出し時は handler を lock 下で snapshot 化し、実行は lock の外で行う。
- handler の差し替えと callback が競合した場合、snapshot 取得時点の handler を 1 回だけ呼ぶ契約にする。
- `0110` (2026-10-07 完了) で Sendable event API は導入済みである。現行実装は legacy handler の呼び出し直後に `publishEvent` を呼ぶ形で、内部 event から legacy handler を配送する adapter は持たない。

### SDK lifecycle

- process-wide な `SoraLifecycleOwner` (internal final class、`@unchecked Sendable`、`NSLock`) が `Sora` の生成と接続の登録数および finish 状態を保持する。cleanup は実行せず、状態遷移だけを担う。
- initialize の 1 回実行は現行の `private static let isInitialized` で実装済みであり、この保証を維持する。
- 接続の登録は `Sora.connect(...)` の入口で `SoraLifecycleOwner` の排他区間内に行い、接続試行中も登録数に含める。登録は 1 回だけ解除できるトークンとして発行し、登録できない (終了状態) 場合は `preconditionFailure` にする。
  - `Sora.connect` の設定エラー: その場で解除する。
  - 接続の終端 (`MediaChannel` の `finishDisconnect`): 公開 handler を呼ぶ前に解除する (handler から `finish()` を呼べるようにするため)。
  - `MediaChannel` の `deinit`: 未解除の場合だけ解除する (二重解除しない)。
  - `Sora.connect` を経由しない `MediaChannel` はトークンを持たない。
- `Sora` の生成も `init` の入口で同じ排他区間で登録し、生成完了で解除する。生成中の `finish()` は `preconditionFailure` にする。`Sora.shared` の存在は数えない。
- テストから process-wide の owner を汚さずに接続登録を検証できるよう、`Sora` の internal init で `SoraLifecycleOwner` を注入できるようにする (`public init()` は shared を使う)。
- `finish()` は次の契約にする。
  - 排他区間で登録数を確認し、1 つ以上ある場合は cleanup を実行せず `preconditionFailure` にする (cleanup と接続の並行実行を防ぐ)。
  - 0 の場合は排他区間で終了状態にしてから `RTCShutdownInternalTracer()` / `RTCCleanupSSL()` を実行する。2 回目以降の `finish()` は何もしない。
  - 終了状態では `Sora` の生成、`Sora` インスタンスの `connect(...)`、`Sora.setWebRTCLogLevel(_:)` を `preconditionFailure` にする。`RTCInitializeSSL()` は再実行しない。
  - この契約を `Sora.finish()` の doc comment と `skills/sora-ios-sdk/SKILL.md` に書く。
- 既存 `public static func finish()` のシグネチャは変更せず、新しい終了 API と `SoraError` の case は追加しない。

### WebRTC callback logger

- process-wide な `SoraLoggerOwner` (internal final class、`@unchecked Sendable`、`NSLock`) が `RTCCallbackLogger`、severity、running state、generation を保持する。
- severity 更新、stop、start、generation の採番を同じ排他区間で順序付ける。
- logger callback は登録時の generation を保持し、owner の現在の generation と一致しない callback は何も出力しない。
- callback 内の日時整形と `print` は owner の lock の外で行う。
- callback で共有する `webRTCLoggingDateFormatter` は iOS 7 以降 thread-safe である Apple の仕様に基づき、専用 lock を追加せず共有を認め、その根拠を日本語コメントに残す。
- `webRTCCallbackLogger` の `nonisolated(unsafe)` を除去し、owner の `let` にする。

### Sendable

- `Sora` 全体の `@unchecked Sendable` を除去できるよう、mutable state を owner / synchronized storage に閉じ込める。
- `Sora` は final class を維持したまま stored property を `let` の owner / synchronized storage だけにし、checked な `Sendable` に準拠させる (`Sora.shared` を並行利用できる現行の公開面を維持するため。Swift 6 では `static let shared` の型が `Sendable` でないと concurrency-safe にならない)。
- 本 issue で `Sora/Sora.swift` に追加する `@unchecked Sendable` は、handler / instance state / lifecycle / logger の可変状態を保持する internal final class (`SoraHandlersStorage` / `SoraInstanceStateOwner` / `SoraLifecycleOwner` / `SoraLoggerOwner`) の 4 型に限定し、既存の `ConnectErrorHandlerBox` は維持する。他の file の既存の `@unchecked Sendable` は変更しない。各型の型 doc に、可変状態を保護する lock と、呼び出し側 executor の契約を日本語で書く。

## スコープ外

- `Logger.shared` の state は `0106` (2026-09-18 完了) で同期済みであり、本 issue の対象外とする。
- `ConnectionTask` の状態遷移と `ConnectionState` の意味は `0092` / `0100` で対応済みであり、本 issue では変更しない。接続登録の開始と解除のフックだけを `Sora.connect` と `MediaChannel` の終端 / `deinit` に追加する。
- 新しい Sendable event API は `0110` (2026-10-07 完了) で導入済みであり、本 issue の対象外とする。
- raw `RTCAudioSession` を legacy handler から除去する作業は `0070` の方針 (`SoraHandlers.onChangeAudioRoute` の第 1 引数を `AVAudioSession` へ変更) に合わせる。新しい event API は `0110` (2026-10-07 完了) で raw 型を含まない形で導入済みである。
- `Sora.setWebRTCLogLevel` のシグネチャと `RTCCallbackLogger` の将来の扱いは `0070` の互換性方針 (webrtc_c 移行での破壊的変更候補) と整合させる。logger owner の設計は移行後も適用できる形にする。
- 音声 unit の機能仕様は変更しない。

## 変更対象

- `Sora/Sora.swift`: `SoraHandlers`、instance state owner、lifecycle owner、logger owner の導入。`Sora` の stored property を `let` だけにして `@unchecked Sendable` とその説明コメントを削除する。`SoraHandlers` の doc comment を lock 付き storage と配送時 snapshot の契約へ更新する。`Sora.finish()` の doc comment に lifecycle 契約を書く。`SoraRTCAudioSessionDelegateAdapter` を internal にし、テスト用に `SoraLifecycleOwner` を注入できる internal init を追加する
- `Sora/MediaChannel.swift`: `Sora.connect` が発行する接続登録のトークンを受け取り、終端 (`finishDisconnect`) と `deinit` のどちらか先の 1 回だけ解除する。トークンを受け取らない生成経路は登録数に影響しない
- `skills/sora-ios-sdk/SKILL.md`: `@unchecked Sendable` の記載から `Sora` を除去する (`0106` は完了済みで、同記載に残る公開型は `Sora` だけである)。internal 型はこの一覧 (公開型の一覧) に載せないため、`Sora` を除去した結果として載せる公開型が無くなる場合は同記載の行を削除する。あわせて、`Sendable` の一覧 (接続と切断の並び) に `Sora` を追加し、「`Sendable` ではない」の一覧から `SoraHandlers` を外して `Sendable` の一覧へ追加する。`### コールバックのスレッド` の「ハンドラの設定」の行の列挙に `SoraHandlers` を加え、「`SoraHandlers` のプロパティは含まない」という括弧書きを削除する。`Sora.finish()` の契約 (接続中または接続試行中の接続がある場合、二重呼び出し、終了状態での利用) を記載する
- `CHANGES.md`: `## develop` の主リストへ、`finish()` の契約変更 (接続中または接続試行中に呼ぶと `preconditionFailure`、終了状態での `Sora` の生成 / `connect` / `setWebRTCLogLevel` は `preconditionFailure`、二重呼び出しは no-op) を `[CHANGE]`、`Sora` と `SoraHandlers` の checked `Sendable` 化と handler property の排他を `[UPDATE]` として追記する。`SoraHandlers` に `Sendable` 準拠を追加するため、利用側で独自に追加していた準拠は削除が必要になる旨を書く
- `SoraTests/SoraHandlersConcurrencyTests.swift` (新規): `SoraHandlers` の並行 get / set、snapshot 境界、再入 deadlock のテスト
- `SoraTests/SoraLifecycleOwnerTests.swift` (新規): テストごとに生成した owner instance による接続登録の増減、finish 判定、二重 finish、終了状態の判定のテスト
- `SoraTests/SoraSharedStateTests.swift` (新規): internal init で owner を注入した複数 `Sora` instance の生成・破棄、`Sora.connect` の設定エラー / キャンセル / 切断 / `deinit` での登録解除、`Sora.shared` の並行利用 (process-wide の owner は終了状態にしない) のテスト
- `SoraTests/SoraLoggerOwnerTests.swift` (新規): `setWebRTCLogLevel` の並行呼び出し、generation、古い callback の無視のテスト
- `SoraTests/SendableConformanceTests.swift`: `requireSendable(Sora.self)` と `requireSendable(SoraHandlers.self)` を追加する
- `TestConsumers/Swift6Consumer/ApiBaseline/` (`iphoneos26.5.json` / `iphoneos26.5.info.txt`): `SoraHandlers` の property を同期 storage 経由の computed property にすると `declAttributes` / `hasStorage` が変わるため、同じ変更で `make api-baseline` により baseline を再生成し、`make api-check-fresh` が成功することを確認する (`CODEBASE.md` の「公開 API baseline」を参照)
- `issues/0035-add-audio-session-event-handlers.md`: 0035 は `SoraHandlers` への handler property 追加と `Sora.audioSessionDelegateAdapter` の生成方法を前提にしている。0111 を先行させ、0111 の変更で 0035 の現状 / 設計方針 / 完了条件を、`SoraHandlersStorage` 経由の property 追加と `SoraInstanceStateOwner` 経由の adapter 生成に更新する (`shiguredo-git` の「issue ファイル単体のコミット」に従い、実装コミットと分けた issue ファイル単体のコミットにする)

## テスト方針

モックやスタブは使用しない。

- 複数の実 `Sora` instance を並行して生成・破棄し、`Sora.shared` を含めた並行利用で handler と SDK lifecycle の競合がないことを確認する。
- handler の設定変更と add、remove、connect、disconnect、audio route event を競合させる。audio route は internal にした `SoraRTCAudioSessionDelegateAdapter` の実インスタンスに `audioSessionDidChangeRoute` を直接呼んで駆動する (モックは使わない)。
- handler 内から handler を差し替え、connect / disconnect を呼んでも deadlock しないことを確認する。
- `setWebRTCLogLevel` を複数 Task から反復し、呼び出しごとに generation が進み、running state が 1 つだけであることを `SoraLoggerOwner` の internal アクセサで確認する。stdout は捕捉しない。
- 実 WebRTC log を出力し、古い generation の callback が出力されないことを確認する。generation の判定は `SoraLoggerOwner` の internal メソッド (generation を渡すと出力可否を返す) で検証する。
- `SoraLifecycleOwner` の状態遷移 (接続登録の増減、finish 判定、二重 finish、終了状態の判定) を、テストごとに生成した owner instance で検証する。`Sora` を使うテストは internal init で owner を注入し、process-wide の owner を終了状態にしない。実際の `RTCShutdownInternalTracer()` / `RTCCleanupSSL()` はテストで実行しない。
- 接続中または接続試行中の接続がある `finish()` と、cleanup を含む `finish()` は実機で手動確認する。CI では cleanup を含む `finish()` を実行しない (`finish()` が WebRTC のグローバル cleanup を行い、同一プロセスの他のテストを壊すため)。
- Thread Sanitizer を補助的に有効化する。
- テストには、handler snapshot と logger generation の境界を日本語コメントで明記する。

## 完了条件

- `SoraHandlers` の全 property の読み書きが同じ同期方針で保護されていること。
- `SoraHandlers` の doc comment から「プロパティの読み書きを排他する lock は無く、並行する設定変更はデータ競合になる」が削除され、lock 付き storage と配送時 snapshot の契約になっていること。
- handler を lock の外で呼び、再入しても deadlock しないこと。
- SDK initialize が 1 回だけ実行され、`Sora` の生成と接続の登録数および finish 状態が `SoraLifecycleOwner` で管理され、生成中または接続中は cleanup せず、finish は 0 回または 1 回だけ cleanup を実行し、終了状態が保持されていること。
- 接続の登録が接続 1 回につき 1 回だけ解除され、設定エラー・終端・`MediaChannel` の `deinit` のどの経路でも登録数が負にならず、`Sora.connect` を経由しない `MediaChannel` は登録数に影響しないこと。
- `Sora.finish()` の doc comment と `skills/sora-ios-sdk/SKILL.md` に、接続中または接続試行中の接続がある場合、二重呼び出し、終了状態での `Sora` の生成 / `connect` / `setWebRTCLogLevel` の挙動が記載されていること。
- WebRTC callback logger の severity、start、stop、generation が `SoraLoggerOwner` で管理され、古い generation の callback が出力されないこと。
- `Sora/Sora.swift` の `webRTCCallbackLogger` から `nonisolated(unsafe)` が除去されていること。
- `Sora` の宣言から `@unchecked Sendable` が除去され、`Sora: Sendable` に準拠していること。
- `Sora/Sora.swift` で `@unchecked Sendable` を付ける型が `SoraHandlersStorage` / `SoraInstanceStateOwner` / `SoraLifecycleOwner` / `SoraLoggerOwner` と既存の `ConnectErrorHandlerBox` だけであり、それぞれの型 doc に、可変状態を保護する lock と executor 契約 (lock を使わない場合はその理由) が日本語で書かれていること。
- `Sora/Sora.swift` の宣言に `nonisolated(unsafe)` が無いこと (宣言行の grep で 0 件。doc comment 内の利用例は対象外)。
- `skills/sora-ios-sdk/SKILL.md` の `@unchecked Sendable` の記載から `Sora` が除去され、載せる公開型が無くなる場合は同記載の行が削除されていること。あわせて、`Sendable` の一覧に `Sora` と `SoraHandlers` が追加され、「`Sendable` ではない」の一覧から `SoraHandlers` が削除されていること。`### コールバックのスレッド` の「ハンドラの設定」の行の列挙に `SoraHandlers` が加えられ、「`SoraHandlers` のプロパティは含まない」という括弧書きが削除されていること。
- `SoraTests/SendableConformanceTests.swift` に `requireSendable(Sora.self)` と `requireSendable(SoraHandlers.self)` が追加されていること。checked であることは `@unchecked Sendable` を付与していないことの差分で確認する (`requireSendable` は準拠の存在だけを確認する)。
- `SoraHandlers` の property の computed property 化に伴い、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` の baseline が再生成され、`make api-check-fresh` が成功すること。
- `CHANGES.md` の `## develop` の主リストに、`finish()` の契約変更が `[CHANGE]`、`Sora` と `SoraHandlers` の checked `Sendable` 化と handler property の排他が `[UPDATE]` として追記され、`SoraHandlers` に `Sendable` 準拠を追加するため利用側の独自準拠の削除が必要である旨が書かれていること。
- 利用側で独自に追加していた `SoraHandlers` の `Sendable` 準拠の削除を除き、public API の名前・型・アクセスレベルが変わっていないこと。
- 追加したテストと既存テストがすべて成功すること (実機で手動確認する経路は除く)。
- 実機で接続中または接続試行中の接続がある `finish()`、二重 `finish()`、終了状態での `Sora` の生成 / `connect` / `setWebRTCLogLevel`、通常の切断後に登録数が 0 に戻ることを手動確認し、結果を issue か PR に記録していること。
- `SoraLifecycleOwner` と `Sora` のテストが process-wide の owner を終了状態にせず、後続テストへ影響を残さないこと。
- `issues/0035-add-audio-session-event-handlers.md` の現状 / 設計方針 / 完了条件が、`SoraHandlersStorage` 経由の property 追加と `SoraInstanceStateOwner` 経由の adapter 生成に更新されていること。

## 解決方法
