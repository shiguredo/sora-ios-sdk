# SwiftPM manifest を Swift 6 language mode に更新する

- Created: 2026-08-27
- Completed: 2026-09-29
- Branch: feature/update-swiftpm-language-mode
- Polished: 2026-09-29

## 目的

`Package.swift` を Swift 6 対応の tools version と language mode へ更新し、CI の command-line override ではなく package manifest を SwiftPM consumer の正本にする。

SDK target と downstream consumer が同じ Swift language mode で compile されることを保証する。

あわせて、Swift 6 言語モードで SDK target に出る concurrency 系の警告を恒久的に gate にする。この gate だけは consumer の compile 条件に影響させないため、manifest ではなく repo の build 経路に置く (設計方針)。

## 現状

`Package.swift` は `swift-tools-version:5.3` で、`swiftLanguageModes` と旧 `swiftLanguageVersions` のどちらも指定していない。`Sora` target と `SoraTests` target に `swiftSettings` は無い。2026-09-29 の Xcode 26.6 / Swift 6.3.3 で `swift package dump-package` を実行した実測は、`toolsVersion` が `5.3.0`、`swiftLanguageVersions` が未指定 (`null`) である。

一方、`README.md` のシステム条件は Xcode 26.6 以降で「Swift 6 言語モードでビルドしています」と説明し、`Makefile` の `build` と `.github/workflows/build.yml` / `.github/workflows/e2e-test.yml` は `xcodebuild` に `SWIFT_VERSION=6` を渡している。この override は SwiftPM consumer へ伝播しないため、consumer が SDK へ適用する language mode は Swift 5 のままである。2026-09-29 の `make consumer-build SCHEME=ConsumerCore` の log では、`Sora` target の compile が `-swift-version 5`、consumer 自身の `ConsumerCore` target が `-swift-version 6` で走っている。

manifest を変更せずに CI だけで Swift 6 を指定すると、SDK repository 内の build と利用者の package resolution / compile condition が一致しない。

### 実測 (2026-09-29、Xcode 26.6 / Swift 6.3.3)

`0155` / `0157` / `0173` / `0177` / `0181` の完了で `Sora` target の concurrency 系の診断は 0 件になっており、gate を有効にできる。実装可否は次の実測で判断した。

- `Sora/` を `-swift-version 6` で型検査した一次行 (行頭が `Sora/<file>:<line>:<col>: warning:`) は 17 件 / error 0 件である。内訳は `#DeprecatedDeclaration` が付く 12 件と、非推奨 message が複数行にわたる 5 件で、`#SendableClosureCaptures` と `add '@preconcurrency'` は 0 件である
- 同じ型検査に `-warnings-as-errors -Wwarning DeprecatedDeclaration` を足すと error 0 件 / warning 17 件である。gate で error になる concurrency 系の警告は残っていない
- `make build` (scheme `Sora` / iOS device / Release) は warning 17 件 / error 0 件である。17 件は同じ非推奨 API の警告である
- `make consumer-build SCHEME=ConsumerCore` は `Sora` target を `-swift-version 5` で build する。Xcode は package 依存の target の compile に `-suppress-warnings` を渡す
- `Sora` target の `swiftSettings` に `.treatAllWarnings(as: .error)` を入れると consumer の build が `error: conflicting options '-warnings-as-errors' and '-suppress-warnings'` で失敗する (設計方針)
- この package は `platforms: [.iOS(.v14)]` の iOS 専用で、`WebRTC.xcframework` も iOS の slice しか持たない。host (macOS) 向けの `swift build` は `no such module 'UIKit'` で失敗し、`swift build --triple arm64-apple-ios14.0-simulator` でも host の SDK が選ばれて失敗する。検証経路は `xcodebuild` である

## 前提となる issue

