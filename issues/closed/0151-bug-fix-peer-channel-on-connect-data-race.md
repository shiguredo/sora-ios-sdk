# PeerChannel.onConnect が排他制御されておらずデータ競合が発生する

- Created: 2026-09-15
- Completed: 2026-09-28
- Priority: Medium
- Branch: feature/fix-peer-channel-on-connect-data-race
- Polished: 2026-09-23

## 目的

`PeerChannel.onConnect` が排他制御なしで複数スレッドから読み書きされており、接続 callback の 1 回保証が壊れ得る。Thread Sanitizer が実際にデータ競合を検出したため、読み書きを単一の排他で保護する。

## 優先度根拠

- 影響: (a) ARC 競合 (Swift の closure は関数ポインタとコンテキストの 2 ワード) によるクラッシュ、(b) 接続 callback の二重呼び出し / 消失、(c) `state` の誤判定 (busy 判定、猶予タイマーのキャンセル判断)
- 発生確率は低い (数命令の窓で、特定の並行パターンが必要) が、Thread Sanitizer は通常のユニットテストで検出した
- CI に Thread Sanitizer がないため、通常のテストや E2E では検出できない
- 修正規模は小さく、公開 callback の保証に直結するため Medium とする (`0001` の PeerChannel.Lock のデータレースは確定的に壊れるため High だった)

## 現状

`PeerChannel.onConnect` は無保護の stored property である。

- 書き: `PeerChannel.connect` の `onConnect = handler`
- 書き: `PeerChannel.invokeConnectHandler` の take-and-clear (`let connectHandler = onConnect` の後に `onConnect = nil`)
- 読み: `PeerChannel.state` の `onConnect != nil`
- 読み: `PeerChannel.Lock.waitDisconnect` の `context?.onConnect != nil` (`Lock.nsLock` を保持しているが、書き側は `nsLock` を取らない)

`PeerChannel.connect` は `Lock.beginConnectionStart()` で初期ロックを取った後に `onConnect = handler` を実行する (`beginConnectionStart()` は `Lock.nsLock` を解放してから戻る)。その近くにある「切断処理との間で onConnect を競合させない」というコメントが指すのは `isStartingConnection` による切断要求の順序の保護であり、`onConnect` の代入自体を保護するものではない。この代入も保護対象に含めること。

`invokeConnectHandler` は `finishConnecting` / `sendConnectMessage(error:)` / `finishBasicDisconnect` から呼ばれる。`finishBasicDisconnect` は `basicDisconnect` が生成する camera cleanup の `Task` の継続から呼ばれるため、非同期 executor のスレッドで実行される。この `Task` は `003bb738` (ステレオ音声出力対応) で導入された。

`-enableThreadSanitizer YES` で `SoraTests/PeerChannelConnectCompletionTests` を実行したときの検出内容:

- 書き: `invokeConnectHandler` ← `finishBasicDisconnect` ← `basicDisconnect` の closure (GCD worker thread)
- 読み: `state` getter ← `PeerChannel.connect` (main thread)

`PeerChannel.connect` は `MediaChannel.basicConnect` から `DispatchQueue.global()` 上で呼ばれる。connect の直後に `MediaChannel.disconnect()` された場合 (onAddMediaChannel からの切断など) は camera cleanup の `Task` の書きと並行し得る。

## 設計方針

