# concurrency runtime stress CI を追加する

- Created: 2026-08-27
- Completed: 2026-09-30
- Branch: feature/add-concurrency-runtime-ci
- Polished: 2026-09-30

## 目的

compile-time の Sendable / actor isolation 検査と `SoraTests` の warnings-as-errors (`0171`) では検出できない実行時のデータ競合を継続的に検出する CI job を追加する。Thread Sanitizer (TSan) を有効にした `SoraTests` の実行を通常の test job と分離し、Swift 6 対応を「コンパイルできること」だけで完了扱いにしない。

## 現状

- `.github/workflows/build.yml` は SDK の Release build、`.github/workflows/consumer-test.yml` は consumer package の検証、`.github/workflows/e2e-test.yml` は実 Sora を使う E2E test を実行するが、TSan を有効にした job はどの workflow にも無く、`Makefile` にも TSan の target は無い (2026-09-30 確認)。TSan は `0151` / `0129` / `0177` / `0181` が手動実行で用いているだけである。
- TSan の手動実行手順は確立している。`-enableThreadSanitizer YES` を付けた `xcodebuild build-for-testing` が作った `SoraTests.xctest` を `xcrun simctl spawn` で起動し、bundle 内の `libclang_rt.tsan_iossim_dynamic.dylib` を `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` で先読みさせる。`xcodebuild test-without-building` では TSan runtime が load されず race を検出しないため、build からやり直すこの経路が必要である。
- develop の `SoraTests` 全体は TSan で完走し、race は検出されない。2026-09-30 の実測は **441 件 / skip 31 / 失敗 0 / `WARNING: ThreadSanitizer` 0 行** (exit 0、約 26 秒) である。`0129` は 433 件、`0177` は 435 件、`0181` は 441 件で同じく検出 0 を記録している。
- `SoraTests` 側の前提は整っている。`0118` (完了 2026-09-25) が concurrency 診断の抑止を除去し、`0121` (完了 2026-09-25) が `DummyAudioDevice` の race を修正し、`0151` (完了 2026-09-28) が `PeerChannel.onConnect` の race を修正し、`0171` (完了 2026-09-30) が `SoraTests` を warnings-as-errors にした。`0129` (完了 2026-09-29) は `PeerChannel.Lock` を `ConnectionStateOwner` へ統合し、`0177` (完了 2026-09-29) は `nativeChannel` / `streams` / `offerEncodings` を lock 付き storage へ移した。`0102` が記録した「`0151` の race でサニタイザがテストプロセスを終了させスイートが完走しない」という阻害要因は解消している。
- `0092`、`0100`、`0101`、`0111` は TSan の補助的な有効化を求めており、`0102`〜`0107`、`0165`、`0173`、`0177`、`0181` (いずれも closed) と open の `0112`、`0154` は実行時検証を本 issue の CI 基盤へ委ねている。`0121` と `0129` と `0178` は本 issue の実行環境またはスコープの整理を参照している。しかし共通の実行方法、対象 scenario、反復回数、artifact 保存、失敗時の切り分け方針は定められていない。
- 実 Sora 接続を含む TSan 実行はまだ無い。手動実行の記録 (`0129` / `0177` / `0181`) はいずれも `SORA_SIGNALING_URL` 未設定で E2E test が skip された状態である。

## 前提となる issue

次はすべて完了しており、着手を妨げるものは無い。`0154` だけが open だが、本 issue は `0154` の対象を stress に含めないため着手を妨げない。

- `0151` (完了 2026-09-28): `PeerChannel.onConnect` の race 修正。本 issue の完了条件を満たす前提となる。
- `0121` (完了 2026-09-25): `DummyAudioDevice` の race 修正。TSan 実行が test helper 由来のノイズを出さない前提。
- `0118` (完了 2026-09-25): E2E test の concurrency 診断抑止の除去。追加する test は `E2ETestBase` の async な `setUp` / `tearDown` 契約に従う。
- `0129` (完了 2026-09-29): `PeerChannel.Lock` の `ConnectionStateOwner` 統合。TSan job は統合後の構造で race 検出 0 を維持する。
- `0171` (完了 2026-09-30): `SoraTests` の warnings-as-errors。追加する test は warning を出してはならない (`0138` が対象外とする非推奨 API の警告だけが許容される)。
- `0154` (open): handler bag の読み書き排他。`0154` が扱う handler の読み書きを本 issue の stress で並行させると、未完了の間は TSan が race を報告して job が赤くなる。本 issue は handler bag を stress の対象に含めない (「スコープ外」)。`0154` は `0121` / `0177` / `0181` と同じ手動 TSan で検証できるため、本 issue を待たない。

## 設計方針

### job の配置

- `.github/workflows/e2e-test.yml` に `tsan` job を追加する (既存 `e2e` job とは別 job)。実 Sora の secret と Simulator の boot を既に持つ唯一の workflow であり、job の失敗を通常の test job と識別できる。
- `runs-on` と `env` は既存 `e2e` job と揃える (`[self-hosted, macOS, ARM64, Apple-M1]`、`XCODE_SDK=iphoneos26.5`、iPhone 17 Pro / OS 26.5)。同じ self-hosted runner を `e2e` job と共有するため、実行時間は CI 全体に加算される。TSan は通常 test より遅いため余裕を見て `timeout-minutes: 20` にする (実測は build と全件実行を合わせて約 1 分、既存 `e2e` job は 45)。
- `slack_notify` の `needs` に `tsan` を加え、`status` を `contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')` の形にする (`consumer-test.yml` の `swift6-consumer` と同じ)。現状の `status: ${{ needs.e2e.result }}` のままでは TSan の失敗が通知されない。
- `on.push.paths-ignore` は変更しない。