- `0107` (完了 2026-09-24): Swift 6 consumer package と公開 API baseline を追加する。本 issue は consumer package の 3 scheme と `make api-check-fresh` を検証に使う。
- `0169` (完了 2026-09-24): 対応する最低 Xcode を 26.6 に上げる。README のシステム条件と CI の Xcode が 26.6 に揃っていることが tools version の上限の根拠になる。
- `0118` (完了 2026-09-25): E2E テストの concurrency 診断抑止を除去する。本 issue は `SoraTests` target の `swiftSettings` を変更しない (検証方針)。
- `0155` (完了 2026-09-28) / `0157` (完了 2026-09-25) / `0173` (完了 2026-09-28) / `0177` (完了 2026-09-29) / `0181` (完了 2026-09-29): `Sora` target の concurrency 系の警告を解消する。これらの完了で `Sora/` の `#SendableClosureCaptures` は 0 件になり、gate を有効にできる。
- `0171` (open): `SoraTests` target の warnings-as-errors gate。本 issue の後に実施し、検証方針が test target の gate を委譲する先になる。

gate が止めた警告を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならない。ここでいう「隠す」は、警告が消えたかどうかではなく、追加する型が次の 3 条件をすべて満たすかどうかで判定する。満たす場合は例外として認め、どの経路のどの型をなぜ認めたかを、その型の doc コメントと、その型を追加した issue の「解決方法」に記録する。本 issue の実装では新しい `@unchecked Sendable` も `@preconcurrency` も追加しない (現状の gate は error 0 件で通る)。

- (1) 追加する型自身が可変状態を持たず、保持する値が `init` で確定した不変値であること。可変状態を持つ型を追加する場合は、この条件を「可変状態の読み書きのすべてが単一の排他に閉じていること」と読み替えて適用する。この読み替えで例外として認めた前例は `0106` の `LoggerStateStorage` (NSLock が `level` / `groups` / `onOutputHandler` への全アクセスを保護する) と `0177` の `PeerChannelTransportStorage` であり、`0181` の `StopwatchStorage` (NSLock が `seconds` への全アクセスを保護し、`handler` は `init` で確定する不変値) も同じ読み替えで認める。
- (2) その値が変更前から同じ系統の非同期境界 (`DispatchQueue` / WebRTC や AVFoundation の callback / `Timer`) へ渡されており、追加する型は配送先・順序・呼び出し回数を変えず、別系統の境界へ新たに渡すこともないこと。
- (3) 追加する型が保持するのは closure と、その closure が変更前から一緒に捕捉していた参照だけであり、SDK 内部の参照型 (`MediaChannel` / `PeerChannel` / `DataChannel` / `ConnectionTask` など) を新たに保持しないこと。

## 設計方針

### manifest の更新

- `swift-tools-version` を `6.3` へ更新する。最低開発環境は README のシステム条件の Xcode 26.6 以降であり、Xcode 26.6 が同梱する Swift 6.3.3 の SwiftPM が読み取れる tools version の上限が 6.3 である (2026-09-29 に実測。6.3 は受理され、7.0 は `package is using Swift tools version 7.0.0 but the installed version is 6.3.3` で拒否される)。最低 Xcode を 26.6 に上げた `0169` により、tools version の引き上げで新たにサポート対象外になる consumer はいない。実装時は `swift package --version` と `PackageDescription` で上限と manifest API を再確認する。
- package initializer に `swiftLanguageModes: [.v6]` を明示する。tools version 6.3 では `swiftLanguageVersions` は非推奨のため `swiftLanguageModes` を使う。`swift package dump-package` の JSON では `swiftLanguageVersions` キーに `["6"]` として現れる (2026-09-29 に実測)。`swiftLanguageModes` は package 全体の既定で、`swiftSettings` で language mode を上書きしていない `Sora` と `SoraTests` の両 target に適用される。
- iOS deployment target の `.iOS(.v14)` は維持する。
- `Package.swift` 内の既存 product、target、binary target、platform、dependency (`SwiftLintPlugins`) の意味を変更しない。`Sora` target に `swiftSettings` を追加しない (gate は repo の build 経路に置く)。
- `.defaultIsolation(MainActor.self)` のような default actor isolation の変更を行わない。`swiftLanguageModes: [.v6]` を宣言しても default isolation は nonisolated のままである。UI 型の MainActor 隔離の整理は本 issue の対象外とする。
- CI の `SWIFT_VERSION=6` は残す。manifest の language mode と異なる値が build 設定から混入していないことを log の `-swift-version` で確認できる冗長な経路として残し、値も経路も変えない。

### warnings-as-errors gate の置き場所