- `onConnect` の読み書きを 1 つの排他で保護し、take-and-clear をアトミックにして接続 callback の 1 回保証を構造的に成立させる。利用者 callback の呼び出しは排他区間の外で行うこと (callback 内から同期的に `disconnect()` されると `waitDisconnect` が同じ排他を取るため、保持したままだとデッドロックする。`testInvokeConnectHandlerReentrantDisconnectRunsOnce` がこの再入を検証する)。
- `state` が `onConnect` を読む経路に注意する。`state` は `Lock.shouldCancelDisconnectTimerBasedDisconnect` から `Lock.nsLock` 保持中に呼ばれるため、`Lock.nsLock` で `onConnect` を保護したうえで `state` がそれを取る形にすると非再帰ロックでデッドロックする。次のいずれかを選ぶ。
  - `onConnect` 専用の lock を設け、`Lock.nsLock` と入れ子にしない
  - 接続試行中の判定を `onConnect != nil` ではなく接続試行状態から導き、`state` から `onConnect` の読み出しをなくす。現状 `0100` の `ConnectionStateOwner` が持つ `ConnectionLifecycleState` には接続試行中を表す状態が無いため、この方法を採るには `0100` の reducer へ接続試行の開始 / 終端イベントと状態の追加が必要になる。また、`Lock.waitDisconnect` の `context?.onConnect != nil` の読みも同じ接続試行状態へ置き換え、`onConnect` の読み経路を `state` と `waitDisconnect` の両方からなくすこと
  - `0100` の snapshot storage と同じく lock 保護の snapshot 方式に寄せる

どの方法を選ぶかは `0129` が決める `Lock` の統合先 (0010 の `connectionLifecycleLock` か 0100 の reducer か) と整合させること。`ConnectionLifecycleState` には接続試行中を表す状態が無いため、接続試行状態を導入するなら `0129` の統合先にも同じ状態を渡す形にする。実施順は本 issue を先とする (「スコープ外」)。

## 完了条件

- `onConnect` の読み書きがすべて同一の排他で保護されていること
- `-enableThreadSanitizer YES` で `SoraTests/PeerChannelConnectCompletionTests` を実行してもデータ競合が報告されないこと
- 接続 callback の 1 回保証を検証する既存テスト (`PeerChannelConnectCompletionTests` / `PeerChannelConnectCompletionE2ETests`) が成功すること
- 既存テストがすべて成功すること

## テスト方針

- 通常のテストでは検出できないため、Thread Sanitizer を併用して回帰を確認する。
- 実 Sora / 実 WebRTC を使う既存 E2E で回帰しないことを確認する。モックやスタブは使用しない。

## スコープ外

- `PeerChannel.Lock` の統合 (`0129`) は refactor であり本 issue では扱わない。本 issue はデータ競合の修正に限定する。
- `0129` との実施順は本 issue を先とする。`0129` は `Lock` を統合して削除する側であり、統合後に `waitDisconnect` の `context?.onConnect != nil` をどこへ移すかが変わるため、先に `0129` を入れると同じ修正を統合後の構造でやり直すことになる。`0129` は逆に、本 issue が `Lock.nsLock` とは別に設けた `onConnect` の排他を、統合先でも維持する必要がある (本 issue の「完了条件」の 1 回保証と、利用者 callback を排他区間の外で呼ぶ性質を壊さないこと)。
- `MediaChannel` の接続ライフサイクル (`0010`) は変更しない。

## 解決方法

### 修正内容

`Sora/PeerChannel.swift` の `onConnect` を、`Lock.nsLock` とは別の専用 lock (`connectHandlerLock`) で保護し、読み書きをすべてこの排他へ通すようにした。公開 API は変更していない。

- `onConnect` を、lock 保護の実体 `storedOnConnect` (private) を持つ computed property にした。`SoraTests` からの `peerChannel.onConnect = ...` はこれまでどおり動作する
- 書き: `PeerChannel.connect` の `onConnect = handler` と `PeerChannel.invokeConnectHandler` の take-and-clear が、どちらもこの排他を通る
- 読み: `PeerChannel.state` の `onConnect != nil` と `PeerChannel.Lock.waitDisconnect` の `context?.onConnect != nil` が、どちらもこの排他を通る
- `invokeConnectHandler` を、取り出しと nil へのクリアを 1 回の lock 区間で行う `takeConnectHandler()` に置き換えた。取り出しとクリアが不可分になり、並行して `invokeConnectHandler` が呼ばれても同じ callback が 2 回取り出されない (1 回保証の維持)
- 利用者 callback の呼び出しは `takeConnectHandler()` の lock を解放した後に行う。callback 内から同期的に `disconnect()` されると `Lock.waitDisconnect` が `state` 経由で同じ lock を取るため、保持したまま呼ぶとデッドロックする (`testInvokeConnectHandlerReentrantDisconnectRunsOnce` が検証する)
- `onConnect` の setter は、置き換えられる旧値の解放 (捕捉したオブジェクトの deinit) を `connectHandlerLock` の区間外で行う。lock 保持中の解放は、lock 区間の中で外部コードを走らせることになる (`0165` の方針に合わせる。`Sora/Logger.swift` の `Logger.onOutputHandler` の setter と同じ形)
- `state` は `onConnect` の有無を 1 度だけ読み、その値を両方の分岐で使うようにした。判定ごとに読み直すと、読み出しの間に接続が終端した場合に判定がぶれる

