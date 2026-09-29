# `Utilities.Stopwatch` の `Timer` closure の `#SendableClosureCaptures` 警告を解消する

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/refactor-remove-stopwatch-sendable-closure-capture
- Polished: {YYYY-MM-DD}

## 目的

`Sora` target に残る唯一の `#SendableClosureCaptures` 警告 (`Sora/Utilities.swift` の `Utilities.Stopwatch` の `Timer` closure が `self` を捕捉する 1 件) を解消し、`0108` の Sora target warnings-as-errors ゲートを `0115` (`Utilities.Stopwatch` の削除) の完了を待たずに有効化できる状態にする。

`0115` は非推奨化 release (D) と次期 major version の release (R) を前提にするため、完了時期を本 issue から制御できない。`0108` のゲートがその完了を待つ間、`Sora` target の concurrency 警告を error として検出できない状態が続く。

本 issue は `Utilities.Stopwatch` の内部構造だけを変更し、公開 API のシグネチャと利用者から観測できる挙動を変えない。

## 優先度根拠

Medium とする。

- `0108` の warnings-as-errors ゲートを開くために残る最後の 1 件である (`0177` が完了 2026-09-29 に残した唯一の `#SendableClosureCaptures`)。放置すると `0108` のゲートを有効化できない
- 一方で `0115` が `Stopwatch` を削除すれば同じ警告は消えるため、`0115` の削除までの一時的な対応である。`0115` が先に完了した場合は本 issue は不要になる
- 公開 API のシグネチャと観測可能な挙動を変えない内部リファクタリングであり、利用者への影響がないため High にはしない

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

`0108` は `## 前提となる issue` と `## 設計方針` と `## 検証方針` と `## 完了条件` に「残る `#SendableClosureCaptures` は `0115` (`Sora/Utilities.swift` の `Stopwatch` 削除の 1 件) だけで、`0115` が完了するまで gate を有効化できない」と記載している。本 issue の完了後は 0 件になるため、この記述を更新する必要がある (「変更対象」)。

`0115` も「`0108` の warnings-as-errors ゲートは、本 issue が `Stopwatch` を削除するまで有効化できない」と記載しており、本 issue の完了でこの前提も古くなる。この更新は `0115` 側の作業とする (本 issue の変更対象に含めない)。

## 設計方針

### 捕捉対象の置き換え

`Timer` closure が捕捉する可変状態 (`seconds` / `handler`) を、`NSLock` で保護した `@unchecked Sendable` の内部 storage (型) へ移し、closure はその storage だけを捕捉する。`Stopwatch` は storage を `let` で保持し、closure は `Stopwatch` ではなく storage を捕捉する。

`Stopwatch` 自身に `@unchecked Sendable` を付けない。`Stopwatch` に `Sendable` 準拠も追加しない (公開 API の追加になり、`0114` / `0115` の予定とも重複する)。

closure が読まない `timer` (`Timer?`) は `Stopwatch` の stored property のまま残す。`timer` を storage へ移すことは本 issue の警告の解消には不要であり、`run()` / `stop()` からのみ触る現在の形を変えない。

### `@unchecked Sendable` を storage だけに認める根拠 (`0108` との整合)

`0108` は「未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならない」とし、その判定を 3 条件で行うとしている。本 issue はこの 3 条件を次のとおり適用する。

- (1) 「追加する型自身が可変状態を持たず、保持する値が `init` で確定した不変値であること」は、可変状態を保持する storage には文字どおりには当てはまらない。本 issue は (1) を「可変状態を持つ場合は、その読み書きのすべてが単一の排他に閉じていること」と読み替えて適用する。`0177` が追加した `PeerChannelTransportStorage` (NSLock が `nativeChannel` / `streams` / `offerEncodings` の全アクセスを保護する storage) と、`0100` が追加した `ConnectionSnapshotStorage` が同じ類型の前例である。`0108` の 3 条件の (2) と (3) は storage にもそのまま当てはめる
- (2) 「変更前から同じ系統の非同期境界へ渡されており、配送先・順序・呼び出し回数を変えず、別系統の境界へ新たに渡すこともないこと」を満たす。closure は変更前と同じ `Timer(timeInterval:repeats:block:)` に渡り、`RunLoop.main` の登録も `run()` のままである。捕捉対象が `Stopwatch` から storage に変わるだけで、配送先・順序・呼び出し回数は変わらない
- (3) 「保持するのは closure と、その closure が変更前から一緒に捕捉していた参照だけであり、SDK 内部の参照型を新たに保持しないこと」を満たす。storage が保持するのは `seconds` (値型) と、利用者から渡された `handler` (`init` で確定し、以後再代入しない) だけである。`Timer` と `RunLoop` は storage へ移さない

`0108` の 3 条件の読み替えを `0108` 本体の記述に反映するかどうかは `0108` 側で判断する。本 issue は「変更対象」に挙げた `0108` の「`0115` 待ち」の記述の更新だけを行い、3 条件の文面は変更しない。