- `Sora` target の gate は `Package.swift` の `Sora` target の `swiftSettings` に置かない。Xcode は package 依存の target の compile に `-suppress-warnings` を渡すため、`.treatAllWarnings(as: .error)` が生成する `-warnings-as-errors` と衝突して consumer の build が失敗する。2026-09-29 の Xcode 26.6 で次のとおり再現した (衝突する組合せはいずれも `error: conflicting options '-warnings-as-errors' and '-suppress-warnings'` で `** BUILD FAILED **`)。
  - path 依存 (`.package(path:)`) と git URL 依存 (`.package(url:)`) の両方で再現する
  - `.treatAllWarnings(as: .error)` 単独でも、`.treatWarning("DeprecatedDeclaration", as: .warning)` を併記しても再現する
  - `make consumer-build` の `xcodebuild` に `SWIFT_SUPPRESS_WARNINGS=NO` を渡すと repo の consumer 検証は通るが、外部の consumer の Xcode project 設定に依存するため公開 manifest では採用しない
- gate は repo の build 経路 (`Makefile` の `build` と `.github/workflows/build.yml` の `xcodebuild`) に `OTHER_SWIFT_FLAGS='-warnings-as-errors -Wwarning DeprecatedDeclaration'` を渡して有効にする。2026-09-29 に `xcodebuild -scheme Sora ... SWIFT_VERSION=6 OTHER_SWIFT_FLAGS='-warnings-as-errors -Wwarning DeprecatedDeclaration'` が warning 17 件 / error 0 件で `** BUILD SUCCEEDED **` になることを実測した。
  - `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` と `OTHER_SWIFT_FLAGS='-Wwarning DeprecatedDeclaration'` の組合せは使えない。Xcode は `OTHER_SWIFT_FLAGS` を `-warnings-as-errors` より前に並べるため、非推奨 API の警告が error になる (2026-09-29 に実測。この invocation は error 17 件で `** BUILD FAILED **`)。`-warnings-as-errors` と `-Wwarning DeprecatedDeclaration` を同じ `OTHER_SWIFT_FLAGS` にこの順で書く。逆順にすると非推奨 API の警告が error 17 件になる (2026-09-29 に実測)。
  - `-Wwarning DeprecatedDeclaration` で warning に戻すのは、`DeprecatedDeclaration` を error にする対象から次の 2 種を外すためである。17 件の内訳はこの 2 種だけである。
    - iOS SDK 由来の deprecation (`Sora/Sora.swift` の `allowBluetooth` 1 件、`Sora/URLSessionWebSocketChannel.swift` の `kCFStreamPropertyHTTPSProxyHost` / `kCFStreamPropertyHTTPSProxyPort` 2 件)。`0138` が対象外とする
    - SDK が後方互換のために残している非推奨 API の内部参照 (`Configuration.multistreamEnabled` / `Configuration.simulcastRid` / `MediaChannelHandlers.onDisconnectLegacy` / `MediaChannelHandlers.onReceiveSignaling`) と、`0138` が解消するまで残る `ICEServerInfo.tlsSecurityPolicy` の内部参照。`0138` の完了後も前者の参照は残る
  - gate を入れるのは scheme `Sora` の build だけにする。`.github/workflows/e2e-test.yml` の `build-for-testing` は scheme `Sora-Package` で `SoraTests` も build するため、同じ flags を入れると `SoraTests` の非推奨以外の警告で落ちる。`SoraTests` の gate は `0171` が manifest の `swiftSettings` で行う (test target は consumer から build されないためこの衝突は起きない)。
- gate を repo の build コマンドに置くため、consumer の build では `Sora` target の concurrency 警告は gate されない。`.treatAllWarnings` を公開 manifest に置けない制約からくる意図的な範囲である。consumer の build は language mode の変更で壊れないことの確認に使う (検証方針)。

### ドキュメントと変更履歴