### TSan の実行手順

`e2e` job の `test-without-building` 経路は使えない。CI でも手動実測と同じ経路を使う。

```
# 1. Simulator を boot する (e2e job の Setup iOS Simulator と同じ)

# 2. TSan runtime を bundle へ複製させるため build から行う。incremental build で
#    複製が省略されないよう、先に build を消す (e2e job と同じ)
rm -rf build
xcodebuild build-for-testing -scheme Sora-Package -sdk $XCODE_SDK -derivedDataPath build \
  -enableThreadSanitizer YES \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE= SWIFT_VERSION=6

# 3. destination と同じ Simulator の UDID を取る (booted が複数ある場合があるため、
#    名前と OS で特定する)
UDID=$(xcrun simctl list devices booted --json \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(dev['udid'] for rt,devs in d.items() if 'iOS-26-5' in rt for dev in devs if dev['name']=='iPhone 17 Pro' and dev.get('state')=='Booted'))")

# 4. 全件を実行する。simctl spawn は親の環境変数を渡さないため、TSan の DYLD_* と
#    E2E の環境変数はどちらも SIMCTL_CHILD_ 接頭辞で渡す
BUNDLE="$PWD/build/Build/Products/Debug-iphonesimulator/SoraTests.xctest"
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PWD/build/Build/Products/Debug-iphonesimulator" \
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$BUNDLE/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib" \
SIMCTL_CHILD_TSAN_OPTIONS=verbosity=1 \
SIMCTL_CHILD_SORA_SIGNALING_URL="$SORA_SIGNALING_URL" \
SIMCTL_CHILD_TEST_SECRET_KEY="$TEST_SECRET_KEY" \
SIMCTL_CHILD_TEST_CHANNEL_ID_PREFIX="$TEST_CHANNEL_ID_PREFIX" \
SIMCTL_CHILD_TEST_CHANNEL_ID_SUFFIX="$TEST_CHANNEL_ID_SUFFIX" \
SIMCTL_CHILD_TEST_API_URL="$TEST_API_URL" \
  xcrun simctl spawn "$UDID" \
    "$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest" \
    "$BUNDLE" 2>&1 | tee build/tsan.log
```

- `SIMCTL_CHILD_` 接頭辞は TSan の `DYLD_*` だけでなく E2E の環境変数にも必要である。2026-09-30 の実測で `SIMCTL_CHILD_SORA_SIGNALING_URL` と `SIMCTL_CHILD_TEST_SECRET_KEY` を渡すと `RecvonlyE2ETests.testConnectRecvonly` が skip ではなく接続を試行して失敗した。`.xctestrun` への `plutil` 注入は `test-without-building` 経路のものであり、この経路では効かない。
- 実行対象は `SoraTests` 全体とする。対象 suite を列挙すると、後から追加した test が無言で TSan の外へ落ちる。
- job の step では反復しない (1 回の実行)。race を確率的に踏むための反復は、追加する stress test の内部で行う。test 実行の実測は約 26 秒 (build を含まない、skip 31 の状態) であり、実 Sora 接続を含む CI でも `timeout-minutes: 20` に収まる。
- `xcrun simctl spawn` は `.xcresult` を作らないため、判定と artifact にはこの step の標準出力 (`build/tsan.log`) を使う。

### 判定 (失敗条件)

- race の判定は `WARNING: ThreadSanitizer` の grep を主とし、exit code だけに依存しない (TSan が report を出しても処理を続けて 0 で終わる可能性を排除できないため)。exit code も併せて失敗条件にする (`set -o pipefail` を設定し、race 検出時は TSan が `BUS` でプロセスを終了し非 0 になる。`0151` の negative control で実測)。pipeline の exit code は判定の `grep` より先に評価して保持する (`grep` は「0 行」のとき exit 1 になるため、そのままでは job の成否に使えない)。
- `WARNING: ThreadSanitizer` が log にあれば失敗させる。`verbosity=1` では `ThreadSanitizer: parsing` と `***** Running under ThreadSanitizer *****` の行も出るため、race の判定に `ThreadSanitizer` の単純な行数を使ってはならない (2026-09-30 実測)。
- interceptor が有効でなければ「検出 0」は空振りである。`***** Running under ThreadSanitizer` が log に無ければ失敗させる (`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` の path 誤りや TSan 無効 build を検出する)。
- 実行した test 数が 0 件でないことを確認する (`simctl spawn` は bundle の path を誤っても 0 件で終了し得る)。
- retry で race を隠さない。`-retry-tests-on-failure` / `-test-iterations` / `-run-tests-until-failure` を使わず、失敗した iteration と scenario は test のログへ出して job を赤くする。

### artifact

