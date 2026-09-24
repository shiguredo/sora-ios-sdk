# Swift 6 consumer の検証と公開 API baseline を追加する

- Created: 2026-08-27
- Completed: 2026-09-24
- Priority: High
- Branch: feature/add-swift6-consumer-verification-and-api-baseline
- Polished: 2026-09-18

## 目的

外部の iOS consumer が `Sora` を通常の package 依存として `import Sora` した状態で、Swift 6 の公開 API と strict concurrency 診断、および公開 API の意図しない変化を CI で検出できるようにする。

`@testable` による内部 API への依存と `@preconcurrency` による診断の抑止を使わず、warnings-as-errors 付きの compile と公開 API baseline を CI の gate にする。複数の Swift 6 対応 issue が本 issue の consumer package と baseline を前提にするため、Swift 6 対応の土台になる。

## 現状

`.github/workflows/build.yml` と `.github/workflows/ci.yml` は `xcodebuild` に `SWIFT_VERSION=6` を渡して SDK と E2E test target をビルドしている。Swift 6 language mode では strict concurrency は complete 相当になるため、診断自体は出ている。

現在の CI に無い gate は次のとおりである。

- `@testable` を使わない外部 consumer からの import (公開インターフェースの検証)
- warnings-as-errors (診断が build を止めないため、現行 CI は警告付きで通る)
- 外部 consumer 側の default actor isolation の明示
- `SoraTests` の E2E テストが使う `@testable @preconcurrency import Sora` の抑止を経由しない検証 (抑止の除去は `0118`)
- 公開 API の baseline (意図しない削除と型変更、`Sendable` 準拠の削除の検出)
- 同じ consumer package を複数の Xcode で検証する matrix

`Package.swift` は `swift-tools-version:5.3` で言語モードの指定を持たず、CI の `SWIFT_VERSION=6` は通常の SwiftPM consumer には伝播しない。manifest を正本にする作業は `0108` で扱う。

## 前提となる issue

- 本 issue は `0111` / `0112` / `0113` / `0138` の完了を待たずに着手できる。`Sora` target 自身の warning を 0 にすることは本 issue の対象外である。
- `0102` / `0106` / `0123` が `0107` に委ねた機械検査 (公開 API の差分と `Sendable` 準拠の削除の検出) を本 issue の baseline gate で担保する。
- compile scenario を追加する issue: `0027` / `0109` / `0110` / `0114` / `0116` / `0120` / `0124` / `0125` / `0152`
- baseline の差分だけを検証する issue: `0113` / `0117` / `0122`

## 設計方針

### consumer package の形態と配置