- tools version の引き上げにより SwiftPM 6.3 未満では package を解決できなくなる。最低 Xcode version と SwiftPM compatibility への影響を `README.md` と `skills/sora-ios-sdk/SKILL.md` と `CHANGES.md` に明示する。
  - `README.md` の「システム条件」に、SwiftPM で取り込む場合は SwiftPM 6.3 以降 (Xcode 26.6 以降) が必要であることと、SDK が manifest で Swift 6 言語モードを宣言しているため consumer 側の設定なしに Swift 6 言語モードで compile されることを追記する。iOS 14 以降と Xcode 26.6 以降の箇条は `0169` で揃っており変更しない。
  - `skills/sora-ios-sdk/SKILL.md` の「Swift 6 と並行性」の冒頭は「`Package.swift` の `swift-tools-version` は 5.3 のため、SwiftPM で取り込んだ場合にパッケージ側へ適用される言語モードは Swift 5 になる。CI の `SWIFT_VERSION=6` は通常の SwiftPM consumer へ伝播しない」と書いており、実装後の状態と矛盾する。`swift-tools-version` が 6.3 で `swiftLanguageModes: [.v6]` を宣言しており、SwiftPM で取り込むと SDK が Swift 6 言語モードで compile されるという記述へ差し替える。同じ節の注意点の列挙 (`Sendable` 準拠・コールバックのスレッド・`@preconcurrency import Sora` など) は本 issue の対象外であり変えない。
  - 同 `SKILL.md` の「現状の制約」の「`Package.swift` の `swift-tools-version` は 5.3 のままで、manifest からの Swift 6 言語モード指定は未対応」の箇条は実装後に成立しなくなるため削除する。同じ節の他の箇条 (Sendable な event / RPC / statistics API が未提供、サンプル集とクイックスタートの暫定対応) は変えない。

### `CHANGES.md`

`## develop` の主リストの `[CHANGE]` の並びの末尾 (最初の `[ADD]` の前) に次のエントリを追加する (インデントはこの節の入れ子のためのもので、`CHANGES.md` へは外して追記する)。

```
- [CHANGE] `swift-tools-version` を 6.3 に上げ、Swift 6 言語モードを manifest で宣言する
  - SwiftPM 6.3 未満 (Xcode 26.6 未満) では package を解決できなくなる。README のシステム条件は Xcode 26.6 以降であり、サポート範囲内の利用者への影響はない
  - `swiftLanguageModes: [.v6]` により、SwiftPM で取り込んだ consumer も SDK を Swift 6 言語モードで compile する。公開 API と SDK の挙動は変わらない
  - @t-miya
```

## 検証方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行する。

- `swift package dump-package` の JSON で `toolsVersion` が `6.3.0`、`swiftLanguageVersions` が `["6"]`、`platforms` が iOS `14.0` であること。`Sora` target の `settings` が空のまま (gate を manifest に置かない) であること。
- `make build` が成功し、log の `-module-name Sora ` の compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で現れ、同じ行の `-swift-version` が `6` であること。warning は 17 件 (すべて非推奨 API) / error 0 件であること。この build が manifest の language mode と gate の正本であり、型検査は補助である。

  ```
  make build 2>&1 | tee build/0108-make-build.log
  ```

  - 件数は `grep -cE 'Sora/[^ ]+:[0-9]+:[0-9]+: warning:' build/0108-make-build.log` で数える。型検査の log も同じ正規表現で数えられる
  - `Makefile` と `.github/workflows/build.yml` の `OTHER_SWIFT_FLAGS` が同じ文字列であること (`git grep -n OTHER_SWIFT_FLAGS`)
- `Sora/` の型検査は補助として実装前後で値が変わらないことを確認する。

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0108-typecheck.log
  ```

  - 一次行が 17 件 / error 0 件で、`#SendableClosureCaptures` と `add '@preconcurrency'` が 0 件であること。同じ flags に `-warnings-as-errors -Wwarning DeprecatedDeclaration` を足した結果も error 0 件 / warning 17 件であること
- consumer package の 3 scheme を build する。`Sora` target の compile 行が `-swift-version 6` になり、`-swift-version 5` で走る target が無いこと。`Sora` target の compile 行は `-suppress-warnings` のままで `-warnings-as-errors` を含まないこと (含めると衝突して失敗する)。incremental build では compile が省略されて flag が log に出ないため、log を取る前に `rm -rf build/consumer` を実行する。

  ```
  rm -rf build/consumer
  make consumer-build SCHEME=ConsumerCore 2>&1 | tee build/0108-consumer-core.log
  make consumer-build SCHEME=ConsumerUI 2>&1 | tee build/0108-consumer-ui.log
  make consumer-build SCHEME=ConsumerLegacy 2>&1 | tee build/0108-consumer-legacy.log
  ```

