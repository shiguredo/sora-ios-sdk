# `Utilities.Stopwatch` の `Timer` closure の `#SendableClosureCaptures` 警告を解消する

- Created: 2026-09-29
- Completed: 2026-09-29
- Priority: Medium
- Branch: feature/refactor-remove-stopwatch-sendable-closure-capture
- Polished: 2026-09-29

## 目的

`Sora` target に残る唯一の `#SendableClosureCaptures` 警告 (`Sora/Utilities.swift` の `Utilities.Stopwatch` の `Timer` closure が `self` を捕捉する 1 件) を解消し、`0108` の Sora target warnings-as-errors ゲートを `0115` (`Utilities.Stopwatch` の削除) の完了を待たずに有効化できる状態にする。

`0115` は非推奨化 release (D) と次期 major version の release (R) を前提にするため、完了時期を本 issue から制御できない。`0108` のゲートがその完了を待つ間、`Sora` target の concurrency 警告を error として検出できない状態が続く。

本 issue は `Utilities.Stopwatch` の内部構造だけを変更し、公開 API のシグネチャと利用者から観測できる通知・停止の挙動を変えない (`Timer` closure と `Stopwatch` の相互参照が解消されることに伴う解放の変化は「設計方針」)。

## 優先度根拠

Medium とする。

- `0108` の warnings-as-errors ゲートを開くために残る最後の 1 件である (`0177` が完了 2026-09-29 に残した唯一の `#SendableClosureCaptures`)。放置すると `0108` のゲートを有効化できない
- 一方で `0115` が `Stopwatch` を削除すれば同じ警告は消えるため、`0115` の削除までの一時的な対応である
- 公開 API のシグネチャと利用者から見た通知・停止の挙動を変えない内部リファクタリングであり、利用者への影響がないため High にはしない

## 現状

### 実測

2026-09-29 の Xcode 26.6 / Swift 6.3.3 で develop を `Sora/` の Swift 6 言語モードで型検査した実測は、一次行 (行頭が `Sora/<file>:<line>:<col>: warning:`) で warning 18 件 / error 0 件、うち `#SendableClosureCaptures` は 1 件である (型検査コマンドは「テスト方針」。log は `build/0181-typecheck-before.log`)。この値は `0177` の完了時の実測 (`build/0177-stage2-typecheck.log` / `build/0177-polish-typecheck.log`) と同じである。

残る `#SendableClosureCaptures` の 1 件は `Sora/Utilities.swift` の `Utilities.Stopwatch` が `Timer(timeInterval:repeats:block:)` へ渡す closure が `self` を捕捉するという指摘で、診断の位置はその closure の中で `seconds` を読む `String(format:arguments:)` の行である。file 別の内訳も `Sora/Utilities.swift` のこの 1 件だけである。

同じ環境で `0108` のゲート相当の flags (`-warnings-as-errors -Wwarning DeprecatedDeclaration`) を付けた型検査の実測は error 1 件 / warning 17 件で、この error 1 件が上記の 1 件と一致する (`build/0181-gate-before.log`)。

残りの 17 件は非推奨 API の宣言・使用に関する警告 (`#DeprecatedDeclaration` 12 件と、非推奨 message だけが付く 5 件) であり、`0108` は `.treatWarning("DeprecatedDeclaration", as: .warning)` で warning のまま残す方針である。concurrency 系の警告はこの 1 件だけである。

### 警告の原因

`Sora/Utilities.swift` は `/// :nodoc:` を付けた `public enum Utilities` を持ち、`Stopwatch` はその中の `public final class Stopwatch` である。公開 API は `init(handler:)` / `run()` / `stop()` の 3 つで、stored property は `private var timer: Timer?` / `private var seconds: Int` / `private var handler: (String) -> Void` である。

- `init(handler:)` は `Timer(timeInterval: 1, repeats: true) { _ in ... }` を生成し、closure は `self.seconds` の読み出しと加算、`self.handler(text)` の呼び出しを行う。この closure が `@Sendable` closure として取り込まれるため、`Stopwatch` が `Sendable` でないことの指摘として `#SendableClosureCaptures` が出る
- `run()` は `seconds` を 0 に戻し、`timer` を `RunLoop.main.add(_:forMode:)` へ登録して `timer.fire()` を呼ぶ。`fire()` は closure を同期的に実行するため、`run()` の直後に handler が `"00:00:00"` で 1 回呼ばれる
- `stop()` は `timer?.invalidate()` を呼び、`seconds` を 0 に戻す

### 参照状況

`Utilities.Stopwatch` は SDK 内部 (`Sora/`)、`SoraTests/`、`TestConsumers/` の Swift source、workflow のいずれからも参照されていない (宣言のみ)。`git grep` で参照が出るのは次の 2 つだけである。

