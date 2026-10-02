# イベントハンドラのプロパティの読み書きを排他する

- Created: 2026-09-15
- Completed: 2026-10-02
- Priority: Medium
- Branch: feature/refactor-handler-bag-exclusion
- Polished: 2026-10-01

## 目的

`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` のイベントハンドラのプロパティ (`onDisconnect` などのクロージャ) は `var` を持つ class であり、利用者スレッドの書き込みと配送スレッドの読み込みが排他されていない。データ競合をなくし、実行時の安全性を満たす。これらの型を `Sendable` に準拠させること、プロパティが持つクロージャに `@Sendable` を付けること、callback の executor 契約の明文化は本 issue の対象外とする (新しい Sendable event API と legacy handler の executor 契約 doc は `0110`、`SoraHandlers` の同期は `0111` が扱い、`0110` は既存 handler の class と property の型を変更しない)。

## 現状

`Sora/MediaChannel.swift` の `MediaChannelHandlers` / `Sora/WebSocketChannel.swift` の `WebSocketChannelHandlers` は `public final class`、`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturerHandlers` は非 `final` の `public class`、`Sora/MediaStream.swift` の `MediaStreamHandlers` は `public final class` で、いずれもイベントハンドラのプロパティを `var` として公開している。

`MediaChannel.handlers` は `public var` で、`MediaChannel.init` が `Configuration.mediaChannelHandlers` の参照をそのまま代入する。`SignalingChannel` も `Configuration.webSocketChannelHandlers` の参照を `ws.handlers` へ代入する。

配送は `MediaChannel.swift` の `handlers.onXxx?`、`DataChannel.swift` の `mediaChannel.handlers.onDataChannelMessage`、`URLSessionWebSocketChannel.swift` の `handlers.onReceive`、`MediaStream.swift` の `handlers.onSwitchVideo` / `onSwitchAudio` で、いずれも配送時にハンドラを読む。利用者は接続成功後に `mediaChannel.handlers.onDisconnect` などを設定する。

`0110` は新しい Sendable event API と legacy handler の executor 契約 doc を対象とし (既存 handler の class と property の型は変更しない)、`0111` は `SoraHandlers` の同期を対象としており、`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` のプロパティの排他はどちらの対象でもない。`CameraVideoCapturerHandlers` は `0103` が `CameraVideoCapturer.handlers` を lock 付きアクセサにした際に、イベントハンドラのプロパティ自体の排他を本 issue へ委ねている。`MediaStreamHandlers` は `0105` が frame の ingress と renderer 配送だけを扱い、イベントハンドラのプロパティの読み書き排他を本 issue へ委ねている。

## 設計方針

- `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` のイベントハンドラのプロパティの get / set を `NSLock` で排他する。公開シグネチャと配送セマンティクス (接続途中の設定が次の配送から反映される) を維持する。
- 配送側は lock の外で取得値 (closure のコピー) を呼ぶ。lock 保持中に呼ぶと、callback から別の handler を設定したときに deadlock するためである。
- `MediaChannel.handlers` の参照自体も lock 付きアクセサにし、差し替えと配送の競合をなくす。
- イベントハンドラのプロパティと `MediaChannel.handlers` を lock 付きの computed property にすると、公開 API のソース互換 (名前・型・アクセスレベル) は変わらないが、`swift-api-digester` の dump では `HasStorage` / `HasInitialValue` と accessor の `implicit` が変わる。`make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt` を同じ変更内で再生成し、`make api-check-fresh` が成功することを確認する (`CODEBASE.md` の「baseline を更新する手順」)。
- `MediaChannel.internalHandlers` / `PeerChannel.internalHandlers` / `SignalingChannelInternalHandlers` / `WebSocketChannelInternalHandlers` は対象外とする。`MediaChannel.internalHandlers` は型が `MediaChannelHandlers` のため イベントハンドラのプロパティは property ごとの `HandlerStorage` が持つ `NSLock` で排他される (参照の差し替えは無いため lock 付きアクセサは不要)。`PeerChannel.internalHandlers` の `onAddStream` などは `MediaChannel.basicConnect` が非同期 hop の後に設定するが、`peerChannel.connect` を呼ぶ前の 1 回だけであり、配送と並行する書き換えは無い。`SignalingChannelInternalHandlers.onDisconnect` は `PeerChannel.init` と `MediaChannel.connect` の 2 箇所で設定され後者が上書きするが、これも配送開始前である。`URLSessionWebSocketChannel.internalHandlers` は redirect ごとに生成される channel へ設定され `disconnect` で差し替わるが、書込は `SignalingChannel` の `owner.queue` 上の接続処理で行われ、読み出しも同じ queue 上の delegate callback である。`URLSessionWebSocketChannel.handlers` (参照) も同じ queue 上で接続開始前に 1 回だけ代入され、配送は同じ channel の delegate callback から行われるため、参照の差し替えと配送が並行しない。
- `SoraHandlers` の同期は `0111`、新しい Sendable event API と legacy handler の executor 契約 doc は `0110` に委ねる。`0110` は既存 handler のクロージャの型を変更しないため、本 issue でも `@Sendable` を付けない。
- `0102` の完了を前提とする。`0102` がハンドラクラスを snapshot から分離し、明示引数として引き渡す形にする。