- `make api-check-fresh` を実行する。language mode の変更で公開 API dump に差分が出た場合は `CODEBASE.md` の「baseline を更新する手順」に従い、差分を読んで language mode に伴う意図した差分 (availability や隔離の注記) だけであることを確認してから再生成する。`Sora` の宣言を変える差分は本 issue に混在させず別 issue に分離する。
- `SoraTests` を現行 CI と同じ invocation (`.github/workflows/e2e-test.yml` の `build-for-testing`) で build して失敗 0 件であること。`SoraTests` target の `swiftSettings` は `0171` が追加するため、本 issue では追加せず、`SoraTests` の警告の件数も完了条件にしない。
- binary `WebRTC.xcframework` の import と iOS 14 deployment target が維持されることを確認する。`git diff Package.swift` で product `Sora` / `WebRTC` の名前、`binaryTarget` の URL と checksum、`Sora` target の `exclude` / `resources` が変わっていないことを確認する。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。`make lint` は `swift package plugin` を使うため、tools version の引き上げで manifest の解決が壊れていないことをこの経路でも確認できる。
- 退行検出: `OTHER_SWIFT_FLAGS` の 2 つの flag を逆順 (`-Wwarning DeprecatedDeclaration -warnings-as-errors`) にすると非推奨 API の警告が error 17 件になって `make build` が失敗することを確認する (2026-09-29 に実測)。あわせて `swiftLanguageModes: [.v6]` を外すと consumer package の `Sora` target の compile が `-swift-version 5` に戻ることを確認する。確認用の変更は commit しない。
- この package は iOS 専用のため `swift build` (SwiftPM CLI) は検証経路に使わない (現状)。

## 変更対象

- `Package.swift`: `swift-tools-version` を `6.3` に更新し、package initializer に `swiftLanguageModes: [.v6]` を追加する。`platforms` / `products` / `dependencies` / `targets` / `WebRTC` の `binaryTarget` は変更せず、`Sora` target と `SoraTests` target に `swiftSettings` を追加しない
- `Makefile`: `build` target の `xcodebuild` に `OTHER_SWIFT_FLAGS='-warnings-as-errors -Wwarning DeprecatedDeclaration'` を追加する
- `.github/workflows/build.yml`: `Build Xcode Project` の `xcodebuild` に同じ `OTHER_SWIFT_FLAGS` を追加する
- `README.md`: 「システム条件」に SwiftPM 6.3 以降 (Xcode 26.6 以降) が必要であることと、manifest が Swift 6 言語モードの正本であることを追記する
- `skills/sora-ios-sdk/SKILL.md`: 「Swift 6 と並行性」の冒頭の `swift-tools-version` 5.3 の記述を実装後の状態へ差し替え、「現状の制約」の manifest 未対応の箇条を削除する
- `CHANGES.md`: `## develop` の主リストに `[CHANGE]` を追加する (「設計方針」の `CHANGES.md` の文面)
- `TestConsumers/Swift6Consumer/ApiBaseline/`: language mode の変更で dump に差分が出た場合だけ、`CODEBASE.md` の「baseline を更新する手順」で再生成する。`Sora` の宣言を変える差分は別 issue に分離する
- `.github/workflows/e2e-test.yml` / `.github/workflows/consumer-test.yml`: 変更しない (`SoraTests` の gate は `0171`、consumer package の検証は現行のまま使う)

## 完了条件

- `Package.swift` の `swift-tools-version` が `6.3` で、package initializer に `swiftLanguageModes: [.v6]` が明示されていること。`Sora` target と `SoraTests` target に `swiftSettings` を追加していないこと。
- `swift package dump-package` が `toolsVersion` `6.3.0`、`swiftLanguageVersions` `["6"]`、iOS `14.0` を示すこと。
- `make build` が成功し (warning 17 件 / error 0 件)、log の `Sora` target の compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で現れ、`-swift-version 6` であること。
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` が成功し、log の `Sora` target の compile 行が `-swift-version 6` であること (`-swift-version 5` で走る target が無いこと)。`Sora` target の compile 行に `-warnings-as-errors` が入っていないこと。
- `make api-check-fresh` が成功し、公開 API baseline に意図しない削除・変更が無いこと。差分が出た場合は差分のレビューと再生成の記録があること。
- `SoraTests` が現行 CI と同じ invocation で失敗 0 件であること。`SoraTests` target の warnings-as-errors gate は `0171` の担当であり、本 issue で追加していないこと。
- package product、target、binary dependency、iOS deployment target の構成が意図せず変わっていないこと。
- `.defaultIsolation(MainActor.self)` などの default actor isolation の変更を追加しておらず、`@unchecked Sendable` と `@preconcurrency` を新規に追加していないこと。
- 最低 Xcode version と SwiftPM compatibility への影響が `README.md` と `skills/sora-ios-sdk/SKILL.md` に記載され、`SKILL.md` の「現状の制約」に manifest 未対応の記述が残っていないこと。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。
- `CHANGES.md` の `## develop` の主リストに `[CHANGE]` エントリが担当者行付きで追加されていること。
- Xcode 26.6 の 1 leg の CI (`build.yml` / `consumer-test.yml` / `e2e-test.yml`) が成功すること。

