# Utilities.Stopwatch を削除する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/remove-stopwatch
- Polished: 2026-09-28

## 目的

非推奨期間を完了した `Utilities.Stopwatch` を次期 major version で削除し、SDK 内で未使用かつ concurrency-safe でない一般 utility を保守対象から外す。

## 優先度根拠

公開 API の削除であり、次期 major version の release までに必ず実施する必要があるため Medium とする。前提の release が公開されるまで着手できないため High にはしない。

## 前提

用語を次のとおり定める。

- 非推奨化 release (D): `0114` の非推奨化と移行案内を含む release
- 削除 release (R): 本 issue の削除を含める release

release とは `CHANGES.md` に `## <version>` 節がある version とし、canary の tag は含めない。D は `git tag --list` のうち、`CHANGES.md` のその version の節に Stopwatch の非推奨化のエントリがある tag とする。

- D の tag が存在し、次の 4 点を満たすこと。確認は `git show <D>:<path>` で行う。
  - `Sora/Utilities.swift` の `Utilities.Stopwatch` の deprecation annotation に、削除予定時期 (既存の非推奨 message と同じ `YYYY 年中に廃止予定` 形式、または次期 major version) と用途別の移行方針が書かれている
  - `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` に Stopwatch の参照がある
  - `.github/workflows/consumer-test.yml` の `Check Deprecation Warning` が検査する symbol 一覧に `Stopwatch` がある
  - `CHANGES.md` の D の節に、非推奨化と用途別の移行案内のエントリがある
- R が次期 major version であること。R は、D の非推奨 message が示す削除予定時期以降に公開される release とする。message が年を挙げている場合 (`YYYY 年中に廃止予定`) はその年以降、`次期 major version` と書いている場合は D の tag の year より大きい year の release とする。時雨堂の version は `YYYY.RELEASE.FIX` で、同じ year でも `RELEASE` が増えるため、year の大小だけで判定できるのは後者の場合である。
- `0107` (consumer package と公開 API baseline) が完了していること。
- `0114` 完了後に `SoraTests` に `Utilities.Stopwatch` の参照が追加されていないかを確認し、追加されている場合はその参照を削除対象に含める。
- 磨き上げ済みの本 issue と、本 issue が更新する `issues/0070-change-migrate-to-webrtc-c-xcframework.md` が develop にコミットされていること。

`0114` の完了条件には、D に `CHANGES.md` の非推奨化エントリを含める作業が書かれていない。この不足は `0114` 側で解消する必要があり、本 issue の作業では `0114` を書き換えない。

上記を満たしていない場合は、本 issue に着手しない。

## 現状

本節は `0107` 完了後・`0114` 完了前 (2026-09-28 時点) の状態である。

`Sora/Utilities.swift` の `Utilities.Stopwatch` は公開 API だが、`Sora` と `SoraTests`、`TestConsumers/` の Swift source からは参照されていない。参照があるのは公開 API baseline の JSON と `TestConsumers/Swift6Consumer/README.md` の記述だけである。

実装には `0114` の現状に挙げた lifecycle と executor 契約の問題がそのまま残る。加えて `String(format:)` の分の計算が剰余になっておらず、1 時間 (3600 秒) に達した時点で `01:60:00` のように分が 60 以上になる表示の問題もある。

Sora SDK 固有の機能ではないため、問題を修正して公開 abstraction として維持するより、削除して SDK の責務を明確にする。

`0177` (2026-09-29 完了) が SDK 内部インスタンスを捕捉する `#SendableClosureCaptures` の 10 件を解消したため、`Sora` target を Swift 6 言語モードで型検査したときに残った `#SendableClosureCaptures` は本 issue が削除する `Utilities.Stopwatch` の 1 件だけであった (`build/0177-stage2-typecheck.log`。`0108` のゲート相当の flags を付けた型検査の error も同じ 1 件)。この 1 件は `0181` (完了 2026-09-29) が `Stopwatch` の内部構造を変更し、`Timer` closure の捕捉対象を `self` から lock 付きの storage へ移したことで解消して `#SendableClosureCaptures` は 0 件になった。`0108` の warnings-as-errors ゲートは、本 issue が `Stopwatch` を削除するのを待たずに有効化できる。

## 設計方針