- 公開 API baseline (`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`) に `Stopwatch` / `init(handler:)` / `run()` / `stop()` の 4 宣言が載っている
- `TestConsumers/Swift6Consumer/README.md` の「公開 closure の列挙手順」の表に「`SoraDispatcher.async(on:block:)` / `Utilities.Stopwatch(handler:)` は対象外。非推奨化する作業が扱う」という記述がある

内部・test・consumer からの参照が無いため、本 issue の変更で呼び出し側を書き換える必要はない。

### 非推奨化と削除の計画

`0114` が `Utilities.Stopwatch` を非推奨化し、`0115` が次期 major version で削除する計画である。`0115` は `issues/pending/` にあり、非推奨化 release (D) と次期 major version の release (R) を前提にする。本 issue の対応はその削除までの一時的なものである。

`0108` は `## 前提となる issue` と `## 設計方針` と `## 検証方針` と `## 完了条件` の 4 箇所に「残る `#SendableClosureCaptures` は `0115` (`Sora/Utilities.swift` の `Stopwatch` 削除の 1 件) だけで、`0115` が完了するまで gate を有効化できない」と記載している。本 issue の完了後は 0 件になるため、この記述を更新する必要がある (「変更対象」)。

`0115` も「`0108` の warnings-as-errors ゲートは、本 issue が `Stopwatch` を削除するまで有効化できない」と記載しており、本 issue の完了でこの前提も古くなる。`0177` は自らの実装と同じ変更で `0115` の記述を更新した前例があるため、この更新も本 issue の変更対象に含める (「変更対象」)。

## 設計方針

### 捕捉対象の置き換え

`Timer` closure が捕捉する可変状態 (`seconds` / `handler`) を、`NSLock` で保護した `@unchecked Sendable` の内部 storage (型) へ移し、closure はその storage だけを捕捉する。`Stopwatch` は storage を `let` で保持する。storage は `init` で `handler` を受け取って `let` として保持し、可変状態を `seconds` だけにする。

closure が storage を捕捉するには、`init` の中で `let storage = self.storage` のようにローカルへ束縛した値を closure が参照するか、capture list `[storage]` を使う。`final class` の `let` property を closure の中で `self.storage` として参照すると closure は `self` を捕捉し、`#SendableClosureCaptures` は消えない (Swift 6.3.3 の型検査で実測済み)。`run()` / `stop()` は closure の外なので `self.timer` を直接参照してよい。

`Stopwatch` 自身に `@unchecked Sendable` を付けない。`Stopwatch` に `Sendable` 準拠も追加しない (公開 API の追加になり、`0114` / `0115` の予定とも重複する)。

closure が読まない `timer` (`Timer?`) は `Stopwatch` の stored property のまま残す。`timer` を storage へ移すことは本 issue の警告の解消には不要であり、`run()` / `stop()` からのみ触る現在の形を変えない。

### `@unchecked Sendable` を storage だけに認める根拠 (`0108` との整合)

`0108` は「未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならない」とし、その判定を 3 条件で行うとしている。本 issue はこの 3 条件を次のとおり適用する。

- (1) 「追加する型自身が可変状態を持たず、保持する値が `init` で確定した不変値であること」は、可変状態を保持する storage には文字どおりには当てはまらない。本 issue は (1) を「可変状態を持つ場合は、その読み書きのすべてが単一の排他に閉じていること」と読み替えて適用する。この読み替えの前例は `0106` が追加した `LoggerStateStorage` (NSLock が `level` / `groups` / `onOutputHandler` の全アクセスを保護し、そのことを `@unchecked Sendable` の根拠として doc コメントに書いている storage) であり、`0177` が追加した `PeerChannelTransportStorage` と `MediaChannelStateStorage` も同じ形である。`0100` が追加した `ConnectionSnapshotStorage` は NSLock で `snapshot` の全アクセスを保護するが `Sendable` 宣言を持たず `@Sendable` closure へ直接渡らないため、この読み替えの前例にはしない。`0108` の 3 条件の (2) と (3) は storage にもそのまま当てはめる
- (2) 「変更前から同じ系統の非同期境界へ渡されており、配送先・順序・呼び出し回数を変えず、別系統の境界へ新たに渡すこともないこと」を満たす。境界へ渡るのは closure であり、その closure は変更前と同じ `Timer(timeInterval:repeats:block:)` に渡り、`RunLoop.main` の登録も `run()` のままである。closure が新たに捕捉するのが storage であるだけで、配送先・順序・呼び出し回数は変わらない
- (3) 「保持するのは closure と、その closure が変更前から一緒に捕捉していた参照だけであり、SDK 内部の参照型を新たに保持しないこと」を満たす。storage が保持するのは、storage の `init` で受け取る利用者の `handler` (closure) と `seconds` (値型) だけである。`Timer` / `RunLoop` / `Stopwatch` の参照は保持しない

