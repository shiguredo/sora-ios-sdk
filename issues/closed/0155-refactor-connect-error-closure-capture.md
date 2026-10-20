# Sora.connect の設定エラー通知経路の non-Sendable closure capture を解消する

- Created: 2026-09-15
- Completed: 2026-09-28
- Priority: Low
- Branch: feature/refactor-connect-error-closure-capture
- Polished: 2026-09-28

## 目的

`Sora.connect` の設定エラー通知経路が非 `@Sendable` な接続 handler を `DispatchQueue.global()` の `@Sendable` block へ capture しており、Swift 6 言語モードで `#SendableClosureCaptures` 警告が出る。接続 handler を包む box を追加してこの警告を解消し、`0108` の Sora target warnings-as-errors ゲートを塞いでいる要因の 1 つを取り除く。

## 現状

`Sora/Sora.swift` の `Sora.connect` は、`ConnectionConfigurationSnapshot` の生成または `MediaChannel` の生成に失敗した場合に `ConnectionTask` を生成して `complete()` を呼んだ後に、`DispatchQueue.global().async` の中で接続 handler と `Sora.handlers.onConnect` を呼ぶ。この catch が受けるのは次の 3 種である。

- `SoraError.configurationError`: snapshot の JSON 化失敗と音声の組合せ制約違反
- `SoraError.mediaChannelError`: native peer connection factory の生成失敗と stereo audio media engine の保持失敗
- `SoraError.connectionBusy`: AudioSession profile の取得失敗 (競合エラー)

2026-09-28 の Xcode 26.6 / Swift 6.3.3 で `Sora/` を Swift 6 言語モードで型検査すると、次の警告が出る (`-D DEBUG` の有無で件数は変わらない)。

```
Sora/Sora.swift:197:9: warning: capture of 'handler' with non-Sendable type '(MediaChannel?, (any Error)?) -> Void' in a '@Sendable' closure [#SendableClosureCaptures]
```

- 診断が出るのは接続 handler の capture だけである。`error` は標準ライブラリで `Sendable` (`public protocol Error : Swift.Sendable`)、`weak self` の `Sora` は `Sendable` (現状は `@unchecked Sendable`、`0111` 完了後は checked) のため診断対象にならない
- `Sora/Sora.swift` の `#SendableClosureCaptures` はこの 1 件。Sora target 全体では 26 件で、残り 25 件の内訳は `Sora/PeerChannel.swift` 12 / `Sora/MediaChannel.swift` 5 / `Sora/CameraVideoCapturer.swift` 3 / `Sora/NativePeerChannelFactory.swift` 2 / `Sora/Utilities.swift` 1 / `Sora/DataChannel.swift` 1 / `Sora/ConnectionTimer.swift` 1 である。同じ型検査では他に `add '@preconcurrency'` 4 件 (WebRTC 3 / AVFoundation 1) と `#DeprecatedDeclaration` 17 件が出る (警告本体の総数は 47 件)
- `0108` の manifest gate (`.treatAllWarnings(as: .error)`) ではこの警告が error になる
- 同種の既存 box には `Sora/SignalingState.swift` の `SignalingQueueBlock` (private。直列 queue へ投入する) と `Sora/CameraVideoCapturer.swift` の `CameraOperationCompletionBox` (保持する closure の不変性と直列 queue への投入を根拠にする) がある

## 優先度根拠

`Sora/Sora.swift` の 1 箇所の警告解消であり、`0108` のゲートを単独で開けるものではないため Low とする。

## 前提となる issue

- `0102` (完了 2026-09-16): 接続設定を immutable な Sendable snapshot へ変換する。本 issue が変更する設定エラー経路は `0102` が確定させたものであり、待つ条件は無い。
- `0118` (完了 2026-09-25): E2E テストの concurrency 診断抑止の除去。本 issue の作業対象は Sora target の 1 箇所だけで、test target の warnings-as-errors ゲートには依存しない (同ゲートは `0118` から `0171` へ引き取らせた)。
- `0165` (open): `Sora.connect` の設定エラー経路の `ConnectionTask.complete()` と完了ログを変更する。本 issue と同じ block を触るため、先に完了した側が先にマージされ、後から着手する側が rebase する (`0165` が `complete()` を戻り値化しても、通知順序と配送先は変えない)。
- `0153` (open): `Sora.connect` の `webRTCConfiguration` 引数の型と既定値を変更する (公開シグネチャの変更)。同じ関数を触るため、先に完了した側が先にマージされ、後から着手する側が rebase する。
- `0171` (open): test target の warnings-as-errors ゲート。本 issue は `0171` に依存しないが、`## 変更対象` で `0171` 側の `0155` 参照を外し、本 issue を完了済みとして扱えるようにした。