storage の `@unchecked Sendable` が主張するのは「storage が保持する可変状態の読み書きが storage の `NSLock` に閉じていること」だけである。`handler` の closure 自体が `Sendable` であることや、`Timer` のオブジェクト状態の不変性は主張しない。この区別を storage の doc コメントに書く。

### lock の区間と利用者コードの呼び出し

- `0165` の「排他区間を保持したまま利用者コードを呼ばない」方針に従い、利用者の `handler` は storage の lock を解放してから呼ぶ。`seconds` の読み出しと加算だけを lock 区間内で行う
- `handler` の参照は lock 区間内で取り出し、呼び出しは区間外で行う
- `seconds` の読み出し、`handler` の呼び出し、`seconds` の加算という現在の順序を変えない。加算は `handler` の呼び出し後に行う。つまり `handler` の実行中は lock を保持せず、`handler` が `stop()` を呼んで `seconds` を 0 に戻した場合の結果も変更前と同じになる
- `run()` の `timer.fire()` は closure を同期的に実行するため、storage の lock を保持したまま呼ばない (保持すると closure が同じ lock を再取得して deadlock する)。`run()` は `seconds` を 0 に戻す区間を閉じてから `RunLoop.main.add(_:forMode:)` と `fire()` を呼ぶ。この順序は現在の実装と同じである
- `stop()` の `timer?.invalidate()` は storage の lock と関係しないため、現在の順序のまま呼ぶ

### 維持する挙動と触らない範囲

- 公開 API のシグネチャ (`init(handler:)` / `run()` / `stop()`) を変えない。`Sendable` 準拠、`@available` 属性、引数ラベル、アクセスレベルを変えない
- 観測可能な挙動を変えない。1 秒ごとに `"時:分:秒"` 形式の文字列を handler へ通知し、`run()` で開始し、`stop()` で停止して `seconds` を 0 に戻す挙動を維持する。`run()` の直後に handler が `"00:00:00"` で 1 回呼ばれる挙動も維持する
- `RunLoop.main` を使う設計を変えない。`Timer` を生成する RunLoop と `run()` が登録する RunLoop はどちらも main のままである
- executor 契約 (handler を実行するスレッドや MainActor 隔離が定まっていないこと) を変更しない。契約の整備は本 issue のスコープ外である
- `PairTable` / `Optional.unwrap(ifNone:)` / `Utilities.randomString` には触れない
- storage は `fileprivate` または `private` の型として `Sora/Utilities.swift` 内に追加し、公開 API を増やさない。型名は実装時に決める
- 追加・変更する storage の doc コメントに、どの lock がどの状態を守るか、新しい並行境界を増やしていないこと、捕捉対象の状態の所有と同期が誰の責務かを日本語で書く。ソースコードに issue 番号は書かない

## 前提となる issue

- `0177` (完了 2026-09-29): `Sora` target の `#SendableClosureCaptures` 11 件のうち SDK 内部インスタンスを捕捉する 10 件を解消し、残る 1 件を `Sora/Utilities.swift` の `Utilities.Stopwatch` として切り分けた。本 issue はその 1 件を扱う。lock 付き storage に `@unchecked Sendable` を付ける前例 (`PeerChannelTransportStorage`) も `0177` が追加した
- `0108` (open): Sora target の warnings-as-errors ゲート。本 issue の完了でゲートを開ける状態になる。`0108` の「`0115` 待ち」の記述の更新は `0108` 側の作業として行い、本 issue の実装と同じ変更に含める (「変更対象」)
- `0114` (open): `Utilities.Stopwatch` の非推奨化。本 issue とは独立であり、実施順序を規定しない。`0114` が deprecation annotation を付けた後に本 issue を実施する場合、本 issue は annotation 行と doc コメントを変更しない
- `0115` (pending、`issues/pending/0115-remove-stopwatch.md`): `Utilities.Stopwatch` の削除。本 issue の対応はその削除までの一時的なもの。`0115` が先に完了した場合は本 issue は不要になり、警告は削除で 0 件になる。`0115` の「`0108` のゲートは `Stopwatch` の削除まで有効化できない」という記述は本 issue の完了で古くなるが、その更新は `0115` 側の作業とする

## 変更対象

- `Sora/Utilities.swift`: `Utilities.Stopwatch` の `Timer` closure が捕捉する `seconds` / `handler` を lock 付き storage へ移す。`Stopwatch` の公開シグネチャ (`init(handler:)` / `run()` / `stop()`) と `timer` の扱い、`PairTable` / `Optional.unwrap(ifNone:)` / `Utilities.randomString` は変更しない
- `SoraTests/`: 「テスト方針」で追加を判断する `Stopwatch` のテスト。追加しない場合は file を変更しない
- `CHANGES.md`: `## develop` の主リストに `[UPDATE]` を追加する (`shiguredo-changelog` に従う。担当者行 `- @t-miya` を含める)
- `issues/0108-update-swiftpm-language-mode.md`: `## 前提となる issue` の `0177` の bullet、`## 設計方針` の warnings-as-errors の bullet、`## 検証方針` と `## 完了条件` の「残る `#SendableClosureCaptures` は `0115` の `Stopwatch` 削除の 1 件だけで、`0115` が完了するまで gate を有効化できない」という記述を、本 issue の完了で 0 件になる記述へ更新する。`0108` の担当範囲 (manifest 更新、`README.md` / `skills/sora-ios-sdk/SKILL.md` の更新、検証) の記述は壊さない

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

