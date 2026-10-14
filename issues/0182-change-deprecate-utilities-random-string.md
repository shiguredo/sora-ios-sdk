# `Utilities.randomString` を非推奨にする

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/change-deprecate-utilities-random-string
- Polished: 2026-10-14

## 目的

リポジトリ内で利用されておらず、Sora / WebRTC と関係しない汎用ユーティリティ `Utilities.randomString` を非推奨にし、利用者へ移行方針と削除予定を明示する。

本 issue は非推奨化だけを扱い、削除は `0183` (次期 major version) へ分離する。

## 優先度根拠

公開 API の整理であり、`0108` の warnings-as-errors ゲートには影響しない。`randomString` に deprecation を付けても SDK target 自身は同 API を参照していないため deprecation warning は出ず、有効化済みのゲート (`make build` の `-warnings-as-errors -Wwarning DeprecatedDeclaration`) を失敗させない。削除も次期 major version であり、当面の release を妨げないため Low とする。

## 現状

`Sora/Utilities.swift` の `public enum Utilities` (`/// :nodoc:`) が `public static func randomString(length: Int = 8) -> String` を公開している。実装は `Utilities.randomBaseChars` から `UInt32.random(in:)` で文字を選んで連結するだけで、Sora の接続・メディア機能や WebRTC の API に依存しない汎用の文字列生成である。

`git grep -n --untracked randomString -- . ':!issues' ':!CHANGES.md'` で一致する file は次の 2 つだけで、SDK のコードからの参照はない。`issues/` 配下の `0114` / `0181` / `0115` / `0183` と本 issue 自身にも `randomString` の言及があるが、いずれも実装対象の説明である。

- `Sora/Utilities.swift`: `public static func randomString(length: Int = 8) -> String` の宣言
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`: `randomString(length:)` (`usr` は `s:4Sora9UtilitiesO12randomString6lengthSSSi_tFZ`)

`Sora/` と `SoraTests/` と consumer package の Swift source、`skills/`、`README.md` を含むリポジトリ内の他の file のいずれにも `randomString` の利用箇所がない。

公開 API baseline 上の `Utilities` の子は `randomString(length:)` と `Stopwatch` の 2 つだけである。`Stopwatch` は `0114` (完了) で非推奨化済みであり、`0115` (pending) で削除が予定されている。`randomString` と `Stopwatch` の両方が削除されると `Utilities` 名前空間も削除できる。同じ file の `PairTable` は internal であり、`Optional.unwrap(ifNone:)` は `Utilities` の外の公開 extension である。

## 設計方針

- `Utilities.randomString(length:)` に `@available(*, deprecated, message: ...)` を付ける。
- deprecation message には、次期 major version で削除する予定であることと、移行方針 (利用者側で `UUID` や標準の乱数 API を利用する) を書く。既存の非推奨 API の message と同様に日本語で書き、削除予定時期と代替を明示する。
- シグネチャ (`length: Int = 8` と `String` の戻り値) と既存挙動を変更しない。
- 非推奨期間中は `randomString` を削除せず、後方互換を維持する。
- SDK 固有の代替ユーティリティを追加しない。Sora / WebRTC と関係しない汎用処理であり、利用者側が用途に合う仕組みを選べるようにする。
- `Utilities.Stopwatch` と `PairTable`、`Optional.unwrap(ifNone:)` には触れない。

## 変更対象

- `Sora/Utilities.swift`: `randomString(length:)` の宣言に `@available(*, deprecated, message: ...)` を追加する。宣言のシグネチャと実装は変更しない。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift`: `_ = Utilities.randomString()` として参照を追加し、deprecation warning が `ConsumerLegacy` の build log に現れるようにする (`0114` が `Stopwatch` の参照を追加済みの file と同じ)。`ConsumerLegacy` は warnings-as-errors が有効なため、`_ =` を付けない裸の呼び出しは戻り値の未使用 (`#NoUsage`) で error になる。warning 以外の source break がないことを確認する。
- `.github/workflows/consumer-test.yml`: `Check Deprecation Warning` step の `symbols` 一覧に `randomString(length:)` を追加する (同 step のコメントが、`DeprecatedAPI.swift` の参照を増減する作業では一覧も同時に更新することを定めている)。
- `CHANGES.md`: `## develop` の種別順の主リストに `[CHANGE]` を追加し、エントリには非推奨にする内容と削除予定時期 (次期 major version)、移行方針 (利用者側で `UUID` や標準の乱数 API を選ぶ) を書き、エントリの最後に担当者行 `- @t-miya` を付ける。`0183` は非推奨化 release の着手前提として、このエントリに非推奨化と移行案内が書かれていることを要求する。
- `TestConsumers/Swift6Consumer/ApiBaseline/`: deprecation annotation の追加を意図した差分として、同じ変更で baseline を再生成する (`CODEBASE.md` の baseline 更新手順に従い差分をレビューする)。