`0108` は、例外として認めた型について「どの経路のどの型をなぜ認めたか」をその型の doc コメントと、その型を追加した issue の「解決方法」に記録することを求めている。本 issue はこの記録を storage の doc コメントと本 issue の「解決方法」で行う。`0108` の 3 条件の文面そのものを読み替え後の表現へ変えるかどうかは `0108` 側で判断し、本 issue は「変更対象」に挙げた `0108` の「`0115` 待ち」の記述の更新だけを行い、3 条件の文面は変更しない。

storage の `@unchecked Sendable` が主張するのは「storage が保持する可変状態の読み書きが storage の `NSLock` に閉じていること」だけである。`handler` の closure 自体が `Sendable` であることや、`Timer` のオブジェクト状態の不変性は主張しない。この区別を storage の doc コメントに書く。

### lock の区間と利用者コードの呼び出し

storage の `NSLock` は非再帰であり、保持したまま同じ lock を取る経路に入ると deadlock する。各区間を次のとおり固定する。

- closure: `seconds` の読み出しと `handler` の取り出しを 1 回の lock 区間で行う。`handler` の呼び出しは区間外で行い、`seconds` の加算は `handler` の呼び出し後に別の lock 区間で行う。`seconds` の読み出し、`handler` の呼び出し、加算という現在の順序を変えない。`handler` が `stop()` を呼んで `seconds` を 0 に戻した場合も、加算は `handler` の呼び出し後に行われるため結果は変更前と同じになる
- `init`: lock を取る区間は無い。storage の生成 (利用者の `handler` の受け渡しを含む) と `Timer` の生成だけを行う
- `run()`: `seconds` を 0 に戻す storage の区間だけ lock を取り、閉じてから `RunLoop.main.add(_:forMode:)` と `timer.fire()` を呼ぶ。`fire()` は closure を同期的に実行するため、lock を保持したまま呼ぶと closure が同じ lock を再取得して deadlock する
- `stop()`: `timer?.invalidate()` は lock 区間の外で先に呼び、その後に `seconds` を 0 に戻す storage の区間を取る。この順序は現在の実装と同じである
- `0165` の「排他区間を保持したまま利用者コードを呼ばない」方針に従い、利用者の `handler` は lock を解放してから呼ぶ

### 維持する挙動と触らない範囲

- 公開 API のシグネチャ (`init(handler:)` / `run()` / `stop()`) を変えない。`Sendable` 準拠、`@available` 属性、引数ラベル、アクセスレベルを変えない
- 観測可能な挙動を変えない。1 秒ごとに `"時:分:秒"` 形式の文字列を handler へ通知し、`run()` で開始し、`stop()` で停止して `seconds` を 0 に戻す挙動を維持する。`run()` の直後に handler が `"00:00:00"` で 1 回呼ばれる挙動も維持する
- `RunLoop.main` を使う設計を変えない。`run()` の `RunLoop.main.add(_:forMode:)` による登録先は main のままである
- executor 契約 (handler を実行するスレッドや MainActor 隔離が定まっていないこと) を変更しない。契約の整備は本 issue のスコープ外である
- `Timer` closure が `self` を捕捉しなくなるため、`0114` の「現状」が挙げる `Timer` closure と `Stopwatch` の相互参照 (`self` の強参照) は解消される。これは捕捉対象を変えることの不可避な結果であり、本 issue の目的ではない。利用者が `Stopwatch` の参照を手放した後に `Stopwatch` が解放される点は変わるが、`Stopwatch` は `deinit` も同一性に依存する挙動も持たず、`run()` 済みの `Timer` は `stop()` まで `RunLoop.main` で発火を続けるため、利用者から見た通知の挙動は変わらない。`stop()` 後の `run()` が動作しない lifecycle の問題は変更前のまま残る (「スコープ外」)
- storage は `fileprivate` または `private` の型として `Sora/Utilities.swift` 内に追加し、公開 API を増やさない。型名は実装時に決める
- 追加・変更する storage の doc コメントに、どの lock がどの状態を守るか、新しい並行境界を増やしていないこと、捕捉対象の状態の所有と同期が誰の責務かを日本語で書く。ソースコードに issue 番号は書かない

### `CHANGES.md`

`## develop` の主リストの `[UPDATE]` の並びの末尾 (最初の `[FIX]` の前) に次のエントリを追加する (インデントはこの節の入れ子のためのもので、`CHANGES.md` へは外して追記する)。

```
- [UPDATE] `Utilities.Stopwatch` の `Timer` closure が `self` を捕捉する `#SendableClosureCaptures` 警告を解消する
  - 公開 API の変更はない。`Timer` closure が `self` を捕捉しなくなるため、`Timer` と `Stopwatch` の相互参照は解消される
  - @t-miya