同じ `Sora/Sora.swift` を触る `0111` は `SoraHandlers` の同期 storage を導入するが (`0110` は legacy handler の型を変えない)、本 issue は引数 `handler` だけを box に包み、`Sora.handlers.onConnect` は block の実行時点で読む形を維持するため、順序の制約は無い。

## 設計方針

- `Sora/Sora.swift` に private の box (`ConnectErrorHandlerBox`) を新設し、接続 handler だけを包んで `DispatchQueue.global().async` へ渡す。宣言形は `Sora/CameraVideoCapturer.swift` の `CameraOperationCompletionBox` に揃え、保持は `private let handler: (MediaChannel?, (any Error)?) -> Void`、`init(_ handler: @escaping (MediaChannel?, (any Error)?) -> Void)`、実行は `func callAsFunction(_ mediaChannel: MediaChannel?, _ error: (any Error)?)` とする。宣言位置は `Sora` クラスの宣言の後ろで `ConnectionTask` の宣言の近傍とする。
- box の安全性の根拠を日本語コメントに書く。根拠は次の 3 点の組み合わせであり、いずれか 1 つではない。
  - 保持する handler は `init` で確定した `let` で、この型は可変状態を持たず書き換えない (box 自身のフィールドアクセスは競合しない)
  - この box は設定エラー経路が元々 `DispatchQueue.global().async` の block で handler を 1 回だけ呼んでいた既存の capture を型で包み直すだけで、新しい並行性を導入しない (配送先・通知順序・呼び出し回数は変更前と同じ)
  - 1 つの block へ 1 回だけ渡して 1 回だけ呼ぶ使用契約である。これは型では強制されないため、複数の block へ渡したり 2 回以上実行したりしてはならない
- あわせて次をコメントに書く。コメント本文には issue 番号を書かない (規約によりソースコードへ issue 番号を持ち込まない)。次の各項目の括弧内は実装者向けの根拠であり、コメントには括弧の前の文だけを書く。
  - `@unchecked Sendable` を付けるのは「入れ物」である box だけであり、handler とその捕捉状態を `Sendable` にするものではない。捕捉状態の同期は、呼び出しスレッドを保証しない既存の挙動の下で利用者の責務である。box は handler を安全にするものではなく、既存の配送を型で表明するだけである
  - 実行スレッドの同一性・直列性は契約にしない (`0118` の「実行文脈が一致することを契約にしない」に従う)
  - 未完了の concurrency refactor を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならないという方針があるが、本 box は警告の出所を隠すものではない (`0108` の方針。`Sora.connect` の handler 引数の executor 契約を doc に書く作業は `0110` の担当であり、`0110` の doc 対象に引数 handler を含める追記を本 issue で行う)