- `Utilities.Stopwatch` の型定義を削除する。
- `0114` が追加した consumer package と CI の参照を同時に削除する。`consumer-test.yml` の symbol 一覧だけを残すと `'Stopwatch' is deprecated` が build log に出ずに `Check Deprecation Warning` が失敗する。
- `CHANGES.md` の `## develop` の種別順の主リストに `[CHANGE]` を追加し、削除することと用途別の代替 (Foundation の `Timer`、Swift の `Clock` / `Duration`、アプリ側の timer) を書く。
- `Utilities.randomString` (`Utilities` の公開 API)、同じ file の `Optional.unwrap(ifNone:)` (公開 API)、internal な `PairTable` は変更しない。`randomString` は SDK 内では未使用だが concurrency-safe であり、非推奨化もされていないため本 issue の対象ではない。削除する場合は非推奨化からの別 issue とする。
- 代替 timer abstraction を SDK へ追加しない。`Stopwatch` の名前を残す互換 wrapper、`typealias`、`@available(*, unavailable)` のスタブも追加しない。

## スコープ外

- `Stopwatch` の lifecycle bug と表示の修正。削除で対象コードごと消えるため、bug issue も起票しない (非推奨かつ SDK 内未使用であり、削除が解消経路である)。
- `ConnectionTimer` (internal であり利用者向けの代替にはならない。ライフサイクル修正は `0096` で完了済み)。
- `Sora/Utilities.swift` の `import WebRTC` の整理 (`0070` の Phase 2 が扱う)。
- 外部の移行ドキュメント (`<https://sora-ios-sdk.shiguredo.jp/>`) の更新 (別リポジトリが管理している。移行案内の正本は `0114` の deprecation message と `CHANGES.md` のエントリ)。
- `sora-ios-sdk-samples` / `sora-ios-sdk-quickstart` (Stopwatch の利用が無いことを確認済み。利用が見つかった場合は別リポジトリの issue とする)。

## 変更対象