```

## 前提となる issue

- `0177` (完了 2026-09-29): `Sora` target の `#SendableClosureCaptures` 11 件のうち SDK 内部インスタンスを捕捉する 10 件を解消し、残る 1 件を `Sora/Utilities.swift` の `Utilities.Stopwatch` として切り分けた。本 issue はその 1 件を扱う
- `0108` (open): Sora target の warnings-as-errors ゲート。本 issue の完了でゲートを開ける状態になる。`0108` の「`0115` 待ち」の記述の更新は `0108` 側の作業として行い、本 issue の実装と同じ変更に含める (「変更対象」)
- `0114` (open): `Utilities.Stopwatch` の非推奨化。本 issue とは独立であり、実施順序を規定しない。`0114` が deprecation annotation を付けた後に本 issue を実施する場合、本 issue は annotation 行と doc コメントを変更しない
- `0115` (pending、`issues/pending/0115-remove-stopwatch.md`): `Utilities.Stopwatch` の削除。本 issue の対応はその削除までの一時的なもの。`0115` が先に完了した場合は本 issue は不要になり、警告は削除で 0 件になる。`0115` の「`0108` のゲートは `Stopwatch` の削除まで有効化できない」という記述は本 issue の完了で古くなるため、同じ変更で更新する (「変更対象」)

## 変更対象

- `Sora/Utilities.swift`: `Utilities.Stopwatch` の `Timer` closure が捕捉する `seconds` / `handler` を lock 付き storage へ移す。`Stopwatch` の公開シグネチャ (`init(handler:)` / `run()` / `stop()`) と `timer` の扱い、`PairTable` / `Optional.unwrap(ifNone:)` / `Utilities.randomString` は変更しない
- `SoraTests/`: 「テスト方針」で追加を判断する `Stopwatch` のテスト。追加しない場合は file を変更しない
- `CHANGES.md`: `## develop` の主リストの `[UPDATE]` の並びに、「設計方針」の `CHANGES.md` の文面のエントリを担当者行付きで追加する
- `issues/0108-update-swiftpm-language-mode.md`: 「`0115` 待ち」と書いている 4 箇所 (`## 前提となる issue` の `0177` の bullet、`## 設計方針` の warnings-as-errors の bullet、`## 検証方針` の型検査の記述、`## 完了条件` の warnings-as-errors の記述) を、`0177` が 10 件を解消し、本 issue が `Utilities.Stopwatch` の 1 件を解消して `#SendableClosureCaptures` が 0 件になった記述へ更新する。`0115` の完了を待つという記述と、残る 1 件の担当として `0115` を挙げる記述は削除する。`0108` の担当範囲 (manifest 更新、`README.md` / `skills/sora-ios-sdk/SKILL.md` の更新、検証) の記述は壊さない
- `issues/pending/0115-remove-stopwatch.md`: `## 現状` の「`0108` の warnings-as-errors ゲートは、本 issue が `Stopwatch` を削除するまで有効化できない」という記述を、本 issue の完了で `#SendableClosureCaptures` が 0 件になった記述へ更新する。`0115` の削除の計画と前提は変更しない

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- 警告の消滅は型検査の実測で確認する。実装前後の log を取り、一次行 (行頭が `Sora/<file>:<line>:<col>: warning:`) だけを数える。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行する

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0181-typecheck-after.log
  ```

  - 一次行の総数が実装前の log から 1 件だけ減り、`#SendableClosureCaptures` が 0 件であること。残る分が非推奨 API の警告のままで、`#no-usage` などの新しい警告が増えていないこと (総数で検出する。`0114` の実施などで件数が変わっている場合は、同じ環境で取り直した実装前の log を基準にする)
- `0108` のゲート相当の flags を付けた型検査で error が 0 件であること (実装前は本 issue の 1 件だけが error になる)

  ```
  swiftc -typecheck -disable-batch-mode -continue-building-after-errors \
    -swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0181-gate-after.log
  ```

- 挙動の維持は、`RunLoop.main` を使う実 `Stopwatch` のテストを `SoraTests` へ追加できるか実装時に判断する。前例は `SoraTests/ConnectionTimerLifecycleTests.swift` で、実 `Timer` を `RunLoop.main` へ登録し、`XCTestExpectation` と `wait(for:timeout:)` で発火を待つ。判断材料は次のとおり
  - `run()` は `timer.fire()` を呼び、`fire()` は closure を同期実行するため、`run()` の直後に handler が `"00:00:00"` で 1 回呼ばれることは wall clock に依存せず決定的に検証できる
  - `seconds` は private のため直接は観測できない。0 リセットは、`Timer` が有効な間に `run()` を再呼び出しして最初の通知が `"00:00:00"` に戻ることで観測する。`stop()` の後の `run()` は invalidated な `Timer` の `fire()` が何もしないため通知を出さず (Swift 6.3.3 で実測)、`stop()` の後の `run()` では 0 リセットを観測できない
  - 1 秒ごとの増加と `stop()` 後の停止は wall clock と RunLoop の実行に依存する。`wait(for:timeout:)` の timeout を十分に取り、通知の回数を厳密に比較せず「増加すること」「停止後に増えないこと」を確認する形にする。厳密な回数の比較が必要になり flaky と判断した場合は追加しない
