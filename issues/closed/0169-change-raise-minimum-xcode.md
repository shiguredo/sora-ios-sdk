# 対応する最低 Xcode を 26.6 に上げる

- Created: 2026-09-24
- Completed: 2026-09-24
- Priority: Medium
- Branch: feature/change-raise-minimum-xcode
- Polished: 2026-09-24

## 目的

対応する最低 Xcode を 26.6 に上げ、リポジトリ内で Xcode と SDK の版を明示している箇所を 26.6 / `iphoneos26.5` にそろえる。後方互換のない変更であり、Xcode 26.2 と iOS 26.2 SDK での検証を終了する。

E2E の self-hosted ランナーと公開 API baseline が Xcode 26.6 / `iphoneos26.5` を前提にしており (`CODEBASE.md`)、これにそろえる。

## 現状

- Xcode 26.2 を明示しているのは `README.md` のシステム条件、`skills/sora-ios-sdk/SKILL.md` の動作条件、`build.yml` の `env.XCODE` / `env.XCODE_SDK`、`deploy-apidoc.yml` の `env.XCODE`、`Makefile` の `build` target の `-sdk`、`consumer-test.yml` の matrix の 26.2 leg
- `consumer-test.yml` の `swift6-consumer` matrix は 26.2 (`api_check: false`) と 26.6 (`api_check: true`) の 2 leg で、26.6 leg だけが `Check Public API Baseline` を実行する。この step は `run` が `make api-check-fresh` で、`if: matrix.api_check` が残っている
- `e2e-test.yml` の `XCODE` は未使用で、Xcode を選び直さない。self-hosted ランナーの既定 Xcode (現状 26.6) と `-destination` の `OS=26.5` に依存する。`XCODE_SDK` は使用されている
- consumer 系の `Makefile` 変数 (`XCODE_SDK ?= iphoneos26.5` / `API_XCODE ?= 26.6`) と公開 API baseline (`iphoneos26.5.info.txt` は Xcode 26.6 / SDK 26.5) は既に新値で、baseline の再生成は不要
- `CHANGES.md` の `## develop` の `### misc` に `[FIX] Makefile の build target の SDK 指定を iphoneos26.2 に修正する` がある
- 関連 issue: `0108` は `swift-tools-version` の上限を README のシステム条件から選ぶ設計で Xcode 26.2 の記述が 3 箇所ある。`0072` は `Makefile` の `build` が `iphoneos26.2` であることを前提として書いている

## 設計方針

- `README.md` と `skills/sora-ios-sdk/SKILL.md` の Xcode 条件を 26.6 に、`build.yml` と `deploy-apidoc.yml` の `env.XCODE` を `/Applications/Xcode_26.6.app` に、`build.yml` の `env.XCODE_SDK` を `iphoneos26.5` に更新する
- `consumer-test.yml` の matrix から 26.2 leg を削除して 26.6 の 1 要素にする。`matrix.xcode` / `matrix.sdk` は step が参照しているため残す。1 leg で不要になる `api_check` フラグ、`Check Public API Baseline` step の `if`、`fail-fast: false` を削除し、leg 数を前提とした 2 つのコメントを次のように書き換える
  - concurrency のコメント (`2 leg の build` と書いている行): `# 同じ ref への連続 push では古い実行を打ち切る (WebRTC artifact の取得と consumer package の build が走るため)`
  - job の直前のコメント (`最低要件の Xcode と公開 API baseline を生成した Xcode の両方で検証する` と書いている行): `# 外部の consumer が Sora を import するのと同じ形の package を、最低要件であり` / `# 公開 API baseline を生成した Xcode 26.6 で検証する`
  - step 名と `run` (`make api-check-fresh XCODE=... XCODE_SDK=...`) は変えない