- `actions/upload-artifact` で、失敗時に TSan の report だけを保存する (`if: failure()`)。workflow の action は `actions/*` だけを使い、既存の `actions/checkout` と同じく commit SHA で pin して tag をコメントに残す。
- `.xcresult` と crash diagnostics はこの経路では生成されないため対象外とする。`e2e` job の `Show E2E Crash Diagnostics` が「接続情報や環境変数を含み得る診断全体は公開しない」としている方針に合わせ、artifact は log 全体ではなく `WARNING: ThreadSanitizer` の report ブロックと XCTest の失敗行だけを抽出した `build/tsan-report.txt` にする (接続情報を含む通常のログ行を持ち出さない)。抽出の実装は `e2e` job の diagnostics 抽出と同じく `grep` と `awk` で行う (`0156` の secret masking は未完了であり、`simctl spawn` の log に接続情報が出得る)。

### 追加する stress test

- TSan は race を確率的にしか検出しないため、対象を反復する。通常 test でも同じ test を実行し、論理的な不変条件 (exactly-once、state の整合) は TSan 無効時にも検証する。TSan を無効にしなければ通らない test を追加しない (追加する test は通常 test と TSan 有効時の両方で成功させる)。
- `SoraTests/ConcurrencyStressTests.swift` (新規): 実 Sora を必要としない交差を反復する。モックやスタブは使わず、実 `ConnectionStateOwner` / 実 `ConnectionTimer` だけを使う。
  - `ConnectionStateOwner` の同期 API (`beginConnectionStart` / `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect` / `prepareSignalingStart` / `finishSignalingStart`) を複数スレッドから交差させ、呼び出しの受理 / 棄却と最終状態の整合を検証する。`DispatchQueue.concurrentPerform(iterations: 64)` による交差を 8 ラウンド反復する (64 は `PeerChannelConnectCompletionTests` / `StreamFrameOwnerTests` / `LoggerTests` と同じ並行度)。`ConnectionStateOwner` は `ConnectionSnapshotStorage` を引数に取って生成する。
  - `ConnectionTimer` の `run()` / `stop()` と timeout 配送を複数スレッドから交差させ、timeout handler が世代照合を通って高々 1 回だけ呼ばれることを検証する。
  - 並行区間の中から `XCTAssert*` を呼ばず、区間の終了後に集約して検証する (`PeerChannelConnectCompletionTests` / `LoggerTests` / `StreamFrameOwnerTests` と同じ方針)。
- `SoraTests/ConcurrencyStressE2ETests.swift` (新規): `E2ETestBase` を継承し、実 Sora 接続を反復する。
  - 1 iteration を「configuration の構築 → connect → DataChannel open → handler 設定 → 切断完了待ち」とし、5 iteration 反復する。iteration ごとに scenario を切り替える (connect / cancel / disconnect、RPC timeout / cancellation、DataChannel open / close)。redirect はサーバー側の指示で発生しクライアントから任意に起こせないため、この stress の scenario には含めない (redirect は既存の `PeerChannelRedirectInvalidationTests` が TSan の対象に入る)。
  - 各 iteration の開始と終了、scenario 名、iteration 番号を日本語のログへ出す (失敗時にどの iteration のどの scenario かを特定するため)。
  - 1 iteration の完了待ちは 30 秒、test 全体の timeout は 300 秒にする。
  - `E2ETestBase` の `disconnectAndVerify` / `disconnectAll` を使い、iteration の間に接続を残さない。
- handler bag の読み書きを並行させる stress は追加しない (「スコープ外」)。
- retry で flaky を隠さない。追加する test が実 Sora に対して flaky と判明した場合は、retry を足さずに scenario を減らすか別 issue へ切り出す。
- 追加する test は `0171` の warnings-as-errors を満たす。非推奨 API の警告以外を出さない。
- 反復回数、scenario、timeout の選択理由は、追加する test のドキュメントコメントと workflow のコメントに日本語で書く。

## スコープ外

- 実カメラ、ReplayKit、AudioUnit (RemoteIO)、マイク入力の実行時検証。Simulator では受信あり接続の `AURemoteIO` の初期化が音声サーバーの RPC タイムアウトで `abort` し、test プロセスごと落ちるため実行時検証の対象にしない。実機での検証は本 issue の対象外である (closed `0134` が実例)。
- 実機 test のチェックリストの作成 (リポジトリに実機 test のチェックリストは存在しないため、本 issue の成果物にしない)。
- Address Sanitizer など TSan 以外の sanitizer の導入。
- handler bag (`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers`) の読み書きを並行させる stress (`0154` が扱う)。
- TSan が検出した race の修正。実装時に検出した場合は別の bug issue として起票し、本 issue には含めない。

## 変更対象

- `.github/workflows/e2e-test.yml`: `tsan` job の追加 (Simulator の boot、`-enableThreadSanitizer YES` の `build-for-testing`、`simctl spawn` による全件実行、interceptor と race と test 数の判定、失敗時の log の artifact 保存)、`slack_notify` の `needs` と `status` の更新。
- `SoraTests/ConcurrencyStressTests.swift` (新規): `ConnectionStateOwner` と `ConnectionTimer` の交差を反復する test。
- `SoraTests/ConcurrencyStressE2ETests.swift` (新規): 実 Sora 接続を反復する E2E stress test。
- `CHANGES.md`: `## develop` の `### misc` に `[ADD]` で「Thread Sanitizer を有効にした concurrency runtime stress CI を追加する」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @t-miya`)。機能に直接影響しない CI 構成の変更のため主リストではなく `### misc` に置き、`### misc` の中では種別の順に従って既存の `[ADD]` の後・最初の `[UPDATE]` の前に置く。