- 挙動の維持は、`RunLoop.main` を使う実 `Stopwatch` のテストを `SoraTests` へ追加できるか実装時に判断する。候補は、`run()` の直後に handler が `"00:00:00"` で呼ばれること、時間経過で通知が増えること、`stop()` で通知が止まり `seconds` が 0 に戻ることである。`Timer` の発火は wall clock と RunLoop の実行に依存するため flaky になる場合は追加しない。追加しない場合は、その理由を「解決方法」に記録し、`SoraTests` 全体と TSan を回帰の正本とする
- `SoraTests` 全体を実行し失敗 0 件であること。E2E は環境変数が無い場合 skip される
- TSan は `-enableThreadSanitizer YES` を付けた `build-for-testing` が作った `SoraTests.xctest` を `xcrun simctl spawn` で実行し、`ThreadSanitizer` の検出行が 0 行であることを確認する (`test-without-building` では interceptor が働かないため、build から実行する。起動手順と `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` の扱いは `0177` の「解決方法」と同じ)
- `make build` が成功すること
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること。公開 API のシグネチャを変えないため、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。差分が出た場合は `make api-baseline` を実行せず、公開 API の変更として別 issue に分離する
- `make fmt-lint` と `swiftlint lint --strict` が成功すること
- 退行検出: closure が storage ではなく `Stopwatch` の `self` を捕捉する変更前の形に戻すと、型検査の `#SendableClosureCaptures` が 1 件に戻ることを確認する。確認用の変更は commit しない

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が 0 件、error 0 件であること。非推奨 API の警告は残ってよい (起票時の実測では 17 件)
- `0108` のゲート相当の flags を付けた型検査で error が 0 件であること
- 公開 API のシグネチャ (`init(handler:)` / `run()` / `stop()`) が変わっていないこと。`Stopwatch` に `Sendable` 準拠を追加していないこと。`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること
- `Timer` closure が捕捉するのが追加した storage だけで、`Stopwatch` 自身を捕捉していないこと。`@unchecked Sendable` が追加した storage の宣言行だけに付いており、`Stopwatch` に付いていないこと
- storage が保持する可変状態の読み書きがすべて `NSLock` の区間内にあり、利用者の `handler` の呼び出しと `run()` の `timer.fire()` が lock 区間の外にあること
- 1 秒ごとの `"時:分:秒"` の通知、`run()` の直後に `"00:00:00"` で 1 回呼ばれること、`stop()` で停止して `seconds` が 0 に戻ることという観測可能な挙動が変わっていないこと
- `SoraTests` 全体が失敗 0 件で、TSan の検出行が 0 行であること。`Stopwatch` のテストを追加しなかった場合は、その理由が「解決方法」に書かれていること
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make fmt-lint` / `swiftlint lint --strict` が成功すること
- `CHANGES.md` の `## develop` の主リストに `[UPDATE]` エントリが担当者行付きで追加されていること
- `issues/0108-update-swiftpm-language-mode.md` の「`0115` 待ち」の記述が、本 issue の完了で `#SendableClosureCaptures` が 0 件になる記述へ更新され、`0108` の担当範囲の記述が壊れていないこと

## スコープ外

- `Utilities.Stopwatch` の非推奨化 (`0114`) と削除 (`0115`)。本 issue は削除までの一時的な対応である
- `Stopwatch` の既知の問題 (stop 後の `run()` が動作しない `Timer` lifecycle、handler の executor 契約が無いこと) の修正。削除で対象コードごと消えるため、bug issue も起票しない
- `Utilities.randomString` / `Optional.unwrap(ifNone:)` / `PairTable` の変更
- `Stopwatch` への `Sendable` 準拠の追加、`@preconcurrency` の追加、default actor isolation の変更で警告を消すこと
- `0108` の manifest 更新 (`swift-tools-version` / `swiftLanguageModes` / Sora target の `swiftSettings`) と `README.md` / `skills/sora-ios-sdk/SKILL.md` の更新。本 issue は `0108` の前提記述の更新だけを行う
- `issues/pending/0115-remove-stopwatch.md` の記述の更新 (`0108` のゲートに関する記述は本 issue の完了で古くなるが、更新は `0115` 側の作業とする)
- `SoraTests` target の warnings-as-errors ゲート (`0171`)

## 解決方法