- `Makefile` の `build` target の `-sdk` を `$(XCODE_SDK)` に変更し、Makefile 内の SDK の指定を `XCODE_SDK` 1 箇所にする (既定値 `iphoneos26.5`)。`# build` の直前に `# SDK は XCODE_SDK (既定 iphoneos26.5)。Xcode を指定する場合は DEVELOPER_DIR を渡す (build は XCODE を参照しない)` を足し、`XCODE` / `XCODE_SDK` の定義の直前のコメント (`# Xcode と SDK は CI の matrix から XCODE=... XCODE_SDK=... として渡す`) を `# XCODE_SDK は build と consumer 系が使い、XCODE は consumer 系の DEVELOPER_DIR にだけ使う` に置き換える
- GitHub ホストの runner を使う workflow (`build.yml` / `consumer-test.yml` / `deploy-apidoc.yml`) の Xcode は版を明示し、利用可能な最新版を動的に選ばない (`e2e-test.yml` は self-hosted ランナーの既定 Xcode に依存するため対象外)
- 26.2 leg の削除で失われるのは旧最低要件 26.2 での検証である。新しい最低要件 26.6 の 1 leg が最低要件での compile 検証を兼ねる
- `CODEBASE.md` の「Xcode を更新するとき」の手順に、新しい手順 1 として「`README.md` / `skills/sora-ios-sdk/SKILL.md` / `TestConsumers/Swift6Consumer/README.md` の Xcode と SDK の記述、`build.yml` の `env.XCODE` / `env.XCODE_SDK`、`deploy-apidoc.yml` の `env.XCODE`、`e2e-test.yml` の `env.XCODE_SDK` を更新する」を追加し、以降を繰り下げる (`consumer-test.yml` は既存の matrix の手順、`Makefile` の `XCODE_SDK` は既存の手順で足りる。`e2e-test.yml` の未使用の `XCODE` は含めない。追加後は 1. 版の記述、2. `consumer-test.yml` の matrix、3. `Makefile` の `XCODE_SDK` / `API_XCODE`、4. baseline の再生成 (条件付き)、5. 差分のレビュー、6. SDK の版が変わる場合の baseline の file 名、の 6 手順になる)。baseline の再生成の手順は「`XCODE_SDK` / `API_XCODE` を変えた場合、または `*.info.txt` の `xcodebuild` と `sdk` が実行環境と一致しない場合は `make api-baseline` で再生成する。`XCODE_SDK` / `API_XCODE` が同じで `*.info.txt` の `xcodebuild` と `sdk` が実行環境と一致する場合だけ再生成しない。再生成の有無にかかわらず `make api-check-fresh` が成功することを確認する」に直す。`CI の iphoneos26.5 の leg` は `swift6-consumer` job に合わせる
- `CHANGES.md` の `## develop` の main セクション先頭 (最初の `[UPDATE]` より前) に次を追記する。新しいエントリは main に置き、`### misc` へは移さない
  - `- [CHANGE] 対応する最低 Xcode を 26.6 に上げる`
  - `  - Xcode 26.6 未満はサポート対象外になる`
  - `  - @t-miya`
- 同じ `## develop` の `### misc` の `[FIX]` は、最終差分に合わせて題名を `[FIX] Makefile の build target の SDK 指定を iphoneos26.5 に修正する`、理由を `既存の build target が SDK を直接指定しており、Xcode の更新に追随できていなかった (SDK は XCODE_SDK から導出する)` に直す (変更履歴は派生元ブランチとの最終差分のみを書くため。同じ `## develop` 内の未リリースの記述を最終状態に合わせる作業であり、別目的ではない)
- `issues/0108-*.md` は、0108 の設計判断には踏み込まず、26.2 leg の削除に伴う参照の更新だけを行う。上限制約の根拠の Xcode 26.2 を 26.6 に直す。検証方針と完了条件の「Xcode 26.2 と最新 26.x」は、26.2 leg が消えて 26.6 の 1 leg になるため `Xcode 26.6 の 1 leg` に置き換える (swift-tools-version の上限の再判断は 0108 側で行う)
- `issues/0072-*.md` の `Makefile` の `build` は `iphoneos26.2`、consumer 検証は `iphoneos26.5` と書いている箇所を次の完成形に置き換える: `SDK は iOS 26.x SDK でビルドされる。`Makefile` の `build` は `$(XCODE_SDK)` (既定 `iphoneos26.5`)、consumer 検証も `iphoneos26.5` (`CHANGES.md` の `## develop` に記載)。`

## スコープ外

- `swift-tools-version` の更新と Swift 6 language mode の適用は `0108` で扱う
- サンプル集とクイックスタート (別リポジトリ) の Xcode 条件と Xcode プロジェクト設定の JSON 形式への移行は `0160` で扱う
- 公式ドキュメント (`sora-ios-sdk-doc`) の `source/setup.rst` の Xcode 条件の更新は本 issue では行わない。README 更新後に別途追従し、リリースチェックで README と一致させる
- self-hosted ランナーの Xcode の版と `e2e-test.yml` の未使用の `XCODE`、`-destination` の `OS=` の更新。ランナーの既定 Xcode が 26.6 で iOS 26.5 の Simulator runtime が使える前提とする
- 26.6 より新しい Xcode での継続検証は本 issue では行わない (Xcode が上がった時点で `CODEBASE.md` の手順に従う)