- box が包むのは `Sora.connect` の引数 `handler` だけとする。`Sora.handlers.onConnect` は現在と同じく block の実行時点で `self?.handlers.onConnect?` として読む。
- 公開 API のシグネチャを変更しない。box は private のため公開 API baseline に現れず、baseline の再生成は不要である。doc コメントも変更しない (handler 引数の executor 契約の記述は `0110` の担当で本 issue のスコープ外。`swift-api-digester` の dump に doc コメントは含まれないため、doc の変更自体は baseline に差分を出さない)。
- `CHANGES.md` の `## develop` の主リスト (`[CHANGE]` → `[ADD]` → `[UPDATE]` → `[FIX]` の順) の既存 `[UPDATE]` 群の末尾 (`[FIX]` の直前) に次を追加する。コードブロックの先頭の 2 スペースはこの節の入れ子のためのもので、`CHANGES.md` へはインデントを外して追記する。

  ```
  - [UPDATE] `Sora.connect` の設定エラー通知経路の closure capture を解消する
    - 非 `@Sendable` な接続 handler を `DispatchQueue.global()` の closure が capture していたことによる `#SendableClosureCaptures` 警告を、handler を包む private の box で解消する
    - 公開 API と利用者の挙動の変更はない (通知順序と配送先は変わらない)
    - @t-miya
  ```

- 次は採らない。
  - 接続 handler の `@Sendable` 化 (`0110` が legacy handler の型を変えない方針のため)
  - `nonisolated(unsafe)` と `DispatchWorkItem` (どちらも警告は消えるが、診断を抑止した理由がコード上に残らないため)
  - 既存 box (`SignalingQueueBlock` / `CameraOperationCompletionBox`) の流用 (実行文脈が直列 queue で異なるため。`Sora/SignalingState.swift` は変更しない)

## スコープ外

- Sora target に残る他の `#SendableClosureCaptures` (2026-09-28 の実測は 25 件。内訳は「現状」)。これらの警告を解消する担当 issue が無く、本 issue の完了だけでは `0108` のゲートは成立しない。このうち `Sora/Utilities.swift` の 1 件は `Stopwatch` の削除に伴って消える見込みである (`0115` が pending。`0115` が先に完了している場合は件数が 1 件減る)。
- WebRTC / AVFoundation module 由来の `add '@preconcurrency' ...` 警告 (2026-09-28 の実測は 4 件。WebRTC 3 / AVFoundation 1)。同じく担当 issue が無く `0108` のゲートを塞いでいる。
- `Sora/Sora.swift` の `#DeprecatedDeclaration` 2 件 (`onDisconnectLegacy` と `allowBluetooth`)。どちらも `0108` の `.treatWarning("DeprecatedDeclaration", as: .warning)` により warning のまま残り、担当 issue は無い (`0138` は `onDisconnectLegacy` を対象外としている)。
- test target の warnings-as-errors ゲート (`0171`) と、handler 型の `@Sendable` 化・Sendable な event API (`0110`)、`SoraHandlers` の同期 (`0111`)。
- 残り 25 件と `add '@preconcurrency'` 4 件を扱う issue の起票。本 issue の作業には含めない (起票は `develop` に対して別途 `create-issue` で行う)。

## 変更対象

- `Sora/Sora.swift`: `ConnectErrorHandlerBox` の新設と、`Sora.connect` の設定エラー経路の投入方法の変更
- `SoraTests/ConnectConfigurationValidationTests.swift`: 通知順序・呼び出し回数・呼び出しスタック外・`onConnect` に届く error の reason の検証の追加
- `CHANGES.md`: `## develop` の主リストへの `[UPDATE]` の追記
- `issues/0108-update-swiftpm-language-mode.md`: `0155` を参照する 5 箇所 (「前提となる issue」の導入文と bullet、`## 設計方針` の残存警告の説明、`## 検証方針` の警告の内訳、`## 完了条件` の concurrency 系の列挙) を、本 issue が実装時点の `#SendableClosureCaptures` のうち `Sora/Sora.swift` の 1 件のみを解消する事実に合わせて更新する (2026-09-28 の実測は 26 件。`0115` が先に完了している場合は 1 件減るため、実装時に再計測する)。`0155` を外した結果 blocker が無いように読めないよう、残りの `#SendableClosureCaptures` と `add '@preconcurrency'` 4 件を解消する担当 issue の状況 (起票済みならその番号、未起票ならその旨) と、解消するまでゲートを有効化できない旨を書く。あわせて `## 検証方針` の警告の内訳 (2026-09-28 の型検査では 47 warning = `#SendableClosureCaptures` 26 + `add '@preconcurrency'` 4 + `#DeprecatedDeclaration` 17) を追記する。`0118` の 2026-09-25 の実測値 (53 warning / 22 error) は日付付きの記録なので書き換えず、その後に本 issue の解消結果を追記する。起票は `0108` の着手前までに `develop` で行う
- `issues/0171-update-soratests-warnings-as-errors.md`: `0155` を参照する 4 箇所を次のとおり更新する。
  - test target ゲートの委譲元の説明 (「`0108` の検証方針と `0155` の前提が `0118` に委譲しており」): `0155` の前提には触れず、`0108` の検証方針と `0118` の旧記述が `0171` へ引き取らせた経路だけを書く
  - `Sora` target の concurrency 警告の担当一覧 (「`0108` / `0155` が扱う」): `0155` を外し、`0108` が扱うのは warnings-as-errors ゲートで、残りの `#SendableClosureCaptures` と `add '@preconcurrency'` 4 件は担当 issue が未起票 (起票済みならその番号) であることを書く。`0108` が残りを解消すると読める書き方はしない
  - `0155` の前提の該当文言を更新対象とする記述: `0155` の前提から当該文言は本 issue で既に消えているため、`0155` を編集対象から外す
  - test target ゲートの委譲先の完了条件 (「`0108` と `0155` の…」): `0155` を外し、`0108` の委譲先が `0171` に更新されていることを条件として残す