### 選んだ排他方式と lock 順序

「設計方針」の 3 案のうち「`onConnect` 専用の lock を設け、`Lock.nsLock` と入れ子にしない」を選んだ。理由は次の 2 点である。

- 接続試行中を `ConnectionLifecycleState` の状態として導入する案は、`0100` の reducer へ状態とイベントを追加することを意味する。`0129` の統合先 (0010 の `connectionLifecycleLock` か `0100` の reducer か) が決まっていない現時点で reducer の状態集合を増やすと、`0129` の決定を先取りすることになる (「スコープ外」)。`0100` の snapshot storage に寄せる案も、保持する対象が closure 1 つであり、専用 lock に比べて構造が増えるだけで得られる性質は同じである
- 本 issue はデータ競合の修正に限定する。`Lock` の統合 (`0129`) と `0100` の reducer の変更は行わない

lock 順序は `Lock.nsLock` → `connectHandlerLock` の一方向にした。

- `Lock.shouldCancelDisconnectTimerBasedDisconnect` と `Lock.unlock` は `Lock.nsLock` を保持したまま `context?.state` を呼び、`state` が `onConnect` を読む。`Lock.waitDisconnect` も `Lock.nsLock` を保持したまま `context?.onConnect` を読む。したがって `Lock.nsLock` 保持中の `connectHandlerLock` 取得は必ず発生する (この向きの入れ子は避けられない)
- 逆向き (`connectHandlerLock` 保持中の `Lock.nsLock` 取得) は作っていない。`takeConnectHandler()` と `onConnect` の getter / setter は `connectHandlerLock` の区間内で `Lock` のメソッドを呼ばず、利用者 callback も区間外で呼ぶ
- `connect` の `onConnect = handler` は `Lock.beginConnectionStart()` が `Lock.nsLock` を解放した後に実行されるため、この代入も一方向の順序に反しない

`Lock.waitDisconnect` の `count == 1, context?.onConnect != nil` は変更していない。接続試行中の切断要求で `count` を強制的に 0 にして `basicDisconnect` へ到達させる経路はそのままで、この判定に使う `onConnect` の読みだけが新しい排他へ入る。

### 1 回保証の維持根拠

- 接続完了 callback は `onConnect` に 1 つだけ保持され、`invokeConnectHandler` の take-and-clear で 1 回だけ取り出される
- take-and-clear は 1 回の `connectHandlerLock` 区間で行うため、複数のスレッドが同時に `invokeConnectHandler` を呼んでも取り出せる callback は 1 つだけである
- `finishConnecting` / `sendConnectMessage(error:)` / `finishBasicDisconnect` のどの経路から呼ばれても、2 回目以降の `invokeConnectHandler` は `storedOnConnect` が nil のため何もしない
- callback 内から同期的に `disconnect()` されて `basicDisconnect` → `finishBasicDisconnect` → `invokeConnectHandler` へ再入しても、callback は既に取り出し済みなので再実行されない
- 利用者 callback は排他区間の外で呼ぶため、callback から SDK の排他へ再入できる (デッドロックしない)

### テスト

