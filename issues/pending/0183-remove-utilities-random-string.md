# `Utilities.randomString` を削除する

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/remove-utilities-random-string
- Polished: {YYYY-MM-DD}

## 目的

非推奨期間を完了した `Utilities.randomString` を次期 major version で削除し、Sora / WebRTC と無関係な未使用の公開ユーティリティを API surface から外す。

`Utilities.Stopwatch` (`0115` が削除する) と本 issue の `randomString` の両方が無くなると `Utilities` 名前空間が空になるため、あわせて `public enum Utilities` 自体を削除する。

## 優先度根拠

公開 API の削除であり、次期 major version の release までに必ず実施する必要があるため Medium とする。前提の release が公開されるまで着手できないため High にはしない。

## 前提

用語を次のとおり定める。

- 非推奨化 release (D): `0182` の非推奨化と移行案内を含む release
- 削除 release (R): 本 issue の削除を含める release

release とは `CHANGES.md` に `## <version>` 節がある version とし、canary の tag は含めない。D は `git tag --list` のうち、`CHANGES.md` のその version の節に `randomString` の非推奨化のエントリがある tag とする。

- D の tag が存在し、次の 4 点を満たすこと。確認は `git show <D>:<path>` で行う。
  - `Sora/Utilities.swift` の `randomString(length:)` に deprecation annotation があり、削除予定時期 (既存の非推奨 message と同じ `YYYY 年中に廃止予定` 形式、または次期 major version) と移行方針が書かれている
  - `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` に `randomString` の参照がある
  - `.github/workflows/consumer-test.yml` の `Check Deprecation Warning` が検査する symbol 一覧に `randomString(length:)` がある
  - `CHANGES.md` の D の節に、非推奨化と移行案内のエントリがある
- R が次期 major version であること。R は、D の非推奨 message が示す削除予定時期以降に公開される release とする。message が年を挙げている場合 (`YYYY 年中に廃止予定`) はその年以降、`次期 major version` と書いている場合は D の tag の year より大きい year の release とする。時雨堂の version は `YYYY.RELEASE.FIX` で、同じ year でも `RELEASE` が増えるため、year の大小だけで判定できるのは後者の場合である。
- `0107` (consumer package と公開 API baseline) が完了していること。
- `0115` (`Utilities.Stopwatch` の削除) が完了していること。`Utilities` 名前空間の公開メンバーは `randomString` と `Stopwatch` の 2 つだけであり、`Stopwatch` が残っている間は `Utilities` 名前空間を削除できない。
- `0182` 完了後に `SoraTests` に `Utilities.randomString` の参照が追加されていないかを確認し、追加されている場合はその参照を削除対象に含める。
- `0182` の完了条件に、D の `CHANGES.md` の非推奨化エントリを含める作業が書かれていない場合は、その不足は `0182` 側で解消する必要がある。本 issue の作業では `0182` を書き換えない。
- 磨き上げ済みの本 issue と、本 issue が更新する `issues/0070-change-migrate-to-webrtc-c-xcframework.md` が develop にコミットされていること。

上記を満たしていない場合は、本 issue に着手しない。

## 現状

本節は `0107` 完了後・`0182` 完了前 (2026-09-29 時点) の状態である。

`Sora/Utilities.swift` の `Utilities.randomString` は公開 API だが、`Sora` と `SoraTests`、`TestConsumers/` の Swift source、`skills/` と `README.md` を含むリポジトリ内の他の file から参照されていない。参照があるのは公開 API baseline の JSON だけである。`Utilities.randomString` に deprecation annotation はまだ無く、`0182` が付ける。

`Utilities` 名前空間 (`public enum Utilities`。`/// :nodoc:` が付いている) の公開メンバーは `randomString(length:)` と `Stopwatch` の 2 つだけである。`Stopwatch` は `0115` が削除し、`randomString` は本 issue が削除する。両方が無くなると `Utilities` 名前空間は空になる。`Utilities` の外にある `PairTable` (internal) と `Optional.unwrap(ifNone:)` (公開 extension) は `Utilities` のメンバーではなく、引き続き公開 API に残る。

`randomString(length:)` の実装は `fileprivate` の `randomBaseString` / `randomBaseChars` から `UInt32.random(in:)` で文字を選ぶだけで、標準ライブラリのみで完結する。Sora SDK の機能ではなく、Sora / WebRTC と無関係な一般 utility である。`randomString` は concurrency-safe だが SDK 内で未使用であり、公開 API として維持する根拠がないため `0182` で非推奨化し、本 issue で削除する。

`Sora/Utilities.swift` は `import Foundation` と `import WebRTC` を持つ。`import Foundation` は `Stopwatch` の `Timer` が使っており、`0115` が `Stopwatch` と同時に削除する計画である。