## テスト方針

モックやスタブは使用しない。

- 通常 test: `xcodebuild test -scheme Sora-Package` (または同等の `build-for-testing` + `simctl spawn`) で失敗 0 件であること。基準は 441 件実行 / skip 31 (`0171` / `0181` の実測) に本 issue の追加分を加えた数。
- TSan 有効時: 「設計方針」の手順で全件を実行し、`WARNING: ThreadSanitizer` 0 行、`***** Running under ThreadSanitizer` あり、exit 0 であること。
- interceptor の確認: `SIMCTL_CHILD_TSAN_OPTIONS=verbosity=1` で `ThreadSanitizer: parsing` と `***** Running under ThreadSanitizer` が出ることを確認する (`0177` / `0181` と同じ)。
- 退行検出 1 (negative control): 意図的に race を作る変更 (例: `ConnectionStateOwner` の state の読み書きを排他区間の外へ出す) を一時的に入れ、job と同じコマンドで `WARNING: ThreadSanitizer: data race` が出て exit code が非 0 になることを確認する。確認後は変更を戻し、`git diff` が元と一致することを確認する (`0151` の negative control と同じ。この変更は commit しない)。
- 退行検出 2: `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` を外して同じコマンドを実行し、TSan が load されず race が検出されない (空振りになる) ことを確認する。あわせて interceptor の判定 step がこの空振りを失敗させることを確認する。
- 退行検出 3: `tsan` job の判定 step (race / interceptor / test 数) を、race を含む log と含まない log の両方に対してローカルで実行し、期待どおりに成否が分かれることを確認する。
- `make fmt-lint`、`swiftlint lint --strict`、`make api-check-fresh` が成功すること (公開 API は変更しない)。
- `SoraTests` の build が `0171` の warnings-as-errors を満たすこと。判定は実 build (`xcodebuild build-for-testing`) で行う。
- 実 Sora の E2E stress test は `SORA_SIGNALING_URL` 未設定のローカルでは skip されるため、実 Sora での確認は PR の `e2e-test.yml` (`tsan` job) で行う。

## 完了条件

- `.github/workflows/e2e-test.yml` に `tsan` job があり、`-enableThreadSanitizer YES` の `build-for-testing` が作った `SoraTests.xctest` を `simctl spawn` で実行していること (`test-without-building` を使っていないこと)。
- `tsan` job が `SoraTests` 全体を実行し、`WARNING: ThreadSanitizer` 0 行、`***** Running under ThreadSanitizer` あり、exit 0 で成功すること。
- 実行した test 数が 0 件でないことを job が判定しており、0 件の場合は失敗すること。
- retry (`-retry-tests-on-failure` / `-test-iterations` / `-run-tests-until-failure`) を使っていないこと。
- 失敗時に TSan の report (`build/tsan-report.txt`) が artifact として取得でき、接続情報を含む通常のログ行を持ち出していないこと。
- `slack_notify` が `tsan` の失敗も通知すること。
- 追加した stress test が通常 test で失敗 0 件、TSan 有効時も `WARNING: ThreadSanitizer` 0 行であること。
- negative control で `WARNING: ThreadSanitizer: data race` が報告され exit code が非 0 になること、および `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` を外すと空振りになることを確認していること。
- Simulator 非対応の実機項目がスコープ外として明記されていること。
- `CHANGES.md` の `## develop` の `### misc` に担当者行付きで追記されていること。
- `0151` / `0121` / `0118` / `0129` / `0171` の完了を前提として、`Build` / `Consumer Test` / `E2E Test` と `tsan` job が成功すること。実装時に TSan が race を検出した場合は「スコープ外」のとおり別 issue として起票し、その修正後に `tsan` job が成功することを本 issue の完了条件とする。

## 解決方法

### 追加した job と step

`.github/workflows/e2e-test.yml` に `tsan` job を追加した。実 Sora の secret と Simulator の boot を既に持つ workflow に置くため、`e2e` job とは別 job にしている。実測はクリーンビルド 16 秒 + 全件実行 32 秒の約 1 分であり、cold cache を見込んで `timeout-minutes: 20` にした。

- `runs-on`: `[self-hosted, macOS, ARM64, Apple-M1]` (`e2e` job と同じ)
- `env`: `XCODE` / `XCODE_SDK` / `DESTINATION` / `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX` / `TEST_API_URL`。secret 名は既存の `e2e` job と同じ 4 つ (`TEST_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_CHANNEL_ID_PREFIX` / `TEST_API_URL`) を使う
- step の並び (既存 `e2e` job の書き方に揃えた)
  1. `actions/checkout` (`3d3c42e5aac5ba805825da76410c181273ba90b1`、v7.0.1)
  2. `Show Xcode Version` (step 名なしの uses は既存 job と同じ)
  3. `Setup iOS Simulator` (`boot` + `bootstatus`)
  4. `Run Thread Sanitizer Tests` (`id: tsan_tests`)
  5. `Check Thread Sanitizer Report`
  6. `Upload TSan Report` (`if: failure()`)
  7. `Shutdown Simulator` (`if: always()`)

### TSan の実行手順

`e2e` job の `test-without-building` は使わない。TSan runtime が load されないためである。