- `issues/0110-add-sendable-event-api.md`: legacy handler の executor 契約の doc 対象に `Sora.connect` の handler 引数も含めることを完了条件または設計方針に 1 行追記する (0110 の現行の記述は handler bag だけを対象にしており、本 issue が doc を変更しない理由を追跡できるようにする)

## テスト方針

モックやスタブは使用しない。既存の `SoraTests/ConnectConfigurationValidationTests.swift` を変更し、新しいテストファイルは追加しない。

- `testSoraConnectNotifiesConfigurationError` / `testSoraConnectNotifiesMetadataConfigurationError` は、`connect` が戻った時点で `task.state` が `.completed` であること、引数の handler に `SoraError.configurationError` が届くこと、`onAddMediaChannel` が呼ばれないことを既に固定している。`Sora.handlers.onConnect` 側の error は `XCTAssertNotNil` のみで種類を固定していない。次の追加・強化を行ったうえで回帰条件とする。記録用の変数の読み取りは `wait(for:)` の後だけにする (既存テストと同じ形)。
  - `Sora.handlers.onConnect` に届く error も、引数の handler と同じ `SoraError.configurationError` の reason であることを検証する
  - 引数の handler と `Sora.handlers.onConnect` がそれぞれ 1 回だけ呼ばれることをカウントで検証する (box の使用契約の回帰条件)
  - 通知が `connect` の呼び出しスタック内の同一スレッドで行われないことを、呼び出しスレッドの識別で検証する。`connect` を呼ぶ直前に一意なキー (例 `jp.shiguredo.sora.tests.connectCallStackMarker`) で thread dictionary の目印を立て、`connect` が戻った直後に `removeObject(forKey:)` で消し (テスト関数の `defer` では `wait` の後まで残るため使わない)、両 handler の先頭でその目印が無いことを assert する。`DispatchQueue.global().sync` の block が呼び出し元スレッドで実行される場合は、block 内での直接呼び出しと合わせて検出できる (libdispatch は実行スレッドを保証しないため、worker thread で実行された場合は次と同じ扱いになる)。一方、別スレッドで handler を実行して `connect` 側がその完了を待つ退行は検出できない (handler が `connect` の戻り前に完了していることは既存の expectation では区別できない)。本検証は設定エラー経路の回帰条件であり、他の経路 (`MediaChannel.connect` の busy ガードは handler を同期で呼ぶ) へ流用しないことをテストのコメントに書く