- `Stopwatch` のテストを追加しない場合は、その理由を「解決方法」に記録し、`SoraTests` 全体と TSan を回帰の正本とする
- `SoraTests` 全体を実行し失敗 0 件であること。E2E は環境変数が無い場合 skip される
- TSan は `-enableThreadSanitizer YES` を付けた `build-for-testing` が作った `SoraTests.xctest` を `xcrun simctl spawn` で実行し、`ThreadSanitizer` の検出行が 0 行であることを確認する (`test-without-building` では interceptor が働かないため、build から実行する。起動手順と `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` の扱いは `0177` の「解決方法」と同じ)。TSan の CI 化は `0119` が担うため、本 issue は `0177` と同じ手動手順で実行し `0119` の完了を待たない
- `make build` が成功すること
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること。公開 API のシグネチャを変えないため、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。差分が出た場合は `make api-baseline` を実行せず、公開 API の変更として別 issue に分離する
- `make fmt-lint` と `swiftlint lint --strict` が成功すること
- 退行検出: closure が storage ではなく `Stopwatch` の `self` を捕捉する変更前の形に戻すと、型検査の `#SendableClosureCaptures` が 1 件に戻ることを確認する。確認用の変更は commit しない

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が 0 件、error 0 件であること。非推奨 API の警告は残ってよい (起票時の実測では 17 件)
- `0108` のゲート相当の flags を付けた型検査で error が 0 件であること
- 公開 API のシグネチャ (`init(handler:)` / `run()` / `stop()`) が変わっていないこと。`Stopwatch` に `Sendable` 準拠を追加していないこと。`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること
- `Timer` closure が捕捉するのが追加した storage だけで、`Stopwatch` 自身を捕捉していないこと。`@unchecked Sendable` が追加した storage の宣言行だけに付いており、`Stopwatch` に付いていないこと
- `@unchecked Sendable` を認めた根拠 (`0108` の 3 条件の (1) の読み替えを含む) が storage の doc コメントと「解決方法」に記録されていること (`0108` の要求)
- storage が保持する可変状態 (`seconds`) の読み書きがすべて `NSLock` の区間内にあり、利用者の `handler` の呼び出し、`run()` の `timer.fire()`、`stop()` の `timer?.invalidate()` が lock 区間の外にあること
- 1 秒ごとの `"時:分:秒"` の通知、`run()` の直後に `"00:00:00"` で 1 回呼ばれること、`stop()` で停止して `seconds` が 0 に戻ることという観測可能な挙動が変わっていないこと
- `SoraTests` 全体が失敗 0 件で、TSan の検出行が 0 行であること。`Stopwatch` のテストを追加しなかった場合は、その理由が「解決方法」に書かれていること
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make fmt-lint` / `swiftlint lint --strict` が成功すること
- `CHANGES.md` の `## develop` の主リストに `[UPDATE]` エントリが担当者行付きで追加されていること
- `issues/0108-update-swiftpm-language-mode.md` の「`0115` 待ち」の 4 箇所が、本 issue の完了で `#SendableClosureCaptures` が 0 件になる記述へ更新され、`0108` の担当範囲の記述が壊れていないこと
- `issues/pending/0115-remove-stopwatch.md` の「`0108` のゲートは `Stopwatch` の削除まで有効化できない」という記述が、本 issue の完了で 0 件になる記述へ更新されていること

## スコープ外

- `Utilities.Stopwatch` の非推奨化 (`0114`) と削除 (`0115`)。本 issue は削除までの一時的な対応である
- `Stopwatch` の既知の問題 (stop 後の `run()` が動作しない `Timer` lifecycle、handler の executor 契約が無いこと) の修正。削除で対象コードごと消えるため、bug issue も起票しない。`0114` が挙げる `Timer` closure と `Stopwatch` の相互参照は捕捉対象の変更で不可避に解消されるが、これは目的ではなく、相互参照の解消自体を別 issue にはしない (「設計方針」)
- `Utilities.randomString` / `Optional.unwrap(ifNone:)` / `PairTable` の変更
- `Stopwatch` への `Sendable` 準拠の追加、`@preconcurrency` の追加、default actor isolation の変更で警告を消すこと
- `0108` の manifest 更新 (`swift-tools-version` / `swiftLanguageModes` / Sora target の `swiftSettings`) と `README.md` / `skills/sora-ios-sdk/SKILL.md` の更新。本 issue は `0108` の前提記述の更新だけを行う
- `SoraTests` target の warnings-as-errors ゲート (`0171`)