## 設計方針

- `Utilities.randomString(length:)` の宣言と、それだけが使う `fileprivate` の `randomBaseString` / `randomBaseChars` を削除する。
- `0115` の完了で公開メンバーが 0 件になった `public enum Utilities` の宣言全体 (`/// :nodoc:` の doc コメントを含む) を削除する。空の enum を残すと公開 API baseline に名前空間だけが載り、利用者に意味のない公開型を残すことになる。
- `Optional.unwrap(ifNone:)` (公開 extension) と `PairTable` (internal の型と `PairTable where T == String` の extension) は `Utilities` の外の宣言であり、変更しない。
- `0182` が追加した consumer package と CI の参照を同時に削除する。`consumer-test.yml` の symbol 一覧だけを残すと `'randomString(length:)' is deprecated` が build log に出ずに `Check Deprecation Warning` が失敗する。
- `CHANGES.md` の `## develop` の種別順の主リストに `[CHANGE]` を追加し、削除することと、代替は標準の乱数 API (`UInt32.random(in:)` など) を利用者側で選ぶことを書く。SDK が代替 utility を提供しないことも書く。
- 代替 utility を SDK へ追加しない。`randomString` の名前を残す互換 wrapper、`typealias`、`@available(*, unavailable)` のスタブも追加しない。
- 公開 API baseline を同じ commit で再生成する。削除が意図した差分であり、それ以外の差分が無いことをレビューする。

## スコープ外

- `Utilities.Stopwatch` の削除 (`0115` が扱う)。
- 標準型への公開 extension (`Optional.unwrap(ifNone:)` / `Array.remove(_:where:)`) の是非。`Optional.unwrap(ifNone:)` は `Utilities` のメンバーではないため本 issue では変更せず、是非は別 issue とする。
- `Utilities` 以外の公開 API の整理。
- 外部の移行ドキュメント (`<https://sora-ios-sdk.shiguredo.jp/>`) の更新 (別リポジトリが管理している。移行案内の正本は `0182` の deprecation message と `CHANGES.md` のエントリ)。
- `sora-ios-sdk-samples` / `sora-ios-sdk-quickstart` (本リポジトリ外。利用が見つかった場合は別リポジトリの issue とする)。

## 変更対象