- `SoraTests/PeerChannelConnectCompletionTests.swift` に次の 2 件を追加した。モックやスタブを使わず、実 `PeerChannel` の同じ入口を複数スレッドから呼ぶ
  - `testInvokeConnectHandlerConcurrentCallsRunsOnce`: 8 スレッドから同時に `invokeConnectHandler` を呼び、callback が 2 回以上実行されないことを `XCTestExpectation` の `assertForOverFulfill` で確認する。1 回保証の論理的な根拠は `takeConnectHandler()` の単一の排他区間 (コード側) であり、このテストは主に Thread Sanitizer を有効にした実行での回帰検出を担う (`assertForOverFulfill` 自体を 1 回保証の根拠とはしない)
  - `testConcurrentInvokeConnectHandlerAndStateReadRunsOnce`: `invokeConnectHandler` の take-and-clear (`onConnect` の読みと nil の書き) と `state` の `onConnect != nil` の読みという元の競合対を、`DispatchQueue.concurrentPerform` で同時に駆動する。利用者 callback の呼び出し回数は lock 付き accumulator で集計し、並行実行の外で 1 回であることを検証する (排他を外した旧実装の get → nil では 2 回呼ばれ得るため、論理的な assert として意味を持つ)。`state` の読みは値域 (`.connecting` / `.new`) を集計して外で検証する。並行実行中の closure から `XCTAssert*` を呼ばず、並行実行の終了後に集約して検証する (`LoggerTests` / `StreamFrameOwnerTests` / `CameraStateOwnerTests` と同じ方針)
- `PeerChannel` は `Sendable` ではないため、2 件のテストは `@Sendable` closure へ渡すための `@unchecked Sendable` の用途限定 box を使う。box の根拠は、box 自身が可変状態を持たず、複数スレッドから触る `PeerChannel` の排他を `PeerChannel` 側の `connectHandlerLock` が担うことである (用途は `-swift-version 6` の型検査で `#SendableClosureCaptures` の warning を出さずに実 `PeerChannel` を渡すことに限る)
- callback の呼び出し回数と `state` の読み出し結果の集計は、テストファイル内の lock 付き accumulator (`ConnectTerminationAccumulator`) で行う。可変状態を `@Sendable` closure へ直接 capture しない
- 本 issue で追加した 2 件以外のテストは変更していない

### 検証結果

- `swift format --in-place` の後、`make fmt-lint` は exit 0
- 全体テスト: `xcodebuild test -scheme Sora-Package -derivedDataPath build -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE=` は、この検証環境では SwiftPM の manifest cache (`~/Library/Caches/org.swift.swiftpm`) への書き込みが sandbox で拒否され、exit 74 の `Could not resolve package dependencies` (`cannot open file .../ManifestLoading/sora-ios-sdk.dia' ... Operation not permitted`) で起動できなかった (`build/0151-polish-xcodebuild-test.log`)。そのため `CFFIXED_USER_HOME` / `HOME` を `build/home` に向けた `xcodebuild build-for-testing` の成果物を `xcrun simctl spawn <booted-udid> $(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest <SoraTests.xctest>` で実行した (WebRTC.framework の解決に `SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` を指定する。`build/0151-polish-tests.log`)。**409 件 / skip 30 / 失敗 0**。同じ環境で HEAD の test 集合を build して実行した結果は **407 件 / skip 30 / 失敗 0** であり (実測、`build/0151-polish-tests-before.log`)、409 件はこの 407 件に本 issue で追加した 2 件を加えた数である
- E2E: `PeerChannelConnectCompletionE2ETests` は `SORA_SIGNALING_URL` が未設定のため `E2ETestBase.swift:90` で skip される (skip 30 件に含まれる)。**ローカルでは E2E が環境変数未設定で skip されるため、実 Sora での確認は PR の `e2e-test.yml` で行う (本 issue の close 時点では未実施)**
- Thread Sanitizer: 次のコマンド列で実行した。**`ThreadSanitizer` の検出行は 0** で、`PeerChannelConnectCompletionTests` の 9 件すべてが成功した (`build/0151-polish-tsan-build.log` / `build/0151-polish-tsan-run.log`)

  ```
  # 1. TSan runtime を bundle へ複製させるため build から行う (test-without-building では interceptor が遅れて動かない)
  xcodebuild build-for-testing -scheme Sora-Package -derivedDataPath build -enableThreadSanitizer YES \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
    SWIFT_VERSION=6 CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE=

  # 2. destination と同じ Simulator の UDID を取る
  UDID=$(xcrun simctl list devices booted --json | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(dev['udid'] for rt,devs in d.items() if 'iOS-26-5' in rt for dev in devs if dev['name']=='iPhone 17 Pro' and dev.get('state')=='Booted'))")

  # 3. xctest の path は Platform から取り、TSan runtime は build が SoraTests.xctest/Frameworks へ複製したものを使う
  XCTEST="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
  BUNDLE="$PWD/build/Build/Products/Debug-iphonesimulator/SoraTests.xctest"
  # simctl spawn は親の環境変数を渡さないため、DYLD_* は SIMCTL_CHILD_ 接頭辞で渡す
  SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PWD/build/Build/Products/Debug-iphonesimulator" \
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$BUNDLE/Frameworks/libclang_rt.tsan_iossim_dynamic.dylib" \
    xcrun simctl spawn "$UDID" "$XCTEST" -XCTest SoraTests.PeerChannelConnectCompletionTests "$BUNDLE"
  ```