- consumer package はリポジトリ直下に新設する `TestConsumers/Swift6Consumer/` に独立した SwiftPM package として置く。Xcode project は使わない (`xcodebuild -scheme <Target>` で完結させ、project file と `TestConsumers/` 配下の生成物を管理しないため)。
- root の `Package.swift` は変更しない。consumer package を root package の target にしない (root の scheme 一覧、`xcodebuild -scheme Sora`、`swift package plugin swiftlint` に影響させない)。
- consumer package の `Package.swift` は `// swift-tools-version:6.2`、`platforms: [.iOS(.v14)]`、`name: "Swift6Consumer"` とする。
- root package への依存は `.package(name: "Sora", path: "../..")` と書き、product は `.product(name: "Sora", package: "Sora")` と `.product(name: "WebRTC", package: "Sora")` で参照する。`.package(path: "../..")` だけを使うと package identity が checkout ディレクトリ名になり `package: "Sora"` が解決に失敗するため、`name:` を明示する。
- target は `ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 つとし、それぞれに対応する library product を 1 つずつ宣言する。product を宣言しないと `xcodebuild` が生成する scheme が package 名だけになり `-scheme ConsumerCore` が存在しない。
- scenario は target ごとに `Sources/<Target>/<Scenario>.swift` を 1 ファイル追加するだけで build 対象になる形にする。追加手順、各 target の役割、どの作業がどの file を追加・削除するかの表は consumer package の README に書く。
- consumer package の依存は root package への path 依存だけなので `Package.resolved` は生成されない (実装時の確認で SwiftPM の workspace-state に現れる依存は `sora-ios-sdk` だけであり、SwiftLintPlugins は consumer package の graph に入らない)。WebRTC の artifact は root の `Package.swift` が URL と checksum で pin しているため解決結果は固定されるが、artifact の取得には network が必要になる。
- `TestConsumers/Swift6Consumer/.swiftpm/` と `.build/` は commit しない。`.build/` は現行の `.gitignore` (`.build/`) で無視されるが `.swiftpm/` は無視されないため、`.gitignore` に `TestConsumers/Swift6Consumer/.swiftpm/` を追加する。
- consumer package は library target のみとする (executable target / `@main` / トップレベルコードを置かない)。Xcode app target へのリンク、リソースバンドル、`WebRTC.xcframework` の embed、remote URL 依存での解決は検証対象にしない。

### compile scenario

各 scenario には「検査する公開 concurrency 契約」と「期待する診断」を日本語コメントで書く。scenario は型や関数として定義し、実行経路は持たない。戻り値のある API は未使用警告で error にならないよう `_ =` や `if let` で扱い、`async throws` の API は `try await` で呼ぶ。

- `ConsumerCore`: `nonisolated` 文脈で `Configuration` を組み立て、`signalingConnectMetadata` を設定し、`Sora.shared.connect(configuration:handler:)` (戻り値 `ConnectionTask`) を `_ =` で受け、`MediaChannel.rpc(method:params:)` を利用者定義の `RPCMethodProtocol` 準拠型 (`static var name`) で `try await` 呼び出しする。`MediaChannel.getStats(handler:)`、`MediaChannel.sendMessage(label:data:)` と `MediaChannel.setAudioSoftMute(_:)` (戻り値 `Error?`) も呼ぶ。期待: error 0 件、warning 0 件。Sendable な params / result を持つ新 RPC API の scenario は `0109` が追加する。
- `ConsumerCore`: 非推奨でない既存 callback API をすべて代入する。`SoraHandlers` の `onConnect` / `onDisconnect` / `onAddMediaChannel` / `onRemoveMediaChannel` / `onChangeAudioRoute`、`MediaChannelHandlers` の `onConnect` / `onDisconnect` / `onAddStream` / `onRemoveStream` / `onReceiveSignalingJSON` / `onDataChannel` / `onDataChannelOpened` / `onDataChannelMessage`、`MediaStreamHandlers` の `onSwitchVideo` / `onSwitchAudio`、`CameraVideoCapturerHandlers` の `onCapture` / `onStart` / `onStop`、`Configuration.webSocketChannelHandlers` の `onReceive` (`WebSocketChannelHandlers` の公開プロパティは `onReceive` のみ)。`VideoRenderer` は nonisolated な型で実装する。期待: error 0 件、warning 0 件 (これらの closure 型に `@Sendable` を付けないことが互換の条件である)。一覧は実装時に公開 handler のプロパティを列挙して突き合わせ、列挙手順を README に書く。
- `ConsumerUI`: target の default actor isolation が `MainActor` であることをコードで担保するため、scenario 側に `@MainActor` を書かずに `VideoView()` を生成し、`MediaStream.videoRenderer` へ代入して `start()` / `stop()` / `clear()` を呼ぶ。UIKit 由来の呼び出しで warning が出た場合は scenario をこの範囲に縮小し、隔離の担保は build ログの `-default-isolation MainActor` の観測で行う。期待: error 0 件、warning 0 件。
- `ConsumerLegacy`: 既存の非推奨 API (`Configuration.multistreamEnabled` / `simulcastRid` / `spotlightEnabled`、`MediaChannelHandlers.onDisconnectLegacy` / `onReceiveSignaling`、`ICEServerInfo.tlsSecurityPolicy`、`ICEServerInfo.init(urls:userName:credential:tlsSecurityPolicy:)`、`TLSSecurityPolicy`) を利用する。期待: deprecation warning のみ (error 0 件)。`SoraDispatcher` と `Utilities.Stopwatch` の参照は `0114` / `0116` が追加し、`0117` / `0115` が削除する (本 issue では追加しない)。
- `@MainActor` な型を現行の `VideoRenderer` へ準拠させるだけでは error にならない (Swift 6.3 は isolated conformance を推論し、`default:` で error になるのは非隔離文脈でその conformance を使ったときで、診断は `[#IsolatedConformances]` になる)。`0027` が追加する新しい `@MainActor` protocol と登録 API、legacy `VideoRenderer` 実装、`VideoView` の 4 ケースは `0027` 自身が追加する。

#### compile 失敗を期待する検証

`0109` は「`Sendable` を満たさない型を指定した場合に compile できないこと」を consumer package で確認する。このため、成功する scenario とは別に失敗を期待する置き場を用意する。

- `TestConsumers/Swift6Consumer/NegativeChecks/core-<Scenario>.swift` と `ui-<Scenario>.swift` はどの target にも含めない。`NegativeChecks/` 直下の `.swift` はこの接頭辞を必須とし、接頭辞が無いファイルや未知の接頭辞のファイルがあれば `make consumer-check-negative` は失敗する。
- 各ファイルの先頭に `// EXPECT-DIAGNOSTIC: <group 名>` を 1 行だけ書く (`0109` / `0110` / `0120` / `0152` がこの規約で負例を追加する)。group 名は toolchain で変わりうるため、ファイルへ書く前に `swiftc -typecheck` の出力で実測して確定する (実測例: `ActorIsolatedCall` / `IsolatedConformances`)。
- `make consumer-check-negative` は `consumer-build` (既定の `ConsumerCore`) を前提とし、1 ファイルにつき 1 回の `swiftc -typecheck` 実行で検査する (隔離はプロセス単位の `-default-isolation` で与えるため、複数ファイルを 1 回に渡さない)。負例は `Sora` (`ui-` は `UIKit` も) を import する単独 file で target の build 設定に依存しないため `-scheme` は使わず、`core-` には `-default-isolation nonisolated`、`ui-` には `-default-isolation MainActor` を使う。付ける引数は `-swift-version 6`、`-sdk "$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)"`、`-target "$(API_TARGET)"`、`-I "$(PRODUCTS)"`、`-F "$(PRODUCTS)"`、`-module-cache-path "$(MODULE_CACHE)"`。
- 判定は「compile に失敗したこと」だけでは不十分 (無関係な typo でも通ってしまう) ため、そのファイルの `EXPECT-DIAGNOSTIC` の group 名が stderr の診断行に現れることを検査する。`ui-` の負例は `@MainActor` (または既定隔離が MainActor) の型を Sora の非隔離 protocol へ準拠させ、その conformance を `nonisolated` 文脈で使う形に限定する。ObjC SDK や `UIView` 継承型 (`VideoView` を含む) への非隔離呼び出しは warning と exit 0 になるため負例に使えない。
- あわせて、`EXPECT-DIAGNOSTIC` の group 名を含まない診断行 (`<file>:<line>:<column>: error:`) が 1 件でもあれば失敗させる (無関係な error が混ざった負例を成功扱いにしないため)。診断が引用するソース行とキャレット注釈行は診断行として扱わない (負例のソースに `error:` という文字列があっても誤検知しない)。
- 本 issue で 2 つ置いて機構が機能することを確認する (`core-sendable-capture.swift` は `SendableClosureCaptures`、`ui-isolated-conformance.swift` は `IsolatedConformances`。group 名は実装時に `swiftc -typecheck` の出力から実測して確定した)。以降の scenario 追加は対応する issue が行う。

### compiler settings

- consumer package の各 target の `swiftSettings` に次を設定する。これらは SwiftPM の `SwiftSetting` であり、`SWIFT_VERSION` / `SWIFT_TREAT_WARNINGS_AS_ERRORS` のような Xcode の build setting 名ではない。
  - `.swiftLanguageMode(.v6)`
  - `.defaultIsolation(nil)` (`ConsumerCore` / `ConsumerLegacy`。`nil` は「既定 (nonisolated) を使う」の意で、`nonisolated` を明示する API は無い)
  - `.defaultIsolation(MainActor.self)` (`ConsumerUI`)
  - `.treatAllWarnings(as: .error)` (3 target)
  - `.treatWarning("DeprecatedDeclaration", as: .warning)` (`ConsumerLegacy` のみ)
- `ConsumerLegacy` では `.treatAllWarnings(as: .error)` を先、`.treatWarning("DeprecatedDeclaration", as: .warning)` を後に書く。SwiftPM は宣言順に `-warnings-as-errors` と `-Wwarning` を並べるため、逆順にすると deprecation が error になり build できない。
- strict concurrency は Swift 6 language mode で complete 相当になるため `SWIFT_STRICT_CONCURRENCY` は設定しない (SwiftPM に strict concurrency 相当の `SwiftSetting` は無い)。consumer package の gate は `.swiftLanguageMode(.v6)` と warnings-as-errors で担保する。
- Xcode の build setting (`SWIFT_APPROACHABLE_CONCURRENCY` など) は consumer package に渡さない (`SWIFT_APPROACHABLE_CONCURRENCY` は Swift 6 language mode には適用されない設定である)。`xcodebuild` のコマンドライン引数でも設定を渡さない (渡すとローカル path 依存の `Sora` target にも伝播し、SDK 本体の既存 warning で consumer package の build が失敗する)。
- SwiftPM の `swiftSettings` は依存 package の target には適用されないため、`Sora` target は `Package.swift` の言語モード (本 issue 時点は Swift 5) でビルドされ、その warning は consumer package の gate に含まれない。Swift 6 の consumer が受け取る診断は `Sora` module のビルド言語モードに依存しない。

### GitHub Actions

- `.github/workflows/consumer-test.yml` を新規追加し、consumer package 専用の job (`swift6-consumer`) を置く。`runs-on: macos-26` とする (`sudo xcode-select` を使うため self-hosted は使わない)。既存の `build.yml` の runner / env / step は変更しない。
- consumer package は secret も self-hosted ランナーも実機も使わず、SDK の build 検証とはライフサイクルが独立しているため、workflow を分けて失敗を名前で区別できるようにする。あわせて `.github/workflows/ci.yml` を `.github/workflows/e2e-test.yml` にリネームし、`build.yml` と `e2e-test.yml` の `paths-ignore` に `TestConsumers/**` を追加する (consumer package だけの変更で SDK の build、lint、E2E を走らせない)。`consumer-test.yml` には `concurrency` を入れ、同じ ref への連続 push で古い実行を打ち切る。
- job の matrix は Xcode と SDK の組を 2 つ固定する。
  - `/Applications/Xcode_26.2.app` + `iphoneos26.2` (`README.md` のシステム条件の Xcode 26.2 に合わせた最低要件の leg。API baseline の比較以外の検査 (compile、負例、compiler settings、deprecation、test-only import) を検証する)
  - `/Applications/Xcode_26.6.app` + `iphoneos26.5` (`macos-26` イメージの default。self-hosted ランナーの `/Applications/Xcode.app` と同じ version。公開 API baseline の dump と比較に使う leg)
- 公開 API baseline は `-I` / `-F` に渡す module と同じ SDK で dump する必要があるため、dump と比較を同じ Xcode にそろえる。baseline は 26.6 + `iphoneos26.5` で生成し、`api-check` は同じ 26.6 leg でだけ実行する (26.6 はローカルにあり、dump から比較までの検証を CI に依存せず行える)。26.2 leg は同一のソースが最低要件の Xcode でも compile できることの確認に使う。
- 「利用可能な最新 26.x」を動的に選ばない (runner image の更新で暗黙に変わると失敗時の再現条件が固定されないため)。26.x が更新されたときは本 issue の matrix と `build.yml` の pin を見直す。`0108` の「最新 26.x」は本 issue の matrix の 26.6 leg を指す。
- 各 leg の最初に `sudo xcode-select -s '<xcode>/Contents/Developer'` を行い、その後に `xcodebuild -version`、`ls /Applications | grep Xcode`、`xcodebuild -list` をログへ出す (`xcodebuild -list` は `TestConsumers/Swift6Consumer` で実行し、3 scheme の存在を確認する)。指定した Xcode と scheme が存在しない場合は skip せず失敗させる。
- `ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` を scheme ごとの step で build する (`make consumer-build SCHEME=<Target> XCODE=${{ matrix.xcode }} XCODE_SDK=${{ matrix.sdk }}`)。失敗した契約を step 名で特定できるようにする。
- `make consumer-check-negative XCODE=... XCODE_SDK=...` を実行する step を置く。
- `consumer-build` のログに `-swift-version 6` / `-warnings-as-errors` / `-default-isolation nonisolated|MainActor` / `-Wwarning DeprecatedDeclaration` が現れることを検査する step を置く (target の設定が compiler まで届いていることを build ログで確認する。incremental build で compile が省略されると flags が現れないため、CI は毎回 fresh な checkout で build する)。
- `consumer-test.yml` には `timeout-minutes` と `fail-fast: false` を置く。`paths-ignore` は `**.md` と `LICENSE` だけとし、consumer package の変更でもこの workflow は走らせる。
- `@testable` / `@preconcurrency` が consumer package に無いことを検査する step を置く (`git grep -n -E '@testable|@preconcurrency' -- ':(glob)TestConsumers/Swift6Consumer/**/*.swift'` が一致したら失敗させる。git の既定の pathspec では `**/` が 0 階層に一致しないため target 直下の `Package.swift` が漏れる (実測: 既定の書き方で 8 file、`:(glob)` で 9 file) ので `:(glob)` を付ける。追跡ファイルの `.swift` だけを対象にし、`.build` と baseline の JSON を拾わない)。ソースのコメントと README にもこれらの語を書かない (README では「内部 API に依存しない」のように理由で書く)。
- `ConsumerLegacy` の build はログを `tee` で残し、consumer package が参照する非推奨 API がそれぞれ warning として出ていることを symbol 名で確認する (xcodebuild は diagnostic group 名を出力しないため `[#DeprecatedDeclaration]` では判定できない。実測では `warning: 'onDisconnectLegacy' is deprecated: …` の形で出る)。件数ではなく symbol 名で見るのは、warning の行数が Xcode の版で変わり得るためである。非推奨 API とその参照を削除する issue が、本 step の symbol 一覧と scenario を同時に更新する。
- API baseline の検証 step は `matrix.api_check` が true の leg (26.6 + `iphoneos26.5`) にだけ置き、`make api-check XCODE=${{ matrix.xcode }} XCODE_SDK=${{ matrix.sdk }}` として呼ぶ (baseline は dump したのと同じ SDK の module と比較する必要があるため、dump に使った leg でだけ実行する。SDK の文字列で判定すると 26.x 更新時に step が無言で skip されるため、matrix のフラグで判定する)。CI が呼ぶ make target は `api-check` だけとする。
- `make fmt-lint` と `make lint` を実行する step を置く。consumer package だけを変更した push では `build.yml` が `paths-ignore` で skip されるため、整形と lint の gate を `consumer-test.yml` 側にも置く (`make fmt-lint` と `make lint` の対象は `Makefile` と `.swiftlint.yml` で consumer package に広げている)。
- `slack_notify` は `consumer-test.yml` 側に置き、`needs: [swift6-consumer]` と `status: ${{ (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')) && 'failure' || 'success' }}` にする (`job.status` のままでは `swift6-consumer` の失敗が通知されず、`cancelled` も failure として扱う)。`build.yml` の `slack_notify` は `needs: [build]` に戻す。
- compile consumer package には E2E 用 secret を渡さない。`actions/checkout` は既存と同じ `@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` を使い、新しい外部 action を追加しない。

### 公開 API baseline

- 手段は `swift-api-digester` に固定する (`swift-symbolgraph-extract` は出力が 2.7 MB 程度になり pre-commit のサイズ上限と衝突するため採用しない)。
- baseline は `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`、生成情報は同ディレクトリの `iphoneos26.5.info.txt` に固定して commit する。dump 先は `build/` 配下 (`$(API_BASELINE_DUMP)`) とし、commit 済み baseline とは分ける。
- dump は Xcode 26.6 と `iphoneos26.5` がある環境で `make api-baseline` で実行する。**`info.txt` の `xcodebuild -version` / SDK が matrix の 26.6 と一致しない baseline は commit しない** (SDK が違うと差分が SDK 差で汚れる)。CI では dump せず、`api-check` が `$(PRODUCTS)` の module と commit 済み baseline を比較する。

dump は `Makefile` の `api-baseline` target が実行する。`-module Sora`、`-o` の dump 先、`-I` / `-F` の `$(PRODUCTS)`、`-sdk`、`-target`、`-module-cache-path` を渡す。

- `-avoid-location` / `-avoid-tool-args` を付けないと dump に絶対パスと実行情報が埋め込まれ、baseline が環境依存になり情報も漏れる。付けた dump は同一条件で再現する (2 回の dump がバイト一致することを実装時に確認する)。
- `-module-cache-path` を必ず指定する (省略すると `SwiftShims` の module cache を作れず `NO_MODULE` の JSON を書いて exit 0 になる環境がある)。dump 先のディレクトリは `mkdir -p` で作る。
- 検証は `Makefile` の `API_VALIDATE` が実行する (`api-baseline` は dump 直後の `$(API_BASELINE_DUMP)` を、`api-check` は比較の前に commit 済みの `$(API_BASELINE)` を引数に渡す)。`ABIRoot.name == "Sora"` であること、`ABIRoot` の `children` が 100 件以上であること、ファイルサイズが 1 MiB 以上であることを確認する。

- `set -e;` を `;` で連結したレシピ行に付ける (`make` はレシピ行ごとに終了ステータスを検査するため単独行の失敗は検出できるが、`;` で連結した行は最後のコマンドの終了ステータスしか返さない)。この検証が無いと、baseline が `NO_MODULE` のとき `-diagnose-sdk` が `API breakage` を出さず exit 0 になり gate が無言で無効化される (0 バイトや非 JSON では digester が異常終了し、切り詰められた JSON では偽の `API breakage` が出ることがある)。`api-baseline` は検証に通った場合にだけ `$(API_BASELINE)` を上書きする。
- 比較は次の形で行う。**`-diagnose-sdk` の「今回」側は `-I` / `-F` で読み込む `Sora` module であり、baseline は `-baseline-path` で渡す** (`-input-paths` は診断に使われないため付けない)。`-I` / `-F` は `$(PRODUCTS)` を指し、ここに読み込み可能な `Sora.swiftmodule` が無いと全シンボルが削除扱いになる。`-module Sora` を欠くと `Need to specify -include-all or -module <name>` で exit 1 になる。`-o` は診断の出力先にはならず空ファイルを作るだけなので付けない。

比較は `Makefile` の `api-check` target が実行する。commit 済み `$(API_BASELINE)` の検証、`$(API_BASELINE_INFO)` の `xcodebuild` / `sdk` / `target` と実行環境の突き合わせ、`swift-api-digester -diagnose-sdk -module Sora -baseline-path "$(API_BASELINE)" -I "$(PRODUCTS)" -F "$(PRODUCTS)" -sdk ... -target ... -module-cache-path ... -compiler-style-diags` の実行、出力の `$(API_CHECK_LOG)` への `tee` をこの順で行う。

- `set -o pipefail` は pipeline と同じレシピ行に書く (`make` はレシピを 1 行ずつ別シェルで実行するため、単独行では次行に効かない)。Makefile 内のシェルコマンド置換は `$$(...)` と書く (`$(...)` は make の変数展開になる)。breakage は warning として報告されるため終了コードは 0 になり得るので、終了コードではなく digester の出力で判定し、`$(API_CHECK_LOG)` が空でなければ (breakage でも toolchain の出力でも) 失敗させる。
- 非推奨シンボルの削除は既定で検出されるため `-enable-remove-deprecated-check` は付けない (既定値へ戻すだけの no-op)。`-disable-remove-deprecated-check` を付けると `0117` / `0122` の削除検出が無効になるため追加しない。
- `-diagnose-sdk` の出力に API の**追加**は現れない。追加時は同じ変更で baseline を再生成する (更新忘れは差分ゼロのため検出できない)。この点を手順に明記する。
- dump の出力は 1.7 MB 程度であり `prek.toml` の `check-added-large-files` (`--maxkb=500`) に抵触するため、`check-added-large-files` に `exclude = "^TestConsumers/Swift6Consumer/ApiBaseline/.*\\.json$"` を追加する (上限値は変更しない)。digester の出力 (baseline の JSON) は末尾改行で終わらないため `end-of-file-fixer` も同じ JSON を除外する (`*.info.txt` は末尾改行がありサイズも小さいため除外しない。除外しないと再生成のたびに 1 バイトの差分が出る)。除外の追加 → baseline の生成 → commit の順に行う (`check-useless-excludes` と `check-added-large-files` の両方を満たすため)。
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.info.txt` には `xcodebuild -version` / `xcrun --sdk iphoneos --show-sdk-version` / `-target` の値を 1 行 1 項目で書く (タイムスタンプと実行者名は入れない)。
- dump コマンド、比較コマンド、意図的な API の追加と deprecation と削除 (`0113` / `0117` / `0122` が行う `Sendable` 準拠と非推奨 API の削除を含む) で baseline を更新する手順、deprecation annotation 以外の差分を必ずレビューする手順、Xcode を更新したときに baseline を作り直す条件を `CODEBASE.md` に書く (`CODEBASE.md` は develop に既にあるため、既存の記述をリネームと CI の変更に合わせて更新する)。
- 検査が機能することを次で確認する。通常時 (シンボル削除なし) に `make api-check` が exit 0 で成功し、SDK の公開シンボルを一時的に 1 つ削除して `make consumer-build` からやり直すと exit 1 で失敗し、ログに `API breakage: … has been removed` が出ること。確認のための一時変更は 1 コミットとして push して CI run の URL を控え、`git revert` の打ち消しコミットを同じ PR に追加する (`git reset` と force push は行わない)。

### リポジトリのツールチェーンへの組み込み

- `Makefile` に `XCODE ?= /Applications/Xcode.app`、`XCODE_SDK ?= iphoneos26.5`、`CONFIGURATION := Release`、`DERIVED_DATA ?= $(CURDIR)/build/consumer`、`DERIVED_DATA_ABS := $(abspath $(DERIVED_DATA))`、`CONSUMER_DIR := TestConsumers/Swift6Consumer`、`PRODUCTS := $(DERIVED_DATA_ABS)/Build/Products/$(CONFIGURATION)-iphoneos`、`MODULE_CACHE := $(DERIVED_DATA_ABS)/module-cache`、`API_CHECK_LOG := $(DERIVED_DATA_ABS)/api-check.log`、`NEGATIVE_CHECK_LOG := $(DERIVED_DATA_ABS)/negative-check.log`、`API_BASELINE_DUMP := $(DERIVED_DATA_ABS)/api-baseline.json`、`API_TARGET := arm64-apple-ios14.0`、`API_BASELINE ?= $(CONSUMER_DIR)/ApiBaseline/$(XCODE_SDK).json`、`API_BASELINE_INFO ?= $(CONSUMER_DIR)/ApiBaseline/$(XCODE_SDK).info.txt`、`API_XCODE ?= 26.6`、`API_SDK_VERSION := $(patsubst iphoneos%,%,$(XCODE_SDK))`、`API_BASELINE_MIN_BYTES := 1048576`、`SCHEME ?= ConsumerCore` を定義する (`DERIVED_DATA` を相対パスで上書きされても `cd` の影響を受けないよう、build 成果物のパスは `abspath` から導出し `build/consumer` を literal で書かない)。baseline の file 名は `XCODE_SDK` から導出し、SDK を変えるときは `XCODE_SDK` と `API_XCODE` だけを変える。
- `xcodebuild` には `DEVELOPER_DIR="$(XCODE)/Contents/Developer"` を環境変数として渡す (`xcodebuild` は `XCODE` という引数を解釈しない)。consumer package 系の 4 target にだけ効かせる target 固有 export にし、既存の `build` / `fmt` / `fmt-lint` / `lint` の toolchain 選択と、利用者が指定した `DEVELOPER_DIR` を変えない。CI の matrix から `make ... XCODE=<path> XCODE_SDK=<sdk>` として渡し、`xcodebuild -version` で選択された Xcode が matrix と一致することを step のログで確認する。
- 次の target を追加する (`consumer-build` は 1 scheme だけを build し、CI が scheme ごとに step を分ける。loop にすると途中の失敗が最後の成功で隠れる)。`consumer-build` は `cd TestConsumers/Swift6Consumer` してから `-derivedDataPath "$(DERIVED_DATA_ABS)"` を渡す。
  - `consumer-build`: `SCHEME ?= ConsumerCore` の 1 scheme を `-configuration Release` / `-destination 'generic/platform=iOS'` / `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGN_IDENTITY=` / `PROVISIONING_PROFILE=` で build する。
  - `consumer-check-negative`: `consumer-build` を前提に、`NegativeChecks` を 1 ファイルずつ typecheck する。
  - `api-baseline`: `consumer-build` を前提に、(1) `$(API_BASELINE_DUMP)` へ dump、(2) `set -e;` 付きで `$(API_BASELINE_DUMP)` を検証、(3) `xcodebuild -version` と `xcrun --sdk $(XCODE_SDK) --show-sdk-version` が 26.6 と `iphoneos26.5` の組と一致することを確認、(4) `mkdir -p` で `$(API_BASELINE)` のディレクトリを作り、通った場合にだけ `cp` で `$(API_BASELINE)` を上書きし `$(API_BASELINE_INFO)` を再生成する。
  - `api-check`: commit 済み `$(API_BASELINE)` を `set -e;` 付きで検証し、`$(API_BASELINE_INFO)` の `xcodebuild` と `sdk` が実行環境と一致することを確認してから比較する (一致しない場合は baseline と別の SDK の module を比較することになるため、差分が SDK の差で汚れる前に失敗させる)。commit 済み baseline は書き換えない。
- 既存 `build` target の `-sdk iphoneos26.1` は Xcode 26.2 に更新したときの追随漏れで、どの環境でも SDK を解決できない。README のシステム条件と `build.yml` が指す `iphoneos26.2` に合わせる (`0167` で最低 Xcode を上げるときにこの値も同時に更新する)。
- `Makefile` の `.PHONY` に `consumer-build` / `consumer-check-negative` / `api-baseline` / `api-check` を追加する。
- CI は `api-check` だけを呼ぶ (`api-baseline` を呼ぶと commit 済み baseline を上書きし、自分自身との比較になって常に成功する)。
- `Makefile` の `fmt` / `fmt-lint` の対象に `TestConsumers/Swift6Consumer/Sources` / `TestConsumers/Swift6Consumer/NegativeChecks` / `TestConsumers/Swift6Consumer/Package.swift` を追加する (`swift format --recursive` は隠しディレクトリを走査しないが、`swift format` に除外オプションは無いため対象を明示的に列挙し、`prek.toml` の glob とそろえる)。
- `prek.toml` の swift-format と swiftlint のフックの `files.glob` に `TestConsumers/Swift6Consumer/**/*.swift` を追加する (swiftlint フックは `pass_filenames = false` のため、glob に含めないと consumer package だけを変更したコミットで起動しない)。
- `.swiftlint.yml` の `included` に `TestConsumers/Swift6Consumer/Sources` と `TestConsumers/Swift6Consumer/NegativeChecks` を追加し、`excluded` に `TestConsumers/Swift6Consumer/.build` を残す (`included` の解釈は SwiftPM plugin の実装に依存するため、`.build` を走査しないことを `excluded` でも担保する)。
- `.gitignore` に `TestConsumers/Swift6Consumer/.swiftpm/` を追加する。
- `CODEBASE.md` を develop に追加する。リネーム後のパス (`TestConsumers/Swift6Consumer/`)、baseline の file 名を導出する `XCODE_SDK` と baseline を生成する Xcode を固定する `API_XCODE`、`api-check` の判定 (`API_VALIDATE` の `children` 数の検査を含む)、`consumer-test.yml` の `swift6-consumer` job を指す内容とする。コミットは `shiguredo-git` の AGENTS.md / CODEBASE.md の特別ルールに従い develop へ直接行う。
- consumer package のコメントは日本語、consumer package が出力するログは英語とする。consumer package のソースと README と `CODEBASE.md` に issue 番号を書かず、未対応である理由を書く。

## スコープ外

- `Package.swift` の tools version と言語モードの変更は `0108` で扱う。
- E2E テストから `@preconcurrency import Sora` を撤去する作業は `0118` で扱う。
- Thread Sanitizer による runtime stress test は `0119` で扱う。
- 公開 API の**追加**を検出する gate (commit 済み baseline が現在の module と一致していることの検証) は `0168` で扱う。本 issue では「追加時は同じ変更で baseline を再生成する」規約と、その旨の README / `CODEBASE.md` の記述までとする。
- `Sora` target 自身の warning を 0 にする作業と、`Sora` target に対する warnings-as-errors gate は本 issue に含めない (`0108` / `0113` / `0138` が扱う。`0138` は iOS SDK 由来の deprecation を対象外とする)。
- `0027` が追加する legacy `VideoRenderer` 実装、新 protocol、新登録 API、`VideoView` の 4 ケースの scenario は `0027` が追加する。
- 実 Sora への接続試験は既存 E2E workflow の責務とする。
- `README.md` のシステム条件 (Xcode 26.2) は最低要件として据え置く (CI が 26.6 でも検証することは記載しない)。
- `skills/sora-ios-sdk/SKILL.md` の「Swift 6 と並行性」「現状の制約」は、本 issue が公開 API と manifest を変更しないため更新しない。

## 変更対象

- `TestConsumers/Swift6Consumer/` (新規): consumer package の SwiftPM package、3 target の scenario、`NegativeChecks/`、`ApiBaseline/`、README
- `.github/workflows/consumer-test.yml` (新規): `swift6-consumer` job と matrix、各種検査 step (format / lint、compiler settings、deprecation、負例、test-only import)、API baseline の step
- `.github/workflows/build.yml`: `paths-ignore` に `TestConsumers/**` を追加する (`swift6-consumer` job は置かない)
- `.github/workflows/e2e-test.yml` (`ci.yml` からリネーム): `name` の変更と `paths-ignore` に `TestConsumers/**` を追加する
- `Makefile`: 変数と consumer package 用 target の追加、`.PHONY` の更新、`fmt` / `fmt-lint` の対象追加、`build` target の `-sdk` を `iphoneos26.2` に修正する (Xcode 26.2 への更新時に追随していなかった指定を、README のシステム条件と `build.yml` に合わせる)
- `prek.toml`: swift-format / swiftlint フックの `files.glob`、`check-json` の対象追加、`check-added-large-files` と `end-of-file-fixer` の除外設定
- `.swiftlint.yml`: `included` / `excluded` の追加
- `.gitignore`: `TestConsumers/Swift6Consumer/.swiftpm/` の追加
- `CODEBASE.md` (新規): consumer package の運用 (Makefile の target、公開 API baseline の生成・比較・更新手順、Xcode 更新時の手順)
- `CHANGES.md`: `## develop` の `### misc` に `[ADD]` を、既存の `[FIX]` エントリより前 (種別順 CHANGE → ADD → UPDATE → FIX) に担当者行付きで追記する

## テスト方針

モックやスタブは使用しない。本 issue は compile と公開 API 差分だけを検証し、実行経路のテストは持たない。

- `NegativeChecks/` の負例も実 API を対象にし、モック・スタブで代用しない。
- 実 DataChannel と実 Sora を必要とする検証は本 issue に含めない (既存 E2E workflow の責務とする)。
- 各 scenario には、検査する公開 concurrency 契約と期待する診断を日本語コメントで書く。

## 完了条件

- `TestConsumers/Swift6Consumer/` が `import Sora` と `import WebRTC` で root package の product に依存し、`ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 scheme が Release で build できること (SDK source を consumer package target へ直接含めていないこと)
- consumer package の各 target が warnings-as-errors (consumer package target の設定) で build でき、`ConsumerLegacy` は deprecation を error にせず build できること (`Sora` target の warning は gate に含めない)
- `make consumer-build SCHEME=<Target>` のログで、選択された Xcode が matrix の値と一致し、`ConsumerUI` に `-default-isolation MainActor` が渡っていること (SwiftPM は `SWIFT_DEFAULT_ACTOR_ISOLATION` を設定しないため、build ログまたは DerivedData の `Logs/Build/*.xcactivitylog` の swift-frontend 引数で確認する。どちらで確認したかを PR 本文に記録する)
- `ConsumerUI` の scenario が `@MainActor` を書かずに compile できること
- `ConsumerLegacy` の導入時検証で `is deprecated` を含む warning が出ること (build ログの grep。xcodebuild は diagnostic group 名を出力しないため `[#DeprecatedDeclaration]` では判定しない)
- `NegativeChecks/` の file が `make consumer-check-negative` で、`EXPECT-DIAGNOSTIC` の group 名を伴って compile に失敗すること
- consumer package が `@testable` と `@preconcurrency` を使用していないこと (`git grep -n -E '@testable|@preconcurrency' -- ':(glob)TestConsumers/Swift6Consumer/**/*.swift'` が 0 件であること)
- `0027` / `0109` / `0110` / `0114` / `0116` / `0120` / `0124` / `0125` / `0152` が scenario を追加できる構造であること (consumer package の README に追加手順、`NegativeChecks` の接頭辞規約と `EXPECT-DIAGNOSTIC` の書き方、どの作業がどの file を追加・削除するかの表がある)
- Xcode 26.2 と 26.6 の `swift6-consumer` job が存在し、26.2 leg で API baseline の比較以外の検査 (compile、負例、compiler settings、deprecation、test-only import) が、26.6 leg でそれらと API baseline の検証が成功すること
- consumer package に secret が渡されていないこと
- GitHub 公式以外の action、または利用実績のない外部 action を新規追加していないこと
- 公開 API baseline が commit され、公開 API の削除・変更と `Sendable` 準拠の削除が baseline の差分として検出されること
- `make api-check` が通常時 (シンボル削除なし) に exit 0 で成功し、公開シンボルを一時的に削除すると exit 1 で失敗してログに `API breakage` が出ること (その CI run の URL が PR 本文にあり、確認後に `git revert` されていること)
- `make api-check` が `-module Sora` と `-baseline-path $(API_BASELINE)` を使い (`-input-paths` は使わない)、`-I` / `-F` に `$(PRODUCTS)` を渡し、commit 済み baseline の `ABIRoot.name` と `children` 数とサイズを検証し、壊れた baseline を渡すと検証の行で exit 1 になること
- `make api-check` が commit 済み baseline を書き換えず、CI が `api-baseline` を呼んでいないこと
- baseline の更新手順 (追加を含む) が `CODEBASE.md` にあり、API を追加する issue が同一変更で baseline を再生成することになっていること (手順が指すパスと job 名がリネーム後に一致していること)
- `api-baseline` が `xcodebuild -version` と SDK の一致を確認し、26.6 と `iphoneos26.5` 以外の環境では commit 済み baseline を上書きしないこと
- consumer package の Swift ソースが `make fmt-lint` と `make lint` の対象で違反 0 であり、`TestConsumers/Swift6Consumer/.build` が対象に含まれず、consumer package だけを変更した場合でも `consumer-test.yml` が `make fmt-lint` と `make lint` を実行すること
- `TestConsumers/Swift6Consumer/Sources` の `.swift` のみを変更したコミットで swift-format と SwiftLint のフックが起動すること
- `TestConsumers/Swift6Consumer/ApiBaseline/` の 2 ファイルが `check-added-large-files` と `end-of-file-fixer` の対象外であり、`check-useless-excludes` が通ること
- `CHANGES.md` の `## develop` の `### misc` の `[FIX]` より前に `[ADD]` が追記されていること
- `Makefile` の `build` target が `-sdk iphoneos26.2` を指定し、`iphoneos26.1` の参照がリポジトリに残っていないこと
- 追加した `swift6-consumer` job と既存の `build` job が成功すること

## 解決方法

`TestConsumers/Swift6Consumer/` に、外部の iOS アプリと同じ形 (通常の SwiftPM package 依存) で `Sora` を import する consumer package を追加した。`ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 target を Swift 6 language mode と warnings-as-errors で build し、compile 失敗を期待する負例 2 件 (`Sendable` でない `MediaChannel` の capture と、隔離された conformance の非隔離文脈での使用) を `make consumer-check-negative` で diagnostic group 名まで検査する。

- `.github/workflows/consumer-test.yml` を新設し、Xcode 26.2 (`iphoneos26.2`) と 26.6 (`iphoneos26.5`) の 2 leg で compile、負例、compiler settings、deprecation、test-only import を検査する。26.6 leg では公開 API baseline も比較し、整形と lint も同じ job で実行する
- 公開 API baseline は Xcode 26.6 と `iphoneos26.5` で `swift-api-digester` の dump を生成し、`TestConsumers/Swift6Consumer/ApiBaseline/` に commit した。`make api-check` が `-diagnose-sdk` で削除・変更・準拠の削除を検出する
- `.github/workflows/ci.yml` を `.github/workflows/e2e-test.yml` にリネームし、`build.yml` と `e2e-test.yml` の `paths-ignore` に `TestConsumers/**` を追加した
- `Makefile` に consumer package 用の 4 target を追加し、`build` target の `-sdk iphoneos26.1` を `iphoneos26.2` に修正した
- `prek.toml` / `.swiftlint.yml` / `.gitignore` に consumer package の対象と除外を追加し、`CODEBASE.md` にリポジトリ側の運用 (Makefile の target、baseline の生成・比較・更新手順、Xcode 更新時の手順) を書いた
- 派生した作業として `0167` (対応する最低 Xcode を 26.6 に上げる) と `0168` (baseline が最新であることを検証する gate) を起票した

`make api-check` は通常時に exit 0 で成功し、baseline に無いシンボルを加えた JSON に対しては `API breakage: … has been removed` を報告することを実測で確認した。consumer package の 3 scheme は Release で build でき、負例 2 件は期待した diagnostic group で compile に失敗する。PR #393 として develop にマージされた。