1. `rm -rf build` で incremental build の TSan runtime 複製の省略を防ぐ
2. `xcodebuild build-for-testing -scheme Sora-Package -sdk iphoneos26.5 -derivedDataPath build -enableThreadSanitizer YES -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE= SWIFT_VERSION=6`
3. `xcrun simctl list devices booted --json` を python3 で読み、runtime 名に `iOS-26-5` を含み、名前が `iPhone 17 Pro` で `Booted` の device の UDID を取る (booted が複数ある場合があるため名前と OS で特定する)。見つからない場合は `exit 1`
4. `xcrun simctl spawn <UDID> $(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest <BUNDLE>` で全件実行する。`simctl spawn` は親の環境変数を渡さないため、次のすべてを `SIMCTL_CHILD_` 接頭辞で渡す
   - `DYLD_FRAMEWORK_PATH`: `build/Build/Products/Debug-iphonesimulator`
   - `DYLD_INSERT_LIBRARIES`: `<BUNDLE>/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib`
   - `TSAN_OPTIONS=verbosity=1`
   - `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX` / `TEST_API_URL` (E2E の secret を `e2e` job と同じ名前で揃える)

つまり `SIMCTL_CHILD_` は TSan の `DYLD_*` と E2E の環境変数の両方に必要である。実行対象は `SoraTests` 全体で、suite を列挙しない (後から追加した test が無言で TSan の外へ落ちるのを防ぐ)。反復は job の step では行わない (1 回実行)。step の先頭で `set -eo pipefail` を設定し、pipeline の exit code は `grep` より先に `TSAN_EXIT_CODE=$?` で取り出す (`set -e` は非 0 で即座に shell を終了させるため、取り出す間だけ `set +e` にする)。

### 判定 (失敗条件)

順に判定し、いずれかに該当すると step を失敗させる。

1. `WARNING: ThreadSanitizer` の行数が 1 以上なら失敗 (race の report)。`verbosity=1` では `ThreadSanitizer: parsing` と `***** Running under ThreadSanitizer *****` の行も現れるため、`ThreadSanitizer` の単純な行数は使わない
2. `***** Running under ThreadSanitizer` が log に無ければ失敗 (interceptor 無効の「検出 0」は空振り)
3. `Executed N tests` から全体の test 数を取り出し、0 件なら失敗。XCTest は suite ごとに同じ行を出すため、入れ子の重複を避けて最大値 (最も外側の suite の値) を使う。bundle の path を誤っても 0 件で終了し得る
4. pipeline の exit code が 0 でなければ失敗 (race を検出した TSan はプロセスを `BUS` で終了させ非 0 になる)。`grep` は「0 行」のとき exit 1 になり、そのままでは job の成否に使えないため、exit code を主、`WARNING` の行数と interceptor と test 数を従の判定にしている

retry (`-retry-tests-on-failure` / `-test-iterations` / `-run-tests-until-failure`) は使っていない。

### artifact の設計

`actions/upload-artifact` (`ea165f8d65b6e75b540449e92b4886f43607fa02`、v4.6.2) で、失敗時のみ `build/tsan-report.txt` を保存する。`simctl spawn` は `.xcresult` を作らないため log から抽出する。log 全体ではなく `WARNING: ThreadSanitizer` の行から `==================` の行までの report ブロックだけを `awk` で抽出する。`0156` の secret masking が未完了であり、`simctl spawn` の log には接続情報が出得るため、通常のログ行は artifact へ持ち出さない。抽出は `e2e` job の diagnostics 抽出と同じく `grep` / `awk` で行い、report の件数は `grep -c` で数える (`grep` の「0 行」の exit 1 は `|| true` で吸収する)。`actions/upload-artifact` は `actions/*` の commit SHA pin とし、tag をコメントに残す。

### `slack_notify` の更新

`needs` を `[e2e, tsan]` にし、`status` を `contains(needs.*.result, 'failure') && 'failure' || contains(needs.*.result, 'cancelled') && 'cancelled' || 'success'` にした。`needs.e2e.result` のままでは TSan の失敗が通知されない。`on.push.paths-ignore` は変更していない。

`status` を真偽値にしていたため、`slack-notify` が failure と認識せず失敗通知をスキップした (run 36670380572、`ステータス=true`)。`slack-notify` は `failure_and_fixed` の判定に結果文字列を使うため、真偽値ではなく `failure` / `cancelled` / `success` の文字列を返す式に直した。`notify_cancelled` (既定 true) に合わせ、cancelled は failure へ潰さず区別する (`consumer-test.yml` の `swift6-consumer` は潰しているが、`e2e-test.yml` は cancelled の通知を有効にしている)。

### 追加した stress test の内容 (対象・反復・timeout)

`SoraTests/ConcurrencyStressTests.swift` (新規、3 件)。モックやスタブは使わず、実 `ConnectionStateOwner` / 実 `ConnectionTimer` だけを使う。並行区間の中から `XCTAssert*` を呼ばず、結果を lock 付き recorder へ集めて区間の終了後に検証する。乱数は使わず、iteration 番号と scenario 名をログ (`print`) へ出す。0154 が扱う handler bag の読み書きを並行させる stress は含めない (スコープ外)。