- 通知順序 (引数の handler → `Sora.handlers.onConnect`) を固定するテスト `testSoraConnectNotifiesConfigurationErrorInOrder` を 1 件追加する。引数の handler の末尾で「呼ばれた」ことを記録し、`Sora.handlers.onConnect` の先頭でその記録を読んだ結果を別の変数に記録して、`wait` の後に「引数の handler が呼ばれた」「`onConnect` の時点で引数の handler が呼び出し済み」を assert する。既存と同じく両方の通知を期待する expectation を使うため、`onConnect` が呼ばれない場合は timeout で失敗する。
- `Sora/` 全体を Swift 6 言語モードで型検査し、実装前の tree で取った `build/0155-typecheck-before.log` と実装後の `build/0155-typecheck-after.log` を比較する。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行する。`-F` には `swift package resolve` が作る xcframework の slice ディレクトリを指定する (`sora-ios-sdk` の部分は checkout ディレクトリ名に読み替える。fresh な checkout では先に `swift package resolve` を実行する)。before の log は同じコマンドの `tee` 先だけを `build/0155-typecheck-before.log` にして実装前に取得する。

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0155-typecheck-after.log
  test "$(grep -cE '^Sora/Sora\.swift:[0-9]+:[0-9]+: warning: .*SendableClosureCaptures' build/0155-typecheck-after.log)" = 0
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning: .*SendableClosureCaptures' build/0155-typecheck-after.log)" \
     = "$(($(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning: .*SendableClosureCaptures' build/0155-typecheck-before.log) - 1))"
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning:' build/0155-typecheck-after.log)" \
     = "$(($(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning:' build/0155-typecheck-before.log) - 1))"
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: error:' build/0155-typecheck-after.log)" = 0
  ```

- 0108 の gate は `Package.swift` の `swiftSettings` 経由の build で評価されるため、実行できる環境では `make build` の log でも `Sora/Sora.swift` の `capture of` 警告が 0 行であることを確認する (`xcodebuild` の診断には group 名が付かず、他の file の `capture of 'handler'` も残るため、file 名で限定する)。SwiftPM の cache に書き込めない環境では `make build` が依存解決で失敗するため、その場合は `Sora/` の型検査の結果で代替し、代替した旨を「解決方法」に記録する。

  ```
  make build 2>&1 | tee build/0155-build.log
  test "$(grep -cE "Sora/Sora\.swift:[0-9]+:[0-9]+: warning: capture of 'handler'" build/0155-build.log)" = 0
  ```

- `SoraTests` を実行し失敗 0 件であること。まず対象テストだけを回し、その後に全体を回す。E2E は環境変数が無い場合 skip される。

  ```
  xcodebuild test -scheme Sora-Package -derivedDataPath build \
    -only-testing:SoraTests/ConnectConfigurationValidationTests \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE=
  xcodebuild test -scheme Sora-Package -derivedDataPath build \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE=
  ```

- `make consumer-build SCHEME=ConsumerCore` が成功し、`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること (baseline を再生成していないことの確認)。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/Sora.swift` の `Sora.connect` の設定エラー経路に、接続 handler を包む private な `@unchecked Sendable` の box があり、`## 設計方針` に書いた安全性の根拠 (不変性・新しい並行性を導入しないこと・1 つの block へ 1 回だけ渡す使用契約) と、`@unchecked Sendable` が入れ物だけに付き捕捉状態を `Sendable` にしないことが日本語コメントで書かれていること。
- `Sora/` の Swift 6 言語モードの型検査で、`Sora/Sora.swift` の `#SendableClosureCaptures` の警告本体が 0 行になり、Sora target の同警告と警告本体の総数が実装前の log よりそれぞれ 1 件だけ減り、error が 0 件であること。実行できる環境では `make build` の log でも `Sora/Sora.swift` の `capture of` 警告が 0 行であること (実行できない環境では代替した旨を「解決方法」に記録する)。
- `## テスト方針` に挙げた通知順序・呼び出し回数・呼び出しスタック外・`onConnect` に届く error の reason の検証が、追加・強化したテストで成功すること。
- 公開 API のシグネチャが変更されていないこと (`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空である)。
- `CHANGES.md` の `## develop` の主リストの `[UPDATE]` 群の末尾に、上記の文面のエントリ (`CHANGES.md` の書式に合わせてインデントを外したもの) が担当者の行 (`- @t-miya`) 付きで追加されていること。
- `issues/0108-update-swiftpm-language-mode.md` の `0155` の記述が、本 issue が実装時点の `#SendableClosureCaptures` のうち `Sora/Sora.swift` の 1 件のみを解消する事実に更新され、残りの警告を解消する担当 issue の状況 (起票済みならその番号、未起票ならその旨) と、解消するまでゲートを有効化できないことが書かれていること。
- `issues/0171-update-soratests-warnings-as-errors.md` の `0155` の記述 4 箇所が `## 変更対象` に書いた内容で更新され、担当一覧の残存警告の帰属が `0108` の更新文面と一致していること。
- `issues/0110-add-sendable-event-api.md` の doc の対象に `Sora.connect` の handler 引数が含まれること (0110 から本 issue の委譲を追跡できる)。
- `make consumer-build SCHEME=ConsumerCore`、`make fmt-lint`、`make lint` が成功すること。
- `SoraTests` の追加したテストと既存テストがすべて成功すること。

## 解決方法

`Sora/Sora.swift` の `Sora.connect` の設定エラー経路で、引数の接続 handler だけを包む private な `ConnectErrorHandlerBox` (`@unchecked Sendable`) を追加し、`DispatchQueue.global().async` の block では box 経由で handler を呼ぶようにした。`Sora.handlers.onConnect` は従来どおり block の実行時点で読む。box には `## 設計方針` の安全性の根拠と使用契約を日本語コメントで書いた。この box は `0108` の判定基準 (可変状態を持たず保持する値が `init` で確定した不変値 / 変更前から同じ非同期境界へ渡しており配送先・順序・呼び出し回数を変えず別系統の境界へ新たに渡さない / 保持するのは closure だけで SDK 内部の参照型を新たに保持しない) をすべて満たすため、`@unchecked Sendable` の例外として認める。

`SoraTests/ConnectConfigurationValidationTests.swift` の既存 2 テストは共通ヘルパー (`assertConnectNotifiesConfigurationError`) に集約し、呼び出し元スレッド外での通知 (thread dictionary の目印と positive control)、引数の handler と `Sora.handlers.onConnect` がそれぞれ 1 回だけ呼ばれること、`onConnect` に届く error の reason が引数側と一致することを検証した。通知順序を固定する `testSoraConnectNotifiesConfigurationErrorInOrder` を追加した。expectation は handler ごとに分け、fulfill は 1 回目の呼び出しだけにして、重複通知の退行が「回数の assert 失敗」として現れるようにした (expectation の over-fulfill による XCTest の API violation やテストバンドルの異常終了を起こさない)。あわせて、期待する error が届かない場合でも後続の assert をすべて実行できるよう、`guard` + `return` をやめて `configurationErrorReason(of:)` で reason を取り出す形にした。

検証 (2026-09-28、Xcode 26.6 / Swift 6.3.3):

- `Sora/` の Swift 6 言語モードの型検査: warning 本体 47 → 46 件、`#SendableClosureCaptures` 26 → 25 件、error 0 件。`Sora/Sora.swift` の警告は deprecation 2 件のみ (`build/0155-typecheck-before.log` / `build/0155-typecheck-after.log`。after は変異テストの実施後に同じコマンドで再取得し、件数が変わらないことを確認した)
- `make build`: 成功。build log の `Sora/Sora.swift` の `capture of 'handler'` 警告は 0 行 (`build/0155-build.log`)
- テスト: 対象 7 件・全体 392 件が失敗 0 件 (30 件 skip) (`build/0155-tests-polish.log` / `build/0155-tests-polish-full.log`)
- 変異テスト (重複通知 / 同期通知 / `onConnect` にだけ error を届けない) で、いずれも通常の assert 失敗として検出され、API violation とテストバンドルの異常終了が 0 件であることを実測 (`build/0155-polish-m1.log` / `build/0155-polish-m3.log` / `build/0155-polish-m4.log`。over-fulfill 対策と早期 return の廃止を入れる前の記録は `build/0155-f4-mutation.txt` / `build/0155-i5-mutation.txt`)
- `make consumer-build SCHEME=ConsumerCore`: 成功。`make api-check-fresh`: baseline 一致。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` は差分なし (`build/0155-api-check-fresh.log`)
- `make fmt-lint` / `make lint`: 0 violations (`build/0155-fmt-lint.log` / `build/0155-lint.log`)

残っている作業と制約:

- `## テスト方針` の「記録用の変数の読み取りは `wait(for:)` の後だけにする」は error の記録に対して守り、呼び出し回数のカウントは重複通知を handler 内で検出する必要があるため handler 内でも読み取って assert する (読み書きは同じ handler 実行スレッド内に閉じる)。並行に重複通知する退行はこのカウントでは検出できない (現行実装は 1 つの block から逐次に呼ぶ)
- 配送先の変更 (`DispatchQueue.global()` から別の queue へ) と、別スレッドで handler を実行して `connect` 側がその完了を待つ退行は、目印方式では検出できない (実行スレッドの同一性・直列性を契約にしないため、テストでは固定しない)
- `Sora.handlers.onConnect` の実行時読み (block 実行時点の読み取り) はテストでは固定していない
- `mediaChannelError` / `connectionBusy` の経路は、box と通知コードが error 種別に依存しないため本 issue では追加検証していない
- `issues/0108-update-swiftpm-language-mode.md` の残存警告の担当内訳の確定と実測値の tree の明示は `issues/0173-refactor-remove-sora-sendable-closure-captures.md` の `## 変更対象` が担当する (本 issue では `0155` の参照、担当 issue が未起票である旨、`0157` の重複 bullet の削除、`0155` / `0157` の件数記述、`## 前提となる issue` の導入文を更新した)
- `issues/0171-update-soratests-warnings-as-errors.md` の `0155` 参照 4 箇所と、`issues/0110-add-sendable-event-api.md` の doc の委譲 (引数 handler と `skills/sora-ios-sdk/SKILL.md`) も本 issue で更新した