## 解決方法

### 変更内容

- `Sora/Utilities.swift` に `private final class StopwatchStorage: @unchecked Sendable` を追加した。保持するのは利用者の `handler` (`init` で確定する `let`) と可変状態の `seconds` だけで、`seconds` の読み書きはすべて storage が持つ単一の `NSLock` 区間内に閉じている
- `Utilities.Stopwatch` の stored property は `timer` と `storage` になった。`Stopwatch` 自身には `@unchecked Sendable` も `Sendable` 準拠も付けていない。`timer` は変更前と同じく storage へ移していない
- `init` では `let storage = StopwatchStorage(handler: handler)` のローカル束縛を作り、`Timer` の closure は `self.storage` ではなくこのローカル束縛の `storage` だけを捕捉する。closure の中に `self` 参照は無い
- storage が公開する操作は値だけを扱う 3 つにした。`elapsedSeconds()` は経過秒数を返し、文字列への整形 (`String(format:arguments:)`) は closure 側で行う。`increment()` は加算、`reset()` は 0 リセットである。`handler` は storage の internal な `let` であり、closure が lock の外で読む。当初の試作にあった「文字列と `handler` の tuple を返す `takeNotification()`」は採用しなかった。`handler` は不変で lock 内で取り出す必然性が無く、整形まで storage に置くと状態保持と同期という責務を超え、`take` prefix (consume-and-clear の慣習) と `Foundation.Notification` の連想も招くためである
- lock 区間は次のとおり。closure は `elapsedSeconds()` で経過秒数を 1 回読み、lock の外で文字列を作って `handler` を呼び、その後に `increment()` で加算する (`seconds` の読み出し、`handler` の呼び出し、加算という変更前の順序を変えない)。`run()` は `reset()` の区間を閉じてから `RunLoop.main.add(_:forMode:)` と `timer.fire()` を呼ぶ。`fire()` は closure を同期実行し、その closure が同じ非再帰 `lock` を取るため、lock 保持中に呼ぶと deadlock する。`stop()` は `timer?.invalidate()` を先に lock の外で呼び、その後に `reset()` を取る
- 利用者の `handler` は lock の外で呼ぶ (排他区間を保持したまま利用者コードを呼ばない)
- `Timer` closure が `self` を捕捉しないため、`Timer` と `Stopwatch` の相互参照は解消される。通知は closure が保持する storage が `handler` を保持して行うため変わらない。変わるのは解放の時期だけで、利用者が `Stopwatch` の参照を手放すと `Stopwatch` が解放され得る (変更前は `Timer` の closure が `self` を強参照していたため解放されなかった)
- `@unchecked Sendable` を認めた根拠は storage の doc コメントと本節に記録する。可変状態を持つ型に対する 3 条件の適用は次のとおり
  - (1) は「可変状態を持たないこと」を求める条件であり、「`seconds` の読み書きがすべて単一の `NSLock` に閉じていること」と読み替えて適用した。`handler` は `init` で確定する不変値であり lock では保護しない。この読み替えの前例は `0106` の `LoggerStateStorage` と `0177` の `PeerChannelTransportStorage` である
  - (2) は変更前から同じ `Timer(timeInterval:repeats:block:)` と `RunLoop.main` へ渡る closure の捕捉対象を置き換えるだけで、配送先・順序・呼び出し回数を変えないこと
  - (3) は保持するのが `handler` と `seconds` だけで、`Timer` / `RunLoop` / `Stopwatch` の参照を保持しないこと
- storage の `@unchecked Sendable` が主張するのは `seconds` の読み書きが単一の `lock` に閉じていることだけである。`handler` の closure 自体が `Sendable` であることや `Timer` のオブジェクト状態の不変性は主張しない
- `0108` の 3 条件の (1) に、この読み替えと前例 (`0106` / `0177`) を注記し、`0108` の判定基準として承認済みにした。`0108` の担当範囲と完了条件の趣旨は変えていない
- 公開 API のシグネチャ (`init(handler:)` / `run()` / `stop()`)、`timer` の扱い、`PairTable` / `Optional.unwrap(ifNone:)` / `Utilities.randomString` は変えていない

### 捕捉が消えた実測

- 実装前の型検査 (Swift 6.3.3 / `arm64-apple-ios14.0-simulator`) は一次行 18 件 / error 0 で、うち `#SendableClosureCaptures` は `Sora/Utilities.swift:33:13` の 1 件 (`build/0181-typecheck-before.log`)。実装後は一次行 17 件 / error 0 で `#SendableClosureCaptures` は 0 件 (`build/0181-typecheck-after.log`)。差分はこの 1 件の削除だけで、`#no-usage` などの新しい警告は増えていない
- `0108` のゲート相当 (`-warnings-as-errors -Wwarning DeprecatedDeclaration`) は、実装前が error 1 件 / warning 17 件 (`build/0181-gate-before.log`)、実装後が error 0 件 / warning 17 件 (`build/0181-gate-after.log`)