- `testConnectionStartRaceAcceptsAtMostOncePerRound`: `beginConnectionStart` を `DispatchQueue.concurrentPerform(iterations: 64)` で交差させる。1 ラウンドで受理されるのは高々 1 回であること、受理した 1 スレッドが `finishSignalingStart` と `endAsyncOperation` で解放し、ラウンド終了時に `asyncOperationCount == 0` / `isStartingConnection == false` / `isDisconnecting == false` になることを検証する。8 ラウンド反復する
- `testAsyncOperationRaceBalancesCountToZero`: `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect` を 64 スレッドで交差させる。開始に成功したスレッドは必ず 1 回終了を登録し、切断要求を即時に受理する呼び出しは高々 1 回であること、ラウンド終了時に残高が 0 に戻り `isDisconnecting == true` になることを検証する。8 ラウンド反復する
- `testConnectionTimerRunStopRaceDeliversHandlerAtMostOncePerGeneration`: 実 `PeerChannel` (`onConnect` を設定して `.connecting`) を monitor にした実 `ConnectionTimer` に対し、`run(timeout: 1)` と `stop()` を 64 スレッドで交差させる。`run()` は呼ばれるたびに旧 Timer を invalidate して世代を進めるため、handler を呼べるのは最後に確定した世代だけである。各ラウンドで handler の呼び出し回数が高々 1 世代分であることを検証し、最後に 1 回だけ `run()` して main RunLoop 上で timeout が配送され handler が呼ばれること (世代照合が機能していること) と、配送後に `isRunning == false` になることを確認する。8 ラウンド反復する

`SoraTests/ConcurrencyStressE2ETests.swift` (新規、1 件)。`E2ETestBase` を継承し、async な `setUp` / `tearDown` 契約に従う。5 iteration の E2E stress とし、iteration 番号から scenario を決める (乱数を使わない)。

- iteration 1: connect / DataChannel open / 切断完了 (正常切断コード 1000) の確認
- iteration 2: `connect` の戻り値を直ちに `cancel()` し、接続が開始されず `mediaChannels` に残らないことの確認
- iteration 3: iteration 1 と同じ connect / disconnect を 3 回繰り返す
- iteration 4: recvonly を接続し、`rpc_methods` に `RequestSimulcastRid` を許可した access token で接続して rpc ラベルの DataChannel の OPEN を待ち、短い timeout (0.001 秒) の RPC を実行して終端を待つ (timeout 経路)
- iteration 5: 同じ接続で実行中の RPC をキャンセルし、終端を待つ (cancellation 経路)

1 iteration の完了待ちは 30 秒、test 全体の timeout は `executionTimeAllowance = 300` 秒にした。`disconnectAndVerify` / `disconnectAll` を使い、iteration の間に接続を残さない。各 iteration の開始と終了、scenario 名、iteration 番号をログへ出す。redirect はサーバー側の指示で発生しクライアントから任意に起こせないため scenario に含めない (`PeerChannelRedirectInvalidationTests` が TSan の対象に入る)。

### 実測 (TSan 全件・negative control・通常 test・基準 test 数)

検証環境は sandbox のため `~/Library/Caches/org.swift.swiftpm` と `~/Library/Developer` への書き込みが拒否される。`CFFIXED_USER_HOME="$PWD/build/home" HOME="$PWD/build/home"` を付けて実行した (`0114` / `0171` / `0177` / `0181` と同じ制約)。

- TSan 全件: `-enableThreadSanitizer YES` の `build-for-testing` (`build/0119-evidence/0119-tsan-build.log`, `** TEST BUILD SUCCEEDED **`, 追加 test は warning / error 0) が作った `SoraTests.xctest` を、`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` / `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` (`<bundle>/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib`) / `SIMCTL_CHILD_TSAN_OPTIONS=verbosity=1` 付きの `xcrun simctl spawn <UDID> .../Agents/xctest <bundle>` で全件実行した。**445 件 / skip 32 / 失敗 0 / `WARNING: ThreadSanitizer` 0 行 / `***** Running under ThreadSanitizer v3` あり / exit 0** (`build/0119-evidence/0119-tsan-all.log`、約 27 秒)。interceptor は `TSAN_OPTIONS=verbosity=1` の `ThreadSanitizer: parsing` と banner で確認した。追加した 4 件は 3 件 pass + `ConcurrencyStressE2ETests` 1 件 skip (`SORA_SIGNALING_URL` 未設定)
- negative control (TSan 有効): 一時的に `SoraTests/TemporaryTSanNegativeControlTests.swift` を追加し、`@unchecked Sendable` な class の stored property を 4096 スレッドで排他なしに読み書きする意図的な race を作り、job と同じ build と実行を行った。**`WARNING: ThreadSanitizer` 5 行 (すべて `TemporaryTSanNegativeControlTests.testIntentionalDataRace()` を指す `Swift access race` / `data race`) / exit code 134 (signal 6, `ThreadSanitizer: reported 5 warnings`) / 445+1 件実行**。判定スクリプトも report 5 件で失敗した。「検出 0 行」の判定が空振りでないことを確認した。計測後に probe を削除し、`git status --short` に現れないことを確認した
- negative control (interceptor 無効): `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` を外して同じ bundle を実行した。race を含まない実行では `ERROR: Interceptors are not working. ... loaded too late` で abort し、`***** Running under ThreadSanitizer` が出ず `Executed N tests` も出ないため、判定 step は失敗する。issue の「race が検出されない (空振りになる)」という記述とは挙動が異なるが、**空振りを失敗させる**という判定の目的は満たす (interceptor の banner と test 数の判定が捕まえる)。probe が無い bundle では検出 0 と区別できないため、interceptor の確認は上の probe の実行で行った
- 通常 test (`build-for-testing` + `simctl spawn`、TSan 無効): **445 件 / skip 32 / 失敗 0** (`build/0119-plain-tests.log`)。追加した 4 件は 3 件 pass + 1 件 skip
- 基準 test 数: 事前実測 (`0171` / `0181`) の 441 件 / skip 31 に本 issue の追加分 4 件 (unit 3 + E2E 1) を加えると **445 件 / skip 32** になり、上の 2 つの実測と一致する。skip の増分 1 は `ConcurrencyStressE2ETests` が `SORA_SIGNALING_URL` 未設定でスキップされる分である
- `0171` の gate: `Package.swift` の `SoraTests` 設定 (`.treatAllWarnings(as: .error)` と `DeprecatedDeclaration` の例外) を効かせた実 build (`build-for-testing`) で、追加 test の warning / error は 0。build log の `warning:` は `Sora` module が非推奨 API を内部で参照する既存のものだけで、`SoraTests/*.swift` からの warning は無い
- workflow の判定ロジック: 実 YAML から `Run Thread Sanitizer Tests` と `Check Thread Sanitizer Report` の `run` を取り出し、実 log に対して実行した。正常 log (445 件 / report 0 / exit 0) は成功、race を含む実 log (report 5 / exit 134) は失敗、banner なしの log は失敗、test 数 0 の log は失敗、report の抽出は `WARNING: ThreadSanitizer` の report ブロックだけを含み接続情報を含む行を含まないことを確認した