## 変更対象

- `README.md` / `skills/sora-ios-sdk/SKILL.md`: Xcode の条件
- `.github/workflows/build.yml`: `env.XCODE` / `env.XCODE_SDK`
- `.github/workflows/deploy-apidoc.yml`: `env.XCODE`
- `.github/workflows/consumer-test.yml`: matrix、`api_check`、`if`、`fail-fast`、コメント
- `Makefile`: `build` target の `-sdk` とコメント
- `CODEBASE.md`: 「Xcode を更新するとき」の手順と leg の記述
- `CHANGES.md`: main の `[CHANGE]` と `### misc` の `[FIX]`
- `issues/0108-update-swiftpm-language-mode.md` / `issues/0072-add-sample-buffer-video-renderer.md`: Xcode / SDK の記述

## テスト方針

モックやスタブは使用しない。実際の Xcode 26.6 と `iphoneos26.5` で確認する。

- `xcode-select -p` が Xcode 26.6 を指す状態で `make build` が成功する (別の Xcode を指定する場合は `DEVELOPER_DIR=<Xcode 26.6 の path>/Contents/Developer` を渡す)
- `XCODE=<実行環境の Xcode 26.6 の path> XCODE_SDK=iphoneos26.5` を付けて (CI は `/Applications/Xcode_26.6.app`、ローカルは `/Applications/Xcode.app` など) `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`、`make consumer-check-negative`、`make api-check-fresh` が成功する
- `make fmt-lint` と `make lint` が違反 0 である
- feature branch の CI で `Build` / `Consumer Test` / `E2E Test` が成功する。`Consumer Test` は 1 leg で、compile (3 scheme)、compiler settings、負例、deprecation、test-only import、fmt-lint、lint、`make api-check-fresh` が skip されずに実行され (job サマリーで `Check Public API Baseline` が success になることで確認する)、`E2E Test` の `Show Xcode Version` が Xcode 26.6 を示す
- develop へのマージ後に `deploy-apidoc` を `workflow_dispatch` (ref: develop) で実行し、jazzy が成功する (`.jazzy.yaml` は版を固定しないため `env.XCODE` の変更だけで追随する)
- `git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空である (公開 API の差分が 0)
- `grep -rn "26\.2\|iphoneos26\.2" README.md skills/sora-ios-sdk/SKILL.md Makefile .github/workflows/` が 0 件である
- `sed -n '/^## develop/,/^## 2026\.3\.0/p' CHANGES.md | grep "26\.2"` が 0 件である (リリース済みの変更履歴は範囲外)
- `grep -n "Xcode 26\.2\|最新 26\.x" issues/0108-update-swiftpm-language-mode.md` が 0 件である
- `grep -n "iphoneos26\.2" issues/0072-add-sample-buffer-video-renderer.md` が 0 件である

## 完了条件

- `README.md` のシステム条件と `skills/sora-ios-sdk/SKILL.md` の動作条件が Xcode 26.6 で一致していること
- `build.yml` の `env.XCODE` / `env.XCODE_SDK`、`deploy-apidoc.yml` の `env.XCODE`、`Makefile` の `build` target の `-sdk` (`$(XCODE_SDK)`、既定 `iphoneos26.5`) が 26.6 / `iphoneos26.5` にそろっていること
- `consumer-test.yml` が 1 leg で、テスト方針に挙げた検査がすべて成功すること
- `Check Public API Baseline` step の `run` が `make api-check-fresh` のままで、step の `if: matrix.api_check` と matrix の `api_check` key の両方が削除されていること
- feature branch の CI で `Build` / `Consumer Test` / `E2E Test` が成功し、`E2E Test` のログで self-hosted ランナーの Xcode が 26.6 であること
- 26.2 を前提とした記述が `README.md` / `skills/sora-ios-sdk/SKILL.md` / `Makefile` / `.github/workflows/` と `CHANGES.md` の `## develop` に残っていないこと (リリース済みの変更履歴と `issues/` は除く)
- `issues/0108-*.md` / `issues/0072-*.md` の記述が設計方針のとおり更新されていること
- `CHANGES.md` の `## develop` の main 先頭に `[CHANGE]` が担当者行付きで追記され、`### misc` の `[FIX]` が最終差分に合っていること
- 公開 API baseline の差分が 0 であること
- `CODEBASE.md` の「Xcode を更新するとき」の手順が、`XCODE_SDK` / `API_XCODE` が同じで `*.info.txt` の `xcodebuild` と `sdk` が実行環境と一致する場合だけ baseline を再生成しないことを示していること