## 前提となる issue

- `0102` (完了): ハンドラクラスを設定 snapshot から分離する。
- `0103` (完了): カメラ状態の所有者を単一化する。`CameraVideoCapturerHandlers` の closure 排他を本 issue へ委ねている。
- `0105` (完了 2026-09-18): frame の ingress と renderer 配送を整理し、`MediaStreamHandlers` の イベントハンドラのプロパティの読み書き排他を本 issue へ委ねている。
- `0119` (完了 2026-09-30): Thread Sanitizer (TSan) による実行時検証の基盤。`.github/workflows/e2e-test.yml` の `tsan` job が `SoraTests` 全体を実行するが、`0119` はハンドラの読み書きを並行させる stress をスコープ外として本 issue へ委ねている。本 issue が追加する stress test はこの job の対象に入る。
- `0162` (open): `Configuration` の `MediaChannelHandlers` が接続間で共有される問題。`0162` が `MediaChannel.handlers` への代入方法を変える場合があるため、`0110` の「実装順序を整合させる」に従い、どちらかを先行させて他方を rebase する。`0162` が扱うハンドラクラスの共有自体は本 issue の対象外である。

## 完了条件

- `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の handler property の読み書きが排他されていること。
- 接続開始後に `MediaChannel.handlers` を変更した場合、次の配送から反映される既存挙動が維持されること。`E2ETestBase` の `disconnectAndVerify` / `disconnectAll` が無修正で成功することを回帰条件とする。
- 公開 API のソース互換 (名前・型・アクセスレベル) と配送セマンティクスが変更されていないこと。stored property から lock 付き computed property への変更で `swift-api-digester` の dump は変わるため、再生成した baseline で `make api-check-fresh` が成功すること。
- `SoraTests/ConcurrencyStressTests.swift` に追加した stress test で、handler property の読み書きと配送を複数スレッドから交差させ、Thread Sanitizer を有効にした実行でハンドラクラスを指す race report が出ないこと。CI の `tsan` job は `SoraTests` 全体を対象とするため、本 issue 以外の未修正の競合が残っている間は job 全体が失敗し得る。その場合の判定はハンドラクラスを指す report が無いことで行う。
- `CHANGES.md` に追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 変更対象

- `Sora/HandlerStorage.swift` (新規): イベントハンドラのプロパティ (クロージャ) とハンドラクラスの参照を `NSLock` で排他して保持する共通の内部型
- `Sora/MediaChannel.swift`: `MediaChannelHandlers` のイベントハンドラのプロパティの lock 化と `MediaChannel.handlers` の lock 付きアクセサ
- `Sora/WebSocketChannel.swift`: `WebSocketChannelHandlers` のイベントハンドラのプロパティの lock 化
- `Sora/CameraVideoCapturer.swift`: `CameraVideoCapturerHandlers` のイベントハンドラのプロパティの lock 化と、`CameraHandlersStorage` を `HandlerStorage` へ委譲する形への変更
- `Sora/MediaStream.swift`: `MediaStreamHandlers` のイベントハンドラのプロパティの lock 化
- `SoraTests/ConcurrencyStressTests.swift`: ハンドラの読み書きを交差させる stress test と、配送中の再入で deadlock しないことの検証の追加 (ファイル冒頭の「対象に含めない」という記述も本 issue の完了に合わせて更新する)
- `SoraTests/CameraVideoCapturerHandlersTests.swift` (新規): `CameraVideoCapturer.handlers` の差し替えと in-place 変更の維持の検証
- `skills/sora-ios-sdk/SKILL.md`: handler の設定が排他され任意の executor から行えることの追記
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: `make api-baseline` による再生成
- `CHANGES.md`: `## develop` への追記

## 解決方法

### 実装