- `Sora/Utilities.swift`: `0114` が付けた `@available(*, deprecated, ...)` の属性行 (doc comment があればその行も) と `Utilities.Stopwatch` の型宣言全体 (`public final class Stopwatch` から `stop()` の後の閉じ括弧まで) を削除する。`Stopwatch` だけが使っていた `import Foundation` も削除する。`import WebRTC` と他の宣言は変更しない。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift`: `Utilities.Stopwatch` を参照する宣言を削除する (参照だけを消すと compile が通らないため)。同じ関数に `0116` が追加した `SoraDispatcher` の参照がある場合は、その参照は残して `Stopwatch` の初期化と `run()` / `stop()` の呼び出しだけを削除する。
- `.github/workflows/consumer-test.yml`: `Check Deprecation Warning` の symbol 一覧から `Stopwatch` を削除する。`SoraDispatcher` 系の symbol は `0117` が削除するため触れない。`Stopwatch` の宣言に由来する他の symbol (`init(handler:)` など) が一覧に残っていれば併せて削除する。
- `TestConsumers/Swift6Consumer/README.md`: `## 公開 closure の列挙手順` の表の行から `Utilities.Stopwatch(handler:)` の記述だけを削除し、`SoraDispatcher.async(on:block:)` の記述がある行は残す (`0117` が完了していて行が無い場合は何もしない)。
- `skills/sora-ios-sdk/SKILL.md`: 「非推奨 API」表に `Utilities.Stopwatch` の行が無いことを確認する (`0114` が行を追加していた場合は削除する)。`SoraDispatcher` の行 (`0116` が追加し `0117` が削除する。現時点では未追加) と `MediaChannelConfiguration` (`0170`) の行には触れない。
- `TestConsumers/Swift6Consumer/ApiBaseline/`: 削除と同じ commit で baseline を再生成する (file 名は着手時点の `XCODE_SDK` から導出される)。
- `CHANGES.md`: `## develop` の種別順の主リストに `[CHANGE]` を追加する。
- `issues/0070-change-migrate-to-webrtc-c-xcframework.md`: 行数表の全行、`Sora/*.swift` 計、`Sora/Extensions/*.swift` 計、`Sora/` 配下計、および 12 行目と 67 行目の計測日の注記を、着手時に `wc -l` で再計測した値と実施日で更新する (`0113` と同じ粒度)。`Sora/Utilities.swift` は行数順を保つ位置 (`ICEServerInfo.swift` と `ConnectionState.swift` の間) へ移す (削除による減少は 36 行。前後の空行の整理で 1 行前後し得る)。`0070` の Phase 2 が先行して `Utilities.swift` の `import WebRTC` が既に除去されている場合は、行を復活させない。`SoraTests/` の file を削除した場合は、同表の `SoraTests/` の file 数と計測日の注記も更新する。
- `SoraTests/`: `0114` 完了後に `Stopwatch` を参照する宣言がある場合だけ削除する (参照だけの場合はその行、テスト関数内の場合は関数ごと、file 全体が Stopwatch 専用の場合は file ごと)。
- `SoraTests/StopwatchTests.swift`: file 全体が `Utilities.Stopwatch` 専用のテストであるため、`Stopwatch` の型宣言と同じ変更で file ごと削除する (`0181` が追加し、`SoraTests` 内で `Stopwatch` を参照する唯一の file である)。

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行う。以下に書く Xcode と SDK と simulator の版数は 2026-09-28 時点の値であり、着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` と baseline の file 名、`xcrun simctl list runtimes` の結果に読み替える。

- Xcode の指定方法は target ごとに異なる。`XCODE=` が効くのは `make consumer-build` / `make consumer-check-negative` / `make api-baseline` / `make api-check` / `make api-check-fresh` だけである (`Makefile` が `DEVELOPER_DIR` として使う)。`XCODE_SDK=` はこれらに加えて `make build` の `-sdk` にも効く。`make build` / `make fmt-lint` / `make lint` と素の `xcodebuild` は `XCODE` を参照しないため、Xcode を切り替える場合は `xcode-select -s` または `DEVELOPER_DIR=<Xcode>/Contents/Developer` を使う。
- `make build` (Sora scheme の clean build) が成功すること。
- `SoraTests` を実行し失敗 0 件であること。E2E は環境変数が無い場合 skip される。シミュレータが無い環境では iOS 26.5 の runtime を用意し、`.github/workflows/e2e-test.yml` の `Setup iOS Simulator` と同じ手順で `iPhone 17 Pro` を作成してから実行する (同 step の `xcrun simctl create` は runtime を指定しないため、最新 runtime が 26.5 でない環境では `xcrun simctl list runtimes` で確認した runtime を明示する)。

  ```
  xcodebuild test -scheme Sora-Package -derivedDataPath build \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6
  ```

- consumer package を clean build して 3 scheme の log を取り、`ConsumerLegacy` の log に `'Stopwatch' is deprecated` が出ず、`Check Deprecation Warning` が検査する他の symbol の warning はすべて出ていることを確認する (`Check Deprecation Warning` は CI の step なので、ローカルでは build log で代替する。incremental build では warning が出ないため `build/consumer` を削除してから実行する)。対象の symbol は `.github/workflows/consumer-test.yml` の一覧から取り出す (件数は `0116` / `0117` の進行で変わるため固定しない)。

  ```
  set -euo pipefail
  rm -rf build/consumer
  make consumer-build SCHEME=ConsumerCore 2>&1 | tee build/consumer-core.log
  make consumer-build SCHEME=ConsumerUI 2>&1 | tee build/consumer-ui.log
  make consumer-build SCHEME=ConsumerLegacy 2>&1 | tee build/consumer-legacy.log
  test -s build/consumer-legacy.log
  ! grep -Fq "'Stopwatch' is deprecated" build/consumer-legacy.log
  for symbol in $(sed -n '/^        symbols=(/,/^        )/p' .github/workflows/consumer-test.yml | grep -o "'[^']*'" | tr -d "'"); do
    grep -Fq -- "'$symbol' is deprecated" build/consumer-legacy.log
  done
  ```

- CI の `Check Negative Checks` と同じ `make consumer-check-negative` を実行する。あわせて CI の `Check No Test-Only Import` と同じ検査を実行する (コマンドは `.github/workflows/consumer-test.yml` の同 step の記述をそのまま使う。`:(glob)TestConsumers/Swift6Consumer/**/*.swift` を対象にし、0 件で終了コード 1 が正常である)。
- baseline の再生成と consumer package の更新を終えた後、次の検索が 0 件であること (`--untracked` で未追跡 file も対象にする。`issues/` は履歴、`CHANGES.md` は削除の告知に `Stopwatch` を含むため除外する)。

  ```
  git grep -n --untracked Stopwatch -- . ':!issues' ':!CHANGES.md'
  ```

- baseline を再生成する前に `make api-check` を実行し、`Utilities.Stopwatch` の宣言の削除だけが `API breakage` として報告されることを `build/consumer/api-check.log` で確認する。`make api-check` は出力が空でなければ失敗する実装 (`Makefile` の api-check) なので、この失敗は想定どおりであり、終了コードではなく出力で判定する。
- `make api-baseline` で baseline を再生成する (依存で `ConsumerCore` を build する)。`make api-baseline` は dump を `build/consumer/api-baseline.json` に残すため、再生成前の baseline とこの dump を `API_BASELINE_DIFF` と同じ集計で比較し、Removed declarations 4 件 / Added declarations 0 件であることを確認する。4 件の内訳は `Stopwatch` (`[Class]`) / `init(handler:)` (`[Constructor]`) / `run()` (`[Func]`) / `stop()` (`[Func]`) である。次の比較は baseline の再生成を commit する前に実行する (`git show HEAD:` は commit 済みの baseline を返すため、commit 後では差分が 0 件になり検証にならない)。3 番目のコマンドは差分があると終了コード 2 を返す (`Makefile` の規約) ため、出力と log で判定する。

  ```
  git show HEAD:TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json > build/consumer/api-baseline-head.json
  sed -n '/^define API_BASELINE_DIFF$/,/^endef$/p' Makefile | sed '1d;$d' > build/consumer/api-baseline-diff.py
  python3 build/consumer/api-baseline-diff.py build/consumer/api-baseline-head.json build/consumer/api-baseline.json build/consumer/api-baseline-diff.log
  ```

- 再生成した baseline の差分を読み、Stopwatch の削除以外の差分 (型の変更、準拠の削除、`printedName` / `declKind` の変化、他の symbol の消滅) が無いことと、`Utilities.randomString(length:)` と `Optional.unwrap(ifNone:)` の宣言が残っていることを確認する。生の行差分は部分木の削除に伴う行番号ずれで大きく出るため、宣言単位の集計で判定する (`CODEBASE.md` の baseline 更新手順)。
- `git diff -- CHANGES.md` を読み、完了条件の `[CHANGE]` の (a)〜(f) を満たすことを確認する。
- `git diff -- issues/0070-change-migrate-to-webrtc-c-xcframework.md` を読み、行数表の全行と 12 行目と 67 行目の合計と計測日の注記が、着手時の再計測値になっていることを確認する。
- `make api-check-fresh` が成功すること (`make api-check` を含む)。
- `make fmt-lint` と `make lint` が成功すること。`make lint` は `swiftlint --fix .` を実行して file を書き換えるため、実行後に `git diff` を読み、意図しない整形が混入していないことを確認する。

## 完了条件

- `Sora/Utilities.swift` から、`0114` が付けた `@available(*, deprecated, ...)` の属性行 (doc comment があればその行も) と `Utilities.Stopwatch` の型宣言全体が削除され、差分がそれと `import Foundation` の削除だけであること。
- 上記の `git grep --untracked` が 0 件であること。
- consumer package の `DeprecatedAPI.swift` の参照、`consumer-test.yml` の symbol 一覧、consumer package の README の記述に Stopwatch が残っておらず、`skills/sora-ios-sdk/SKILL.md` の「非推奨 API」表にも Stopwatch の行が無いこと。
- 代替 timer abstraction と `Stopwatch` の名前を残す shim を追加していないこと。
- `CHANGES.md` の `## develop` の種別順の主リストに `[CHANGE]` が追加され、(a) `Stopwatch` を削除すること、(b) 代替が用途別であり単一の万能な代替があるような書き方をしないこと、(c) issue 番号を書かないこと、(d) エントリの最後に 2 文字インデントで担当者行があること、(e) 削除理由が書かれていること、(f) 変更内容が「〜する」の形で書かれていることが満たされていること。
- baseline の差分が `Stopwatch` の 4 宣言の削除だけ (Removed 4 件 / Added 0 件) で、`Utilities.randomString(length:)` と `Optional.unwrap(ifNone:)` の宣言が残っていること。`make api-check-fresh` が成功すること。
- `make build` が成功し、`SoraTests` が失敗 0 件で、consumer package の 3 scheme の build が成功し、`make consumer-check-negative` と CI の `Check No Test-Only Import` と同じ検査が成功すること。
- `make fmt-lint` と `make lint` が成功すること (SwiftPM の manifest 解決ができない環境では、同じ `.swiftlint.yml` で `swiftlint --fix` と `swiftlint --strict` を直接実行した結果で代替し、その旨を「解決方法」に記録する)。
- `issues/0070-change-migrate-to-webrtc-c-xcframework.md` の行数表の全行と、12 行目と 67 行目の合計と計測日の注記が、着手時の再計測値になっていること。

## pending にした理由

D (`0114` の非推奨化と移行案内を含む release) が公開されておらず、R の version 条件も未達である (現行の `SDKInfo.version` は `2026.4.0-canary.0`)。`0114` は open で `Completed:` が空である。

## 解決方法

## Pending 解除条件

- 前提の D の確認点 (deprecation annotation の削除予定と移行方針、`DeprecatedAPI.swift` の参照、`consumer-test.yml` の symbol 一覧、`CHANGES.md` の D の節のエントリ) を満たす release の tag が存在し、`0107` が完了していること。
- D の非推奨 message が示す削除予定時期以降に公開される release があること (前提の R の条件)。
- `0114` が完了した時点の develop で `SoraTests` に `Utilities.Stopwatch` の参照が無いこと (ある場合は変更対象に含める)。
- 磨き上げ済みの本 issue と `issues/0070-change-migrate-to-webrtc-c-xcframework.md` が develop にコミットされていること。
