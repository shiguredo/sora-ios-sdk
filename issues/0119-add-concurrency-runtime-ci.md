# concurrency runtime stress CI を追加する

- Created: 2026-08-27
- Completed:
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
- `runs-on` と `env` は既存 `e2e` job と揃える (`[self-hosted, macOS, ARM64, Apple-M1]`、`XCODE_SDK=iphoneos26.5`、iPhone 17 Pro / OS 26.5)。同じ self-hosted runner を `e2e` job と共有するため、実行時間は CI 全体に加算される。TSan は通常 test より遅いので `timeout-minutes: 60` にする (既存 `e2e` job は 45)。
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
- job の step では反復しない (1 回の実行)。race を確率的に踏むための反復は、追加する stress test の内部で行う。test 実行の実測は約 26 秒 (build を含まない、skip 31 の状態) であり、実 Sora 接続を含む CI でも `timeout-minutes: 60` に収まる。
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