### 実行した検証と結果

- `make build` (`-warnings-as-errors -Wwarning DeprecatedDeclaration`): `** BUILD SUCCEEDED **`、error 0
- `make consumer-build SCHEME=ConsumerCore`: `** BUILD SUCCEEDED **`
- `make api-check-fresh`: `The committed API baseline matches the current Sora module.` (公開 API の差分なし)
- `make fmt-lint`: 成功 (追加した 2 file は `swift format --in-place` で整形した)
- `swiftlint lint --strict --cache-path build/swiftlint-cache`: `Found 0 violations, 0 serious in 65 files`。`.swiftlint.yml` の `included` が `Sora` / `TestConsumers` のため `SoraTests` は対象外だが、追加 file は `fmt-lint` の `swift format` で `AlwaysUseLowerCamelCase` と `LineLength` を解消済み
- `make lint` (`swift package plugin ... swiftlint`): 検証環境の sandbox が `sandbox-exec` を拒否する (`sandbox-exec: sandbox_apply: Operation not permitted`) ため実行できない (`0177` と同じ制約)。`swiftlint lint --strict` で代替した
- 全体 test: `xcodebuild test -scheme Sora-Package -derivedDataPath build -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 ...` は、検証環境が PTY を作成できず `Pseudo Terminal Setup Error` (IDEPseudoTerminalDomain code 7) で起動できない (`0177` と同じ制約)。同一の `build-for-testing` 成果物を `simctl spawn` で実行した **445 件 / skip 32 / 失敗 0** で代替した
- workflow の構文: `ruby -ryaml` で YAML を parse できること、`jobs` が `e2e` / `tsan` / `slack_notify` であること、`tsan` の step 名・`timeout-minutes: 20`・env のキー・`slack_notify` の `needs` が `[e2e, tsan]` であること、`uses` がすべて commit SHA で pin されていることを確認した。`actionlint` は環境に無い。既存 `e2e` job の差分は `slack_notify` の `needs` と `status` の 2 行だけで、`e2e` job 自体は変更していない
- `git status --short`: `.github/workflows/e2e-test.yml` と `CHANGES.md` の変更、`SoraTests/ConcurrencyStressE2ETests.swift` と `SoraTests/ConcurrencyStressTests.swift` の新規のみ。コミットと push はしていない

### CI で検出した 4490 INVALID-MESSAGE と scenario の修正

2026-09-30 の `E2E Test` workflow (run 36670380572) の `e2e` job と `tsan` job の両方で、`ConcurrencyStressE2ETests.testConnectionStressScenarios` が失敗した。`e2e` job は `** TEST EXECUTE FAILED **` (exit 65) で `Executed 445 tests, with 7 tests skipped and 2 failures (1 unexpected)`、`tsan` job は同じ失敗で `Check Thread Sanitizer Report` が失敗した (`Run Thread Sanitizer Tests` step 自体は成功、`WARNING: ThreadSanitizer` は 0 行)。