- `Sora/HandlerStorage.swift` (新規) に `HandlerStorage<Value>` を追加した。イベントハンドラのプロパティ (クロージャ) およびハンドラクラスの参照を 1 つずつ `NSLock` で排他して保持する generic な storage であり、get は lock を解放してから値を返し、set は旧値の解放 (捕捉した object の `deinit`) を lock の外で行う。4 つのハンドラクラスと `MediaChannel.handlers` で同じ排他・解放の実装を重複させないため、`変更対象` に追記した共通の内部型として新設した (internal に閉じ、公開 API ではない)。
- `Sora/MediaChannel.swift`: `MediaChannelHandlers` の 10 個のイベントハンドラのプロパティを `HandlerStorage` の get / set に置き換えた (`@available(deprecated)` の注釈はそのまま維持)。`MediaChannel.handlers` は `HandlerStorage<MediaChannelHandlers>` の lock 付きアクセサにした。`internalHandlers` は参照自体を lock 化しない (接続開始後に差し替える経路が無い) が、イベントハンドラのプロパティは型が `MediaChannelHandlers` のため property ごとの `HandlerStorage` が持つ `NSLock` で排他される。
- `Sora/WebSocketChannel.swift`: `WebSocketChannelHandlers.onReceive` を `HandlerStorage` に置き換えた。
- `Sora/MediaStream.swift`: `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` を `HandlerStorage` に置き換えた。
- `Sora/CameraVideoCapturer.swift`: `CameraVideoCapturerHandlers.onCapture` / `onStart` / `onStop` を `HandlerStorage` に置き換えた。`CameraHandlersStorage` は `HandlerStorage<CameraVideoCapturerHandlers>` へ委譲する薄い型にし、自前の lock と旧 instance の解放処理の重複を削除した (旧 instance の解放は `HandlerStorage` の setter が lock の外で行う)。`CameraVideoCapturer` の型 doc を「`handlers` は型全体で共有する lock 付き storage から読み、イベントハンドラのプロパティはプロパティごとの storage が排他する」に更新した。
- `skills/sora-ios-sdk/SKILL.md`: handler の設定 (4 つのハンドラクラスのイベントハンドラのプロパティと `MediaChannel.handlers` の参照) が SDK 内部の lock で排他され任意の executor から行えることを、「コールバックのスレッド」節に追記した (`Logger` の設定についての既存記述と対にする)。

配送側 (`MediaChannel.swift` の `handlers.onXxx?`、`DataChannel.swift` の `mediaChannel.handlers.onDataChannelMessage`、`URLSessionWebSocketChannel.swift` の `handlers.onReceive`、`MediaStream.swift` の `handlers.onSwitchVideo` / `onSwitchAudio`) は変更していない。get が lock を解放してから closure を返すため、配送側は lock を保持せずに closure を呼ぶ。公開 API のソース互換と配送セマンティクスは変わらない。

### 追加した test

`SoraTests/ConcurrencyStressTests.swift` に 2 件追加し、ファイル冒頭の「ハンドラの読み書きを並行させる stress は本ファイルの対象に含めない」という記述を、本 issue で交差させる旨へ更新した。

- `testHandlerBagReadWriteRaceWithDelivery`: 4 つのハンドラクラスのイベントハンドラのプロパティ **16 個すべて**と、実 `MediaChannel.handlers` の参照の get / set を 64 スレッドで交差させ、8 ラウンド反復する。モックやスタブは使わない。`MediaStreamHandlers.onSwitchVideo` は、その設定と同じ並行区間の中で `MediaStream.videoEnabled` の確定経路 (`commitVideoEnabled` → `handlers.onSwitchVideo?(value)`) を実配送として駆動し、読み取りと書き込みを交差させる (`DispatchQueue.concurrentPerform` は全 iteration の完了まで戻るため、区間を分けると交差しない)。配送を駆動するのは 1 スレッドだけにした (`videoEnabled` の setter は native track の `isEnabled` も書くため、複数スレッドで駆動すると handler ではなく libwebrtc 側の競合になる)。`CameraVideoCapturerHandlers` の配送 (`onCapture` / `onStart` / `onStop`) は実カメラが必要で Simulator では駆動できないため get / set の交差だけを行う。round の区切りでは `onSwitchVideo` への `nil` 代入も write-vs-write として交差させる。通常の実行では**ラウンドごとに**配送回数が増えることを検証する (交差が空振りしていないこと)。実 Sora 接続を必要としないため `SORA_SIGNALING_URL` が無い環境でも実行される。
- `testHandlerReentrancyDoesNotDeadlock`: 配送された closure の中から同じ property と別の property を設定し直しても deadlock しないことを検証する。lock を保持したまま closure を呼ぶ実装に退行すると、失敗ではなく deadlock になる。
- `SoraTests/CameraVideoCapturerHandlersTests.swift` (新規): `CameraVideoCapturer.handlers` が差し替えない限り同じ instance を返すため in-place 変更 (`CameraVideoCapturer.handlers.onCapture = ...`) が維持されることと、差し替えると次の get が新しい instance を返すことを検証する (`CameraHandlersStorage.publish(_:)` の変更を踏む test が無かったため追加した)。

### 公開 API baseline の再生成

stored property から lock 付き computed property への変更で `swift-api-digester` の dump が変わるため、`make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt` を再生成した。再生成前後の差分は `hasStorage` の削除 (17 件)、`declAttributes` の `HasStorage` / `HasInitialValue` の削除、accessor の `Transparent` / `implicit` の変化だけで、`usr` の集合は新旧で一致し (追加・削除 0 件)、`ABIRoot.children` も 118 件のままである。`make api-check-fresh` が成功することを確認した。