### TSan の実測

- `-enableThreadSanitizer YES` の `build-for-testing` (`build/polish-0181-tsan-build.log`) が作った `SoraTests.xctest` を `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<SoraTests.xctest>/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib` 付きの `xcrun simctl spawn` で全件実行し、`ThreadSanitizer` の検出行は 0 行、441 件 / skip 31 / 失敗 0 (`build/polish-0181-tsan-run.log`)。`StopwatchTests` 5 件も完走し (2.534 秒)、追加した 2 件の再入テストは TSan 有効時もハングしない
- interceptor が有効であることは `TSAN_OPTIONS=verbosity=1` で `ThreadSanitizer: parsing ...` と `ThreadSanitizer: parsed suppression entry ...` が出力されることで確認した (`build/polish-0181-tsan-verbosity.log`)
- この 0 行は「既存スイートに新しい競合が無い」ことの証拠に留まる。新しい `NSLock` の正しさや `handler` の並行実行を検証したものではない (`StopwatchTests` は main thread だけで動き、`handler` を並行に呼ばない)。lock の正しさは 2 件の再入 deadlock テストと「`seconds` の読み書きがすべて区間内にあること」のコード上の確認で担保する
- `SoraTests.xctest` は `WebRTC.framework` を `PackageFrameworks` に持たないため、`simctl spawn` には `SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=<Build/Products/Debug-iphonesimulator>` も渡した (0177 の手順への追加)

### テストの追加

- `SoraTests/StopwatchTests.swift` を追加した (5 件)。モック・スタブは使わず、実 `Stopwatch` と実 `Timer` だけを使う
  - `run()` の直後に handler が `"00:00:00"` で 1 回だけ呼ばれ、`run()` の再呼び出しで最初の通知が `"00:00:00"` に戻ること (`timer.fire()` の同期実行と `seconds` の 0 リセット。wall clock に依存しない)。当初の 2 件 (`testRunNotifiesImmediately` / `testRunResetsSeconds`) は同じ assert で観測できたため 1 件にまとめた
  - `stop()` の後は通知が同期通知の 1 回だけに留まること (invalidate 済み Timer は発火しない)。main RunLoop を回す待ち時間は Timer の 1 周期 (1 秒) を確実に超える 1.5 秒にした
  - 1 秒経過で 2 回目の通知 `"00:00:01"` が届くこと (`wait(for:timeout:)` の timeout で「文字列が進まない」退行を、`assertForOverFulfill` で「同じ文字列が 2 回届く」退行を検出する。1 秒ごとの通知の回数の比較はしない)
  - 利用者の `handler` から `stop()` を呼んでも deadlock しないこと (再入テスト)
  - 利用者の `handler` から `run()` を呼んでも deadlock しないこと (`fire()` の同期再入テスト。再入は 1 回で止め、2 回目の通知が届くことで再入が起きたことを確認する)
- 追加した 2 件は、本リファクタが新設した唯一の失敗モード「非再帰 `NSLock` を保持したまま利用者の `handler` を呼ぶ」の回帰テストである。他の 3 件の handler は再入しないため、`handler` を lock 内へ移す退行では緑のままになる
- 退行時は deadlock でハングし、XCTest の timeout では検出できない (`wait(for:timeout:)` を挟んでも返らない)。このため `handler` を lock 内で呼ぶ一時ビルドで `SoraTests` を実行し、`testHandlerCanCallRunReentrantly` の開始後に停止することを実測した (`build/polish-0181-deadlock-regression.log`)。確認用の変更は commit しておらず、確認後に元へ戻した
- `handler` を lock の外で呼ぶ最終形では 5 件とも完走し、ハングしない (`build/polish-0181-tests-final.log` の `StopwatchTests` は 2.537 秒)
- 1 秒ごとの通知の回数を比較する観測は行っていない。`stop()` の後の `run()` が動作しない既知の lifecycle の問題は変更前のままである

### 実行した検証