- 失敗したのは iteration 1 (`connect-and-disconnect`、recvonly) の connect である。test の stdout は `stress iteration 1/5 started: scenario=connect-and-disconnect` の 1 行だけで、test の実行時間は 0.46 秒 (`e2e` job) / 0.72 秒 (`tsan` job) であり、connect の送信から約 0.1 秒で `webSocketClosed(statusCode: other(4490), reason: "INVALID-MESSAGE")` が返っている (同じ実行で通っている recvonly の接続は約 0.3 秒で完了しているため、offer の処理まで進まずに拒否されている)
- 原因は iteration 1 の connect が `"audio": false` と `"video": false` を同時に指定していたことである (`config.audioEnabled = false` と `config.videoEnabled = false`)。Sora は recvonly で音声も映像も有効にしない connect を拒否する (`details.reason` の `no_media` に相当すると推測する。Sora のドキュメントは `no_media` を「音声も映像も有効にせずに type: connect を送ってきた場合のエラー」とし、`signaling_error.jsonl` の `details.reason` はクライアントには返らない)。Sora のシグナリングエラーは理由にかかわらず close code 4490 で返り、クライアントが見る reason は `INVALID-MESSAGE` になる
- 同じ CI 実行で通っている E2E test との差分が根拠である。recvonly の接続は `RecvonlyE2ETests` が音声と映像のフラグを既定 (有効) のまま、`RpcE2ETests` / `SimulcastE2ETests` が `audioEnabled = false` かつ映像は有効 (`videoCodec = .vp8`) で通っている。音声と映像を同時に無効にしているのは本 stress test の iteration 1 と 3 だけで、この組み合わせを使う他の E2E test は無い。`videoEnabled = false` と `audioEnabled = false` を同時に使う `MessagingE2ETests` (sendrecv) は通っているため、拒否の条件は「recvonly かつ音声と映像の両方が無効」である
- `RequestSimulcastRid` はこの Sora で許可されている。同じ CI 実行で `RpcE2ETests.testRequestSimulcastRid` が skip せず 10.9 秒で pass している (rpc ラベルの DataChannel も払い出されている)。「残った懸念」に書いた RPC scenario の失敗は今回の原因ではない
- scenario は削減していない。iteration 数は issue の設計どおり 5 のままにし、失敗した connect の組み立てだけを既存の通っている test に揃えた
  - iteration 1 / 3 (recvonly の connect と切断): `RecvonlyE2ETests` と同じ組み立てにした。音声と映像は既定 (有効) のままにし、`initialCameraEnabled = false` だけを指定する。recvonly は `PeerChannel.initializeAudioInput` を通らない (送信側の経路のみ) ため、音声を有効にしても Simulator の AURemoteIO の問題は起きない
  - iteration 2 (sendonly の即時キャンセル): 音声だけを無効にし、映像は無効にしない。`ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` と同じ組み立てにした
  - iteration 4 / 5 (RPC の timeout と cancellation): `RpcE2ETests` の recvonly 接続と同じ組み立てにした。`audioEnabled = false`、映像は有効 (`videoCodec = .vp8`)、`simulcastEnabled = true`、`simulcastRequestRid = .r2`、`dataChannelSignaling = true`、`ignoreDisconnectWebSocket = true`。`rpc_methods` は connect メッセージの `metadata` から外し、access token のクレーム (`rpc_methods` / `simulcast` / `simulcast_request_rid` / `simulcast_rpc_rids`) として渡す。RPC の scenario は signaling の項目が他の scenario と異なるため、`RpcE2ETests` と同じく一意な channel ID を使う
- retry は追加していない。失敗した iteration と scenario は test のログへ出る
- ローカルでは `SORA_SIGNALING_URL` と `TEST_SECRET_KEY` が無いため E2E は skip され、実サーバーでの確認はできない。修正の根拠は「同じ CI 実行で通っている E2E test との差分の解消」である
- 接続メッセージそのものはローカルで確認した。一時的な probe (`SoraTests/TemporaryConnectMessageProbeTests.swift`、確認後に削除) で `Configuration` → `ConnectionConfigurationSnapshot` → `PeerChannel.makeSignalingConnect` → JSON の経路を実行し、修正前の iteration 1 の connect が `"video": false` と `"audio": false` を含むこと、修正後の iteration 1 の connect が `RecvonlyE2ETests` の connect と同じキー (`audio` / `video` を含まない) になること、修正後の RPC scenario の connect が `RpcE2ETests` の recvonly 接続と同じキー (`audio: false` / `video: {codec_type: VP8}` / `simulcast` / `simulcast_request_rid` / `data_channel_signaling` / `ignore_disconnect_websocket`) になることを確認した。probe は削除済みで `git status --short` に現れない

### 残った懸念

- 実 Sora 接続を含む 5 iteration の E2E stress は、ローカルに `SORA_SIGNALING_URL` と `TEST_SECRET_KEY` が無いため skip され、実測できていない。PR の `e2e-test.yml` (`e2e` job と `tsan` job) で確認する。2026-09-30 の CI で iteration 1 が `4490 INVALID-MESSAGE` で失敗したため「CI で検出した 4490 INVALID-MESSAGE と scenario の修正」のとおり修正した。修正後も iteration 4 / 5 (RPC) は実サーバーで実行できていないため、接続の組み立てを `RpcE2ETests` に揃えたこと以外の確認はできていない。PR で失敗が再現する場合は retry を足さず、scenario を減らすか別 issue へ切り出す (Sora のバージョンが `RequestSimulcastRid` を許可しない場合は `RpcE2ETests` と同じく skip にする判断も残る)
- interceptor 無効時の挙動が issue の想定 (race が検出されない) と異なり、`ERROR: Interceptors are not working` で abort した。判定 step は banner と test 数の判定でこの状態を失敗させるため job の目的は満たすが、issue の記述とは食い違う
- `TSAN_EXIT_CODE` は TSan の race 検出時に非 0 になるが、`simctl spawn` の exit code は子プロセスの abort を必ず伝えるとは限らない。そのため job の主判定は `WARNING: ThreadSanitizer` の行数であり、exit code は補助の失敗条件として残している
- `SoraTests` は `.swiftlint.yml` の対象外のため、追加 file の lint は `fmt-lint` (`swift format`) だけである