- `Sora/Utilities.swift`: `Utilities.randomString(length:)` の宣言、`fileprivate` の `randomBaseString` / `randomBaseChars`、および公開メンバーが 0 件になった `public enum Utilities` の宣言全体 (`/// :nodoc:` の doc コメントを含む) を削除する。`Optional.unwrap(ifNone:)` と `PairTable` の宣言は変更しない。`randomString` の削除で未使用になる import は無い (`UInt32.random(in:)` は標準ライブラリ。`import Foundation` は `0115` が `Stopwatch` と同時に削除する)。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift`: `Utilities.randomString` を参照する宣言を削除する (参照だけを消すと compile が通らないため)。同じ関数や file に他の非推奨 API の参照 (`Stopwatch` は `0115` が削除済み) がある場合は、それらは残す。
- `.github/workflows/consumer-test.yml`: `Check Deprecation Warning` の symbol 一覧から `randomString(length:)` を削除する。他の symbol には触れない。
- `TestConsumers/Swift6Consumer/README.md`: 「公開 closure の列挙手順」の表に `Utilities.randomString` の行がある場合は削除する (`0182` が追加していない場合は何もしない。`Utilities.Stopwatch(handler:)` の行は `0115` が削除済みである前提)。
- `skills/sora-ios-sdk/SKILL.md`: 「非推奨 API」表に `Utilities.randomString` の行があれば削除する (`0182` が追加していない場合は何もしない)。
- `TestConsumers/Swift6Consumer/ApiBaseline/`: 削除と同じ commit で baseline を再生成する (file 名は着手時点の `XCODE_SDK` から導出される)。
- `CHANGES.md`: `## develop` の種別順の主リストに `[CHANGE]` を追加する (担当者行 `- @t-miya` を含める)。
- `issues/0070-change-migrate-to-webrtc-c-xcframework.md`: 行数表の `Utilities.swift` の行数と、`Sora/*.swift` 計、`Sora/` 配下計、および 12 行目と 67 行目の計測日の注記を確認する。`Utilities.swift` の行数が減って古くなる場合は、着手時に `wc -l` で再計測した値と実施日で更新し、行数順を保つ位置へ移す。`0115` または `0070` の Phase 2 が `Utilities.swift` の `import WebRTC` を除去している場合は、その記述に合わせて更新する。更新が不要と判断した場合は、その理由を「解決方法」に記録する。
- `SoraTests/`: `0182` 完了後に `randomString` を参照する宣言がある場合だけ削除する (参照だけの場合はその行、テスト関数内の場合は関数ごと、file 全体が `randomString` 専用の場合は file ごと)。

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行う。以下に書く Xcode と SDK と simulator の版数は 2026-09-29 時点の値であり、着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` と baseline の file 名、`xcrun simctl list runtimes` の結果に読み替える。

- Xcode の指定方法は target ごとに異なる。`XCODE=` が効くのは `make consumer-build` / `make consumer-check-negative` / `make api-baseline` / `make api-check` / `make api-check-fresh` だけである (`Makefile` が `DEVELOPER_DIR` として使う)。`XCODE_SDK=` はこれらに加えて `make build` の `-sdk` にも効く。`make build` / `make fmt-lint` / `make lint` と素の `xcodebuild` は `XCODE` を参照しないため、Xcode を切り替える場合は `xcode-select -s` または `DEVELOPER_DIR=<Xcode>/Contents/Developer` を使う。
- `make build` (Sora scheme の clean build) が成功すること。
- `SoraTests` を実行し失敗 0 件であること。E2E は環境変数が無い場合 skip される。シミュレータが無い環境では iOS 26.5 の runtime を用意し、`.github/workflows/e2e-test.yml` の `Setup iOS Simulator` と同じ手順で `iPhone 17 Pro` を作成してから実行する (同 step の `xcrun simctl create` は runtime を指定しないため、最新 runtime が 26.5 でない環境では `xcrun simctl list runtimes` で確認した runtime を明示する)。

  ```
  xcodebuild test -scheme Sora-Package -derivedDataPath build \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6
  ```

- consumer package を clean build して 3 scheme の log を取り、`ConsumerLegacy` の log に `'randomString(length:)' is deprecated` が出ず、`Check Deprecation Warning` が検査する他の symbol の warning はすべて出ていることを確認する (`Check Deprecation Warning` は CI の step なので、ローカルでは build log で代替する。incremental build では warning が出ないため `build/consumer` を削除してから実行する)。対象の symbol は `.github/workflows/consumer-test.yml` の一覧から取り出す (件数は `0114` / `0115` / `0116` / `0117` などの進行で変わるため固定しない)。

  ```
  set -euo pipefail
  rm -rf build/consumer
  make consumer-build SCHEME=ConsumerCore 2>&1 | tee build/consumer-core.log
  make consumer-build SCHEME=ConsumerUI 2>&1 | tee build/consumer-ui.log
  make consumer-build SCHEME=ConsumerLegacy 2>&1 | tee build/consumer-legacy.log
  test -s build/consumer-legacy.log
  ! grep -Fq "'randomString(length:)' is deprecated" build/consumer-legacy.log
  for symbol in $(sed -n '/^        symbols=(/,/^        )/p' .github/workflows/consumer-test.yml | grep -o "'[^']*'" | tr -d "'"); do
    grep -Fq -- "'$symbol' is deprecated" build/consumer-legacy.log
  done
  ```

- CI の `Check Negative Checks` と同じ `make consumer-check-negative` を実行する。あわせて CI の `Check No Test-Only Import` と同じ検査を実行する (コマンドは `.github/workflows/consumer-test.yml` の同 step の記述をそのまま使う。`:(glob)TestConsumers/Swift6Consumer/**/*.swift` を対象にし、0 件で終了コード 1 が正常である)。
- baseline の再生成と consumer package の更新を終えた後、次の検索が 0 件であること (`--untracked` で未追跡 file も対象にする。`issues/` は履歴、`CHANGES.md` は削除の告知に `randomString` を含むため除外する)。

  ```
  git grep -n --untracked randomString -- . ':!issues' ':!CHANGES.md'
  ```

- baseline を再生成する前に `make api-check` を実行し、`Utilities` の名前空間と `randomString(length:)` の削除だけが `API breakage` として報告されることを `build/consumer/api-check.log` で確認する。`make api-check` は出力が空でなければ失敗する実装 (`Makefile` の api-check) なので、この失敗は想定どおりであり、終了コードではなく出力で判定する。
- `make api-baseline` で baseline を再生成する (依存で `ConsumerCore` を build する)。`make api-baseline` は dump を `build/consumer/api-baseline.json` に残すため、再生成前の baseline とこの dump を `API_BASELINE_DIFF` と同じ集計で比較し、Removed declarations 2 件 / Added declarations 0 件であることを確認する。2 件の内訳は `Utilities` (`[Enum]`) / `randomString(length:)` (`[Func]`) である。次の比較は baseline の再生成を commit する前に実行する (`git show HEAD:` は commit 済みの baseline を返すため、commit 後では差分が 0 件になり検証にならない)。3 番目のコマンドは差分があると終了コード 2 を返す (`Makefile` の規約) ため、出力と log で判定する。

  ```
  git show HEAD:TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json > build/consumer/api-baseline-head.json
  sed -n '/^define API_BASELINE_DIFF$/,/^endef$/p' Makefile | sed '1d;$d' > build/consumer/api-baseline-diff.py
  python3 build/consumer/api-baseline-diff.py build/consumer/api-baseline-head.json build/consumer/api-baseline.json build/consumer/api-baseline-diff.log
  ```

- 再生成した baseline の差分を読み、`Utilities` と `randomString(length:)` の削除以外の差分 (型の変更、準拠の削除、`printedName` / `declKind` の変化、他の symbol の消滅) が無いことと、`Optional.unwrap(ifNone:)` と `PairTable` の宣言が残っていることを確認する。生の行差分は部分木の削除に伴う行番号ずれで大きく出るため、宣言単位の集計で判定する (`CODEBASE.md` の baseline 更新手順)。
- `git diff -- CHANGES.md` を読み、完了条件の `[CHANGE]` の (a)〜(e) を満たすことを確認する。
- `git diff -- issues/0070-change-migrate-to-webrtc-c-xcframework.md` を読み、更新した場合は行数表の全行と 12 行目と 67 行目の合計と計測日の注記が着手時の再計測値になっていることを、更新しなかった場合はその理由が「解決方法」に書かれていることを確認する。
- `make api-check-fresh` が成功すること (`make api-check` を含む)。
- `make fmt-lint` が成功し、`swiftlint lint --strict` が違反 0 件であること。`make lint` は `swiftlint --fix .` を実行して file を書き換えるため、実行後に `git diff` を読み、意図しない整形が混入していないことを確認する。

## 完了条件

- `Sora/Utilities.swift` から、`Utilities.randomString(length:)` の宣言、`fileprivate` の `randomBaseString` / `randomBaseChars`、および `public enum Utilities` の宣言全体が削除され、`Optional.unwrap(ifNone:)` と `PairTable` の宣言は残っていること。
- 上記の `git grep --untracked` が 0 件であること。
- consumer package の `DeprecatedAPI.swift` の参照、`consumer-test.yml` の symbol 一覧、`skills/sora-ios-sdk/SKILL.md` の「非推奨 API」表に `Utilities.randomString` が残っていないこと。
- 代替 utility と `randomString` の名前を残す shim を追加していないこと。
- `CHANGES.md` の `## develop` の種別順の主リストに `[CHANGE]` が追加され、(a) `Utilities.randomString` を削除すること、(b) 代替が標準の乱数 API であること、(c) issue 番号を書かないこと、(d) エントリの最後に 2 文字インデントで担当者行があること、(e) 変更内容が「〜する」の形で書かれていることが満たされていること。
- baseline の差分が `Utilities` の名前空間と `randomString(length:)` の 2 宣言の削除だけ (Removed 2 件 / Added 0 件) で、`Optional.unwrap(ifNone:)` と `PairTable` の宣言が残っていること。`make api-check-fresh` が成功すること。
- `make build` が成功し、`SoraTests` が失敗 0 件で、consumer package の 3 scheme の build が成功し、`make consumer-check-negative` と CI の `Check No Test-Only Import` と同じ検査が成功すること。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること (SwiftPM の manifest 解決ができない環境では、同じ `.swiftlint.yml` で `swiftlint --fix` と `swiftlint --strict` を直接実行した結果で代替し、その旨を「解決方法」に記録する)。
- `issues/0070-change-migrate-to-webrtc-c-xcframework.md` を更新した場合、行数表と 12 行目と 67 行目の合計と計測日の注記が着手時の再計測値になっていること (更新しない場合は、その理由が「解決方法」に書かれていること)。

## pending にした理由

D (`0182` の非推奨化と移行案内を含む release) が公開されておらず、R の version 条件も未達である (現行の `SDKInfo.version` は `2026.4.0-canary.0`)。`0182` は非推奨化側の issue で `Completed:` が埋まっていない。`0115` (`Utilities.Stopwatch` の削除) も `issues/pending/` にあり未完了であり、`Utilities` 名前空間を削除できない。

## 解決方法

## Pending 解除条件

- 前提の D の確認点 (deprecation annotation の削除予定と移行方針、`DeprecatedAPI.swift` の参照、`consumer-test.yml` の symbol 一覧、`CHANGES.md` の D の節のエントリ) を満たす release の tag が存在し、`0107` が完了していること。
- D の非推奨 message が示す削除予定時期以降に公開される release があること (前提の R の条件)。
- `0115` が完了していること。
- `0182` が完了した時点の develop で `SoraTests` に `Utilities.randomString` の参照が無いこと (ある場合は変更対象に含める)。
- 磨き上げ済みの本 issue と `issues/0070-change-migrate-to-webrtc-c-xcframework.md` が develop にコミットされていること。