## スコープ外

- `Package.swift` の `Sora` target の `swiftSettings` に warnings-as-errors を入れること (設計方針のとおり consumer の build が壊れる)。gate は repo の build 経路にだけ置く
- `SoraTests` target の warnings-as-errors gate (`0171`)。`.github/workflows/e2e-test.yml` の `build-for-testing` への gate 追加も `0171` に含める
- `0138` (`Sora/` 内部の非推奨 API 利用の解消) と `0072` (iOS 18 の deprecation の解消)。本 issue は `DeprecatedDeclaration` を warning に戻したままにする
- default actor isolation の変更と、UI 型の MainActor 隔離の整理
- `0115` (`Utilities.Stopwatch` の削除)。`0181` の完了で本 issue の前提から外れた
- 公開 API の追加・変更 (差分が出た場合は別 issue に分離する)

## 解決方法

### manifest

- `Package.swift` の `swift-tools-version` を `5.3` から `6.3` へ上げ、package initializer の `targets` の後に `swiftLanguageModes: [.v6]` を追加した。`Sora` target と `SoraTests` target の `swiftSettings` は追加していない (gate を manifest に置かない)。`platforms` / `products` / `dependencies` / `targets` / `WebRTC` の `binaryTarget` は変更していない
- `swift package dump-package` の実測 (2026-09-29、Xcode 26.6 / Swift 6.3.3) は `toolsVersion` が `6.3.0`、`swiftLanguageVersions` が `["6"]`、`platforms` が iOS `14.0` で、`WebRTC` / `Sora` / `SoraTests` の `settings` はすべて空である

### warnings-as-errors gate

- gate は manifest に置かず、repo の build 経路に `OTHER_SWIFT_FLAGS='-warnings-as-errors -Wwarning DeprecatedDeclaration'` として置いた
  - `Makefile` の `build` target の `xcodebuild` (`SWIFT_VERSION=6` の直後)
  - `.github/workflows/build.yml` の `Build Xcode Project` の `xcodebuild` (同じ文字列)
- `git grep -n OTHER_SWIFT_FLAGS` で 2 file の文字列が一致することを確認した。`.github/workflows/e2e-test.yml` の `build-for-testing` (scheme `Sora-Package`) には追加していない (`SoraTests` の gate は `0171`)

### ドキュメント

- `README.md` の「システム条件」の Xcode 26.6 の箇条に、SwiftPM 6.3 以降が必要であることと、manifest が Swift 6 言語モードを宣言しているため consumer 側の設定なしに SDK が Swift 6 言語モードでコンパイルされることを追記した
- `skills/sora-ios-sdk/SKILL.md` の「Swift 6 と並行性」の冒頭を、`swift-tools-version` 6.3 と `swiftLanguageModes: [.v6]` により SwiftPM consumer でも Swift 6 言語モードになる記述へ差し替え、「現状の制約」の manifest 未対応の箇条を削除した
- `CHANGES.md` の `## develop` の主リストの `[CHANGE]` の末尾 (最初の `[ADD]` の前) に `[CHANGE]` エントリと担当者行 `- @t-miya` を追加した。`## develop` の `### misc` への `[UPDATE]` は `0171` の担当であり、本 issue では追加していない

### 実測