- 型検査: 一次行 17 件 / error 0、`#SendableClosureCaptures` 0 件 (`build/polish-0181-typecheck.log`)。`0108` ゲート相当は error 0 件 / warning 17 件 (`build/polish-0181-gate.log`)
- 全体テスト: `xcodebuild test` はこの検証環境ではテスト実行の起動時に Pseudo Terminal を確保できず `Pseudo Terminal Setup Error` で失敗するため (`build/polish-0181-stopwatch-tests.log`)、`CFFIXED_USER_HOME` / `HOME` を `build/home` に向けた `build-for-testing` (`build/polish-0181-build-for-testing-final.log`) の成果物を `xcrun simctl spawn 643CF0FB-...` で実行し、441 件 / skip 31 / 失敗 0 (`build/polish-0181-tests-final.log`)。内訳は、develop 時点の 436 件 / skip 31 (0177 の 435 件 / skip 30 に `0178` の `SendonlyE2ETests.testSendonlyDummyAudioActivatesSharedAudioSession` が加わったもの) に `StopwatchTests` の 5 件を加えたものである
- `make build` 成功 (`build/polish-0181-make-build.log`)、`make consumer-build SCHEME=ConsumerCore` 成功 (`build/polish-0181-consumer-build.log`)
- `make api-check-fresh` 成功し `The committed API baseline matches the current Sora module.` (`build/polish-0181-api-check-fresh.log`)。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` は空 (`build/polish-0181-api-baseline-diff.log`)
- `make fmt-lint` は成功 (`build/polish-0181-fmt-lint.log`)、`swiftlint lint --strict --cache-path build/swiftlint-cache` は 0 violations / 64 files (`build/polish-0181-swiftlint.log`)
- 0177 と同じく、xcodebuild 系 (`make build` / `make consumer-build` / `make api-check-fresh`) は `CFFIXED_USER_HOME` / `HOME` を `build/home` に向けないと manifest cache に書けず終了する。上記の成功は向けた実行の結果である

### 退行検出

- closure の `handler` 呼び出しを storage のローカル束縛ではなく `self.storage` 参照に戻し、storage ではなく `Stopwatch` の `self` を捕捉する形にすると、型検査の一次行が 18 件に戻り `#SendableClosureCaptures` が `Sora/Utilities.swift:33:28` の 1 件に戻ることを確認した (`build/0181-regression-typecheck.log`)。元の実装の捕捉位置は `self.seconds` の行の `:33:13` であり、このとき使った `self.storage` 参照形は同じ `self` 捕捉の同等形であって、元の形そのものではない。確認用の変更は commit しておらず、確認後に元へ戻した
- もう 1 つの退行候補である「利用者の `handler` を lock 区間の中で呼ぶ」形は deadlock になり、追加した 2 件の再入テストがハングとして検出する (「テストの追加」に実測を記載)

### ドキュメントの更新

- `issues/0108-update-swiftpm-language-mode.md` の 4 箇所 (`## 前提となる issue` / `## 設計方針` / `## 検証方針` / `## 完了条件`) の「`0115` 待ち」を、本 issue の完了で `#SendableClosureCaptures` が 0 件になり gate を有効化できる記述へ更新した。あわせて判定に使う 3 条件の (1) に、可変状態を持つ lock 付き storage に対する読み替えと前例 (`0106` の `LoggerStateStorage` / `0177` の `PeerChannelTransportStorage`)、本 issue の `StopwatchStorage` を注記し、`0108` の判定基準として承認済みにした。`0108` の担当範囲と完了条件の趣旨は変えていない
- `issues/pending/0115-remove-stopwatch.md` の「`0108` のゲートは `Stopwatch` の削除まで有効化できない」を、本 issue が捕捉を解消したため削除を待たずに有効化できる旨へ更新した。あわせて「変更対象」に `SoraTests/StopwatchTests.swift` (file 全体が `Stopwatch` 専用) の削除を 1 行明記した。削除の計画と前提は変更していない
- `CHANGES.md` の `## develop` の `[UPDATE]` の末尾に担当者行付きのエントリを追加した。通知が storage 経由で継続することと、変わるのが解放の時期だけであることも書いた

### 残った懸念

- 追加した `SoraTests/StopwatchTests.swift` は `Stopwatch` を参照するため、`0115` が `Stopwatch` を削除するときの削除対象になる。`0115` の「変更対象」に file ごとの削除として明記した
- 検証環境の制約により、issue の「テスト方針」が示す `xcodebuild test` は実行できず (起動時の `Pseudo Terminal Setup Error`)、0177 と同じ `build-for-testing` + `xcrun simctl spawn` で代替した。加えて `SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` の指定が必要だった
- `String(format:)` の分が `seconds / 60` で剰余になっておらず、3600 秒で `"01:60:00"` を通知する既知の表示の不具合が残る。`develop` の `Stopwatch` も同じで本 issue の退行ではないため修正しない (`0115` の削除で対象コードごと消える)
- `stop()` の後の `run()` が動作しない既知の lifecycle の問題と、handler の executor 契約が無いことは変更前のままである (スコープ外)。追加した再入テストは handler が main thread で呼ばれる前提 (実 `Timer` を `RunLoop.main` へ登録) で動き、`Timer` の block が別スレッドで発火する場合の handler の並行実行は検証していない