### 検証結果

検証環境は sandbox のため `~/Library/Caches/org.swift.swiftpm` などへの書き込みが拒否される。`CFFIXED_USER_HOME="$PWD/build/home" HOME="$PWD/build/home"` を付けて実行した。

- `make build` (`-warnings-as-errors -Wwarning DeprecatedDeclaration`): `** BUILD SUCCEEDED **` (`build/0154-final-release.log`)
- `make fmt-lint`: 成功 (`build/0154-final-fmtlint.log`)。`make lint` は検証環境の sandbox が `sandbox-exec` を拒否する (`sandbox-exec: sandbox_apply: Operation not permitted`) ため実行できない。`swiftlint lint --strict --cache-path build/swiftlint-cache` で代替し、`Found 0 violations, 0 serious in 68 files` (`build/0154-final-swiftlint.log`)
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerLegacy` / `ConsumerSwift5` / `ConsumerUI`: すべて `** BUILD SUCCEEDED **` (`build/0154-final-consumer-*.log`)
- `make consumer-check-negative`: 4 件が期待どおり compile に失敗 (`build/0154-final-negative.log` の `4 negative check(s) failed as expected`)
- `make api-check-fresh`: `The committed API baseline matches the current Sora module.` (`build/0154-final-api.log`)
- 完了条件の `E2ETestBase` の `disconnectAndVerify` / `disconnectAll` の回帰は、実 Sora 接続が必要なため `SORA_SIGNALING_URL` 未設定のローカルでは skip され (36 件の skip に含まれる)、CI の `e2e` job と `tsan` job でのみ検証される
- 通常 test: **472 件 / skip 36 / 失敗 0 / exit 0** (`build/0154-final-plain.log` の `PLAIN_EXIT=0`)。追加した `testHandlerBagReadWriteRaceWithDelivery` / `testHandlerReentrancyDoesNotDeadlock` / `CameraVideoCapturerHandlersTests.testHandlersStoragePublishesBagAndKeepsInPlaceChanges` は pass
- Thread Sanitizer 有効: `-enableThreadSanitizer YES` の `build-for-testing` が作った `SoraTests.xctest` を、`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` に `<bundle>/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib` を指定した `xcrun simctl spawn` で全件実行した。**472 件 / skip 36 / 失敗 0 / `WARNING: ThreadSanitizer` 0 行 / `***** Running under ThreadSanitizer` あり / exit 0** (`build/0154-final-tsan.log` の `TSAN_EXIT=0`)。追加した 3 件の test を TSan で 30 回反復しても 90 件すべて pass、`WARNING: ThreadSanitizer` 0 行、abort 0 件 (`build/0154-final-repeat-tsan.log`。TSan が load されたことは `***** Running under ThreadSanitizer` が 30 回記録されていることで確認した)
- 退行検出 (negative control): `HandlerStorage` の get / set から `NSLock` を一時的に外して同じ手順で TSan 実行したところ、`testHandlerBagReadWriteRaceWithDelivery` の開始直後にプロセスが **`Child process terminated with signal 5: Trace/BPT trap` (exit 133 = 128 + signal 5) で abort** した (`build/0154-final-negative-control.log`。log には `***** Running under ThreadSanitizer` があり TSan が load されたことを確認できる)。lock を外した変更のみで abort し、lock を戻すと同じ test が成功する。`WARNING: ThreadSanitizer` の行は log に残っていないが、abort した時点の stack は `testHandlerBagReadWriteRaceWithDelivery` を指している。abort の signal は実行ごとに変わり得る (別の実行では signal 4 / exit 132 だった)。確認後は lock を戻し、`HandlerStorage.swift` が元の内容と一致することを `diff` で確認した (この一時変更は commit しない)
- `git status --short`: `Sora/HandlerStorage.swift` (新規) と 4 つの `Sora/*.swift`、`SoraTests/ConcurrencyStressTests.swift`、`SoraTests/CameraVideoCapturerHandlersTests.swift` (新規)、`CHANGES.md`、`skills/sora-ios-sdk/SKILL.md`、`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と本 issue ファイルの変更 (別 issue の `issues/0135-*.md` は本 issue の対象外)

### 残った懸念

- `make lint` (SwiftPM plugin 経由の swiftlint) は sandbox の制約で実行できず、`swiftlint lint --strict` で代替した。CI では `make lint` が実行される。
- CI の `tsan` job は `SoraTests` 全体を対象とするため、本 issue 以外の未修正の競合 (`0135` / `0026` など) が残っている間は job 全体が失敗し得る。本 issue の判定はハンドラクラスを指す report が無いことで行う。