- `make build` (scheme `Sora` / iOS device / Release): **BUILD SUCCEEDED**。`-module-name Sora ` の compile 行 (SwiftDriver / Swift-Compilation / Swift-Compilation-Requirements の 3 行) に `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で現れ、同じ行の `-swift-version` が `6` である。一次行の warning 17 件 (すべて非推奨 API) / error 0 件
- `git grep -n OTHER_SWIFT_FLAGS`: `Makefile` と `.github/workflows/build.yml` の文字列が一致する (`-warnings-as-errors -Wwarning DeprecatedDeclaration`)
- consumer (`rm -rf build/consumer` の後に `make consumer-build`): `ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 scheme とも BUILD SUCCEEDED。`Sora` target の compile 行は `-suppress-warnings` のままで `-warnings-as-errors` を含まず、`-swift-version 6` である。`-swift-version 5` で走る compile 行は 3 scheme で 0 件
- `make consumer-check-negative`: `core-sendable-capture.swift` (`SendableClosureCaptures`) と `ui-isolated-conformance.swift` (`IsolatedConformances`) の 2 件が期待どおり失敗した
- `Sora/` の型検査 (`-swift-version 6`): 一次行 17 件 / error 0 件 / `#SendableClosureCaptures` 0 件 / `add '@preconcurrency'` 0 件。同じ flags に `-warnings-as-errors -Wwarning DeprecatedDeclaration` を足しても error 0 件 / warning 17 件
- 全体テスト: `xcodebuild test` は PTY 制約 (`Pseudo Terminal Setup Error ... Operation not permitted`) で起動できないため、`build-for-testing` (`** TEST BUILD SUCCEEDED **`) と `xcrun simctl spawn <booted-udid> .../Agents/xctest SoraTests.xctest` で代替した。441 件実行 / skip 31 / 失敗 0 件で基準どおり
- `make fmt-lint` 成功、`swiftlint lint --strict --cache-path build/swiftlint-cache` は 0 violations / 0 serious
- ApiBaseline: language mode の変更で公開 API dump に差分は出ず、`make api-check-fresh` が「The committed API baseline matches the current Sora module.」で成功した。`TestConsumers/Swift6Consumer/ApiBaseline/` は再生成していない (差分なし)
- `make lint` は検証環境の sandbox で `sandbox-exec: sandbox_apply: Operation not permitted` となり実行できない。manifest 自体は `-package-description-version 6.3.0` として compile されており、失敗は sandbox の入れ子制限による。`swift package --disable-sandbox plugin ... swiftlint --strict .` では 0 violations で plugin 経路の manifest 解決も確認した

### 退行検出

- `OTHER_SWIFT_FLAGS` を `-Wwarning DeprecatedDeclaration -warnings-as-errors` に逆順にすると `make build` は error 17 件で **BUILD FAILED** になった (確認後に戻した)
- `swiftLanguageModes` を外すと consumer の `Sora` target は `-swift-version 6` のままで、`-swift-version 5` には戻らなかった。`swiftLanguageModes: [.v5]` を明示すると `-swift-version 5` になることを実測した。tools version 6.3 の package は manifest で指定しなくても既定が Swift 6 言語モードであるため、`swiftLanguageModes: [.v6]` は既定と一致する明示宣言として機能する (検証方針の「外すと `-swift-version 5` に戻る」という記述は実測と食い違う)
- `swift build` (SwiftPM CLI) は host 向けに `no such module 'UIKit'` で、`--triple arm64-apple-ios14.0-simulator` でも host の SDK が選ばれて失敗するため、検証経路に使えないことを再確認した

### 残った懸念

- `Sora` target の gate は repo の build 経路にしか無いため、consumer の build では SDK の concurrency 系の警告は gate されない (`.treatAllWarnings` を公開 manifest に置くと consumer が `conflicting options` で壊れる制約による意図的な範囲)
- `-Wwarning DeprecatedDeclaration` で warning のまま残る 17 件は `0138` / `0072` の担当である。`0138` の完了後も後方互換のための非推奨 API 内部参照は残る
- `make lint` の `swift package plugin` 経路は検証環境の sandbox 制限で実行できない。`swiftlint lint --strict` の直接実行では 0 violations である
- tools version 6.3 では `swiftLanguageModes` の既定が Swift 6 のため、consumer の `-swift-version 5` への退行は `swiftLanguageModes` の削除ではなく tools version の引き下げでしか起きない