## テスト方針

モックやスタブは使用しない。

- `make build` が成功し、`randomString` の非推奨化で新しい warning が出ないこと (SDK 内に参照がないため deprecation warning は出ない)。`make build` は `0108` の warnings-as-errors ゲート (`-warnings-as-errors -Wwarning DeprecatedDeclaration`) が有効な正規の build 経路である。
- `Sora/` 全体を `swiftc -typecheck -swift-version 6` で型検査する場合は、`Sora/Utilities.swift` の `import WebRTC` のため `-sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"`、`-target arm64-apple-ios14.0-simulator`、`-F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator`、`-module-cache-path build/module-cache`、`$(find Sora -name '*.swift')` を渡す (`0108` の実測と同じ引数)。
- `make consumer-build SCHEME=ConsumerLegacy` が成功し、deprecation warning 以外の source break がないこと。incremental build では warning が出ないため、`build/consumer` を削除してから build する。
- `ConsumerLegacy` の build log に `'randomString(length:)' is deprecated` が出て、`Check Deprecation Warning` step の symbol 検査 (同じ log を対象にする) が成功すること。
- `make api-baseline` の後に `git diff TestConsumers/Swift6Consumer/ApiBaseline/` を読み、差分が `randomString(length:)` の deprecation annotation の追加だけであり、型の変更・準拠の削除・`printedName` / `declKind` の変化・他の symbol の消滅がないこと。`make api-check-fresh` が成功すること。
- `SoraTests` を実行し、失敗 0 件であること。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。
- テストには、非推奨期間を設ける理由を日本語コメントで明記する。

## 完了条件

- `Utilities.randomString` が deprecated であること。
- deprecation message に削除時期 (次期 major version) と移行方針が記載されていること。
- SDK 固有の代替ユーティリティを追加していないこと。
- `Utilities.randomString` のシグネチャと既存挙動を変更していないこと。
- consumer package で既存利用コードが compile できること。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` に `_ = Utilities.randomString()` の参照があり、deprecation warning 以外の source break がないこと。
- `.github/workflows/consumer-test.yml` の `Check Deprecation Warning` が検査する `symbols` 一覧に `randomString(length:)` があること。
- `CHANGES.md` の `## develop` の種別順の主リストに `[CHANGE]` エントリが追加され、非推奨にする内容と削除予定時期 (次期 major version)、移行方針が書かれ、エントリの最後に担当者行 `- @t-miya` があること。
- 公開 API baseline が再生成され、diff に意図しない変更がないこと (deprecation annotation の追加は意図した差分である)。
- 追加したテストと既存テストがすべて成功すること。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。

## 前提となる issue

- `0107` (完了): consumer package と公開 API baseline。`TestConsumers/Swift6Consumer/` の compile 検証と baseline 検証はこの完了を前提とする。
- `0114` (完了): `Utilities.Stopwatch` の非推奨化。同じ `Utilities` 名前空間で同じ非推奨化のパターンの前例であり、本 issue と同じ `DeprecatedAPI.swift` と `consumer-test.yml` の symbol 一覧を更新済みである。本 issue はこの 2 file に `randomString` の参照と symbol を追加する。
- `0115` (pending): `Utilities.Stopwatch` の削除。本 issue の対象ではないが、`0183` が `Utilities` 名前空間を削除する前提として完了を要求する。
- `0183` (`issues/pending/`): 本 issue の後に実施する `Utilities.randomString` の削除 (次期 major version)。`0115` (`Utilities.Stopwatch` の削除) の完了を前提にし、公開メンバーが 0 件になった `Utilities` 名前空間も削除する。

## スコープ外

- `Utilities.randomString` の削除は `0183` で扱う。
- `Utilities.Stopwatch` の非推奨化 (`0114`・完了) と削除 (`0115`・pending) は本 issue では扱わない。
- SDK が標準型へ追加している公開 extension (`Optional.unwrap(ifNone:)` / `Array.remove(_:where:)`) の是非は別途判断する。
- `Utilities` 名前空間の削除は `0183` で扱う。

## 解決方法