## 検証記録

- 2026-09-24: Xcode 26.6 (Build version 17F113) / `iphoneos26.5` の環境で `make build`、`make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`、`make consumer-check-negative`、`make api-check-fresh`、`make fmt-lint`、`make lint` がすべて成功した。`make api-check-fresh` は `The committed API baseline matches the current Sora module.` を出力した
- 2026-09-24: `git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空で、`make lint` (`swiftlint --fix`) の前後で `git status --short` が空のままだった (公開 API baseline の差分が 0)
- 2026-09-24: 26.2 を前提とした記述の残存検査が 0 件だった (`README.md` / `skills/sora-ios-sdk/SKILL.md` / `Makefile` / `.github/workflows/`、`CHANGES.md` の `## develop`、`issues/0108-*` / `issues/0072-*`)。`consumer-test.yml` に `api_check` と `fail-fast` は残っていない
- 2026-09-24: PR #396 (`feature/change-raise-minimum-xcode`、804f5681) の CI が `Build` / `Consumer Test` / `E2E Test` の 3 つとも success だった。`Consumer Test` は `swift6-consumer (/Applications/Xcode_26.6.app, iphoneos26.5)` の 1 leg で、`Check Public API Baseline` を含むすべての step が skip されずに success だった。`E2E Test` の `Show Xcode Version` は `Xcode 26.6` / `Build version 17F113` だった
- 2026-09-24: マージ後の `deploy-apidoc` の `workflow_dispatch` (ref: develop) は実行していない。今回の変更で jazzy の入力は変わらず、実行すると develop 時点の API ドキュメントが Pages へ公開されるため

## 解決方法

対応する最低 Xcode を 26.6 に上げ、リポジトリ内で Xcode と SDK の版を明示している箇所を Xcode 26.6 / `iphoneos26.5` にそろえた。

- `README.md` のシステム条件を `Xcode 26.6 以降`、`skills/sora-ios-sdk/SKILL.md` の動作条件を `Xcode 26.6` に更新した
- `.github/workflows/build.yml` の `env.XCODE` を `/Applications/Xcode_26.6.app`、`env.XCODE_SDK` を `iphoneos26.5` に、`.github/workflows/deploy-apidoc.yml` の `env.XCODE` を `/Applications/Xcode_26.6.app` に更新した
- `.github/workflows/consumer-test.yml` の `swift6-consumer` の matrix から 26.2 leg を削除して 26.6 の 1 leg にし、1 leg で不要になった `api_check` key、`Check Public API Baseline` step の `if: matrix.api_check`、`fail-fast: false` を削除した。step 名と `run` (`make api-check-fresh XCODE=... XCODE_SDK=...`) は変えていない。leg 数を前提としていた concurrency と job のコメントも 1 leg の実態に合わせた
- `Makefile` の `build` target の `-sdk` を `$(XCODE_SDK)` (既定 `iphoneos26.5`) に変更し、SDK の指定を `XCODE_SDK` 1 箇所に集約した。`build` が `XCODE` を参照しないことと `XCODE_SDK` の用途をコメントに書いた
- `CODEBASE.md` の「Xcode を更新するとき」に版の記述の更新を手順 1 として足して 6 手順にし、baseline の再生成が `XCODE_SDK` / `API_XCODE` と `*.info.txt` の `xcodebuild` / `sdk` の一致に依存することを明記した
- `CHANGES.md` の `## develop` の main 先頭に `[CHANGE] システム要件の Xcode バージョンを 26.6+ に更新する` を担当者行付きで追記した。`### misc` には Build workflow の `[UPDATE]` を追記し、SDK を `XCODE_SDK` から導出する形になった `[FIX] Makefile の build target の SDK 指定を iphoneos26.2 に修正する` は最終差分に含めなかった
- `issues/0108-update-swiftpm-language-mode.md` の上限制約の根拠と検証方針・完了条件、`issues/0072-add-sample-buffer-video-renderer.md` の `Makefile` の `build` の SDK の記述を更新した

公開 API baseline は Xcode 26.6 / `iphoneos26.5` で生成済みのものをそのまま使い、再生成していない。commit 済み baseline が現在の `Sora` module と一致することは `## 検証記録` のとおり確認済みである。