- negative control: `onConnect` と `takeConnectHandler()` を一時的に lock 保護なしの stored property の読み書きへ戻して同じ手順を実行したところ、`testConcurrentInvokeConnectHandlerAndStateReadRunsOnce` が data race を 5 件報告した (`build/0151-polish-tsan-run-negative.log`)。内訳は「書き: `storedOnConnect.setter` ← `takeConnectHandler()` ← `invokeConnectHandler`」と「読み: `storedOnConnect.getter` ← `onConnect.getter` ← `state.getter`」の対 (元の報告と同じ読みと書きの競合)、および `invokeConnectHandler` を並行に呼ぶスレッド間の書きと書きの対である。`ThreadSanitizer` に言及する行は 14 行で、`objc_retain` の `BUS` で abort した。interceptor が有効であることと、本修正が検出対象の競合を消していることを確認した。**この検出は新規テストの並行アクセス (`invokeConnectHandler` と `state`) によるものであり、元の報告経路 (`finishBasicDisconnect` / `connect`) ではない**。計測後は一時変更を戻し、`git diff` が計測前と一致することを確認した (build の成果物も戻した後に取り直した)
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` はすべて成功した (`The committed API baseline matches the current Sora module.`)
- `swiftlint lint --strict --cache-path build/swiftlint-cache` は 0 violations
- `Sora/` の Swift 6 型検査 (`swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios14.0-simulator -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator -module-cache-path build/module-cache`) は、実装前 (HEAD の `Sora/PeerChannel.swift` に戻して同じコマンドで取得) と実装後がいずれも warning 28 件 / error 0 件で、うち `#SendableClosureCaptures` は 11 件である。増えていない

### テストを追加できなかった観測点

`connect` が実行する `onConnect = handler` の代入そのものを、`connect` の実経路で `state` の読み出しと並行させる観測点は追加していない。`connect` は `Lock.beginConnectionStart()` に成功した 1 つの呼び出しだけが代入へ到達し、同じ `PeerChannel` への 2 本目の `connect` は `beginConnectionStart()` に失敗して代入しない。実経路で代入と読み出しを並行させるには `Lock` の内部状態を外から操作する必要がある。この代入も `takeConnectHandler()` と同じ `connectHandlerLock` を通るが、割り込みの窓を作れるのはテストからの連続代入だけである。代入を含む書きと読みの排他は共通であり、`testConcurrentInvokeConnectHandlerAndStateReadRunsOnce` は同じ `connectHandlerLock` を通る書き (`takeConnectHandler()` の nil 代入) と読み (`state`) を並行させて検証する。実経路での順序 (代入が `Lock.nsLock` の解放後であること) はコードとコメントで固定する。
