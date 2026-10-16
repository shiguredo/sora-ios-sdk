# E2E テストの RPC 切断競合テストが、切断完了を待たずに同一 channelId へ再接続するため断続的に失敗する問題を修正する

- Created: 2026-10-16
- Completed: 2026-10-16
- Branch: feature/fix-rpc-race-reconnect-timeout-flake
- Polished: 2026-10-16

## 目的

E2E テストの CI が、無関係な変更の push でも断続的に赤くなる問題を解消する。

2026-10-16 の develop への push (run 38833224522) で `RpcE2ETests.testRPCRaceWithDisconnectTerminatesAll` が失敗し、E2E の `e2e` job が赤くなった。同じ commit を再実行した run 38833228062 では同じテストが成功しており、SDK の回帰ではなくテストまたはその実行環境に依存する不安定要因である。

## 現状

失敗した run 38833224522 の `e2e` job (job id 116756446277) のログから確認できた事実は次のとおり。

- 失敗したテストは `SoraTests/RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll`。失敗は 2 件で、いずれも同テスト内の `XCTFail`。
  - `再接続に失敗した : connectionTimeout` — テスト内の再接続処理 (`attempt > 1` の分岐で `sora?.connect(configuration:)` を呼ぶ箇所) のエラーハンドラ
  - `再接続後にメディアチャネルが nil` — 直前のエラーで `reconnectChannel` が設定されないため
- テスト実行のタイムラインは次のとおり。テストは 10:10:14.890 に開始し、10:10:46.413 に `Connection is timeout` (PeerChannel / SignalingChannel / MediaChannel / MediaChannel の `connection timeout`) が記録され、10:10:46.82 に 31.932 秒で失敗した。失敗に至った 1 回の再接続が約 30 秒を消費しており、これは `Configuration.connectionTimeout` の既定値 30 秒と一致する (同じテストの正常終了では 12 回の試行全体が 5.259 秒で、1 回あたりの再接続は 30 秒かかっていない)。
- 再接続待ちの `wait(for:timeout:)` は 35 秒であり、SDK 側の 30 秒の `connectionTimeout` が先に発火する。したがってこの経路では、テストが待ち時間でタイムアウトするのではなく、SDK の接続タイムアウトがエラーとして返り、そのエラーが `XCTFail` として記録される。
- 失敗した commit `d9cc820` の変更は `Sora/PackageInfo.swift` のバージョン文字列 1 行のみ (`git show --stat d9cc820`)。このテストの失敗を説明できる変更を含まない。
- 同じ commit `d9cc820` の再実行である run 38833228062 の `e2e` job (job id 116756457630) では、同じテストが 5.259 秒で成功している。runner は同じ `macos-m1`。
- 同じ run 38833224522 の並行実行された `tsan` job (job id 116756446075, runner `macos-m1-2`) は、同じテストを 10:10:22 に開始して 10:10:28 に 6.119 秒で成功させている。`e2e` job が 10:10:16 から 10:10:46 まで再接続で固まっていた時間帯と重なる。両 job は同じ Sora サーバーへ接続している。なお両 job のチャンネル ID suffix は `TEST_CHANNEL_ID_SUFFIX` で job ごとに分離済み (`.github/workflows/e2e-test.yml`)。
- 同種の失敗の前例が 2 件ある。
  - 2026-10-14 の run 38504592116 の `tsan` job では、同じ `testRPCRaceWithDisconnectTerminatesAll` が同じ `connectionTimeout` で失敗し、`tsan_exit_code` が非 0 になった。これは issue 0188 の現状に記録されており、issue 0188 は「tsan job 内で走る E2E テストのサーバー接続 timeout のフレーキーは別問題とする」として本件を対象外にしている。本 issue の対象はこの切り出しと一致する。
  - 2026-10-09 の run 37915949613 の `e2e` job でも、`testRPCRaceWithDisconnectTerminatesAll` が同じ 2 件の assertion (再接続失敗 / メディアチャネルが nil) で失敗している。このときのエラーは `connectionTimeout` ではなく `webSocketError(NSURLErrorDomain Code=-1011 ...)` であり、失敗の見え方は同じでも下位の原因は異なる見込みである。ただしこの run の `e2e` job の失敗は issue 0187 / 0188 / 0189 のいずれにも記録されておらず (issue 0187 のファイルに run 37915949613 の記述は無い。issue 0188 はこの run を `tsan` job の report 抽出失敗、すなわち issue 0189 の対象としてのみ言及している)、`-1011` が issue 0187 の対象 (並行実行によるチャンネル ID 衝突) そのものであった可能性を本 issue では排除できない。なお issue 0187 の完了条件は `NSURLErrorDomain Code=-1011` などで赤くなった run を検証回数に数えず「原因を別 issue として記録したうえで再実行する」としており、本 issue の前例の記録はこれに沿う。

なお、この run の `Show E2E Crash Diagnostics` step は `xctest` の `EXC_BAD_ACCESS` / `SIGSEGV` (`webrtc::Thread::Get`) の report を 1 件出力している。これは本件の assertion 失敗とは別の report であり、issue 0187 でも同種の crash が本筋の失敗とは別物として扱われているため、本 issue の対象外とする。

### 原因

切断の完了を待たずに、同じ `channelId` で即座に再接続しているためである。

`testRPCRaceWithDisconnectTerminatesAll` は、RPC 呼び出しと `disconnect()` の競合を 12 回試行する。各試行は次の順で進む。

1. `callRPCAndDisconnect` が RPC 呼び出しを開始し、0.1 秒後に `disconnect()` を呼ぶ
2. テストは切断の完了を待たず、RPC の completion を待つだけで次の試行へ進む
3. 次試行の冒頭で `sora?.connect(configuration: recvonlyConfig)` を呼び、前の接続のサーバー側セッション解放が終わっていない同じ `channelId` へ新しい接続を張る

`channelId` はテスト冒頭で `buildChannelId(unique: true)` により 1 回だけ生成し、12 回の試行すべて (うち 11 回が再接続) で同じ値を使い回す。このため、前の接続の解放が終わる前に同一 `channelId` の接続シグナリングが送られ、Sora 側で新しい接続が受け入れられない状態が起こりうる。この状態では接続が進行せず、SDK の `ConnectionTimer` が `Configuration.connectionTimeout` の既定値 30 秒で `beginDisconnect(error: SoraError.connectionTimeout, ...)` を実行し、再接続が `connectionTimeout` で終端する。

補足すると、`SignalingChannel.connect(handler:)` は既に自チャネルが `.connecting` の場合 `SoraError.connectionBusy` を即座に返す。今回返ったのは `connectionBusy` ではなく `connectionTimeout` であるため、SDK 内部の排他で弾かれたのではなく、接続要求は送信されたが Sora からの応答が得られなかったと判断できる。

失敗した run 38833224522 の 30 秒間には、SDK の中間ログ (`disconnected from` / `failed to connect to Sora` / WebSocket エラー) が 1 件も出ていない。ただし `Sora/SignalingChannel.swift` の「disconnected from」「failed to connect to Sora」は `Logger.info`、接続試行時の「try connecting」は `Logger.debug` であり、E2E テストは `E2ETestBase.setUp` で `Logger.shared.level = .warn` に設定するため、いずれも出力されない。したがって中間ログの欠如は、接続が何もせず待たされていたことの証拠にはならない (正常に進行していても同じように見える)。この 30 秒間で観測できるのは、接続が失敗として確定した時点の `Logger.error` の「connection timeout」(`Sora/MediaChannel.swift` のタイマー処理) だけである。

### 同種の前例と回避策

同じリポジトリの `SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` には、まさにこの競合を避けるための待機が入っている。

```
// 1 秒待機してから再接続する (即時再接続による DUPLICATED-CHANNEL-ID レースを避ける)
// 1 秒の待機は main RunLoop 上で行い、Thread.sleep は使用しない
// (main RunLoop を止めると DummyVideoCapturer のフレーム送信が停止するため)
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
  _ = self.sora?.connect(configuration: config) { mediaChannel, error in ... }
}
```

過去の issue 0042 では「切断処理の完了（サーバー側セッション解放）前に次の接続シグナリングが送られると競合する」ことが記録されている。ただし 0042 は当該サーバー側エラーが現行 Sora で廃止されたとして対応不要で closed になっており、この待機はその名残である。

`testRPCRaceWithDisconnectTerminatesAll` にはこの待機に相当するものが無い。切断完了を待たずに同一 `channelId` へ再接続する点が、`testSendonlyReconnect` と異なる。

### テスト構造上の問題点

- 次試行の再接続が、前試行の切断処理と重なる。切断完了を待つ仕組みが無い。
- 再接続の待ちに使う `wait(for:timeout:)` の 35 秒は、SDK の `connectionTimeout` (`Configuration.connectionTimeout` の既定値 30 秒) とは無関係な固定値で、コード上に関係が読み取れない。SDK の 30 秒タイマーが先に発火すると、テスト自身の待ち時間ではなく SDK の接続タイムアウトがエラーとして返り、それが `XCTFail` として記録される。サーバー側セッション解放の遅延が 30 秒を超える場合に「接続が遅い」ことと「失敗」が直結する構造になっている。`SendonlyE2ETests` は同じ構造の問題を、`connectionTimeout` (60 秒) を明示し、待ち時間をその内包値 (`SendonlyE2ETests.connectionTimeout` 60 秒 + 30 秒 = `SendonlyE2ETests.connectWaitTimeout` 90 秒) にして扱っているが、`testRPCRaceWithDisconnectTerminatesAll` には `connectionTimeout` の明示が無い。

## 設計方針

原因はテスト側の再接続手順 (切断完了を待たずに同一 `channelId` へ再接続する) にある。SDK の欠陥と断定できる根拠は得られていない。同じ commit の再実行と並行する `tsan` job の双方で同じテストが数秒で成功していることからも、SDK 側の変更ではなくテスト側の手順を直す。

- 次試行の再接続に入る前に、前試行の切断完了を待つ。`SoraTests/E2ETestBase.swift` の `disconnectAll(channels:)` と同様に `onDisconnect` を待つ形にする。同メソッドはハンドラ設定の前後で `channel.state != .disconnected` を確認し、切断が間に挟まって `onDisconnect` の発火を取りこぼさない作りになっている。本テストでも、RPC 完了の待ちが長引いて `onDisconnect` がハンドラ設定より先に発火した場合は取りこぼさないよう、同じ確認を入れる。「切断完了を待たずに同じ `channelId` へ再接続する」順序を無くす。
- `testSendonlyReconnect` の 1 秒待機と同じく、固定時間の待機を入れる案は採らない。切断完了を検知して待つほうが、必要な分だけ待つ形になり、サーバー側の解放に要する時間が環境で変動しても成立する。切断完了を検知する仕組みで足りない場合に限り、固定待機の追加を検討する。
- SDK の `connectionTimeout` とテストの再接続待ちの関係を、コード上で読み取れる形にする。`recvonlyConfig` の `connectionTimeout` を明示的に設定し (既定値 30 秒に依存させない)、再接続待ちのタイムアウトを `connectionTimeout + 余裕` の内包値にする (`SendonlyE2ETests` が `connectionTimeout` 60 秒・`connectWaitTimeout` 90 秒で扱っているのと同じ関係)。`SendonlyE2ETests` は SDK の `ConnectionTimer` による `connectionTimeout` の発火を wait の内側で処理し、テスト終了後に遅延コールバックが残らないよう余裕を足しており、本テストも同じ関係に揃える。これにより、サーバー側セッション解放の遅延が SDK の 30 秒タイマーより長い場合に、実際には成立しうる接続が SDK のタイムアウトで失敗として記録される状態を無くす。SDK の `connectionTimeout` が発火するときは、設定した待ち時間内に接続が成立しなかったときだけになり、テスト自身の待ち時間切れで失敗が記録されることは無くなる。
- 上記を行っても再接続が遅い状況そのものが解消しない場合は、それが SDK の欠陥か実行環境依存かを切り分ける。切り分けは実 Sora への接続を伴うため、`e2e` job のログに再接続の所要時間を残すなど、次回失敗時に判断できる情報を増やす。あわせて、切り分けられた結果を本 issue に記録する。
- SDK の実装・公開 API を変えない。テストの検証内容 (RPC の pending が残存しないこと) を弱めない。試行回数を減らして失敗確率を下げるような対処は採らない。

## 完了条件

- 2 回目以降の各試行 (11 回の再接続) で、前試行の切断完了を待ってから再接続していること。切断完了の待ちには上限を設け、待ち切れなかった場合は失敗を残して後始末すること (`E2ETestBase.disconnectAll(channels:)` の 10 秒待ちと同じ扱い)。
- `testRPCRaceWithDisconnectTerminatesAll` が、再接続のたびに `connectionTimeout` で失敗しないこと。
- 再接続待ちのタイムアウトが SDK の `connectionTimeout` の内包値になっており (例: `connectionTimeout` 60 秒・待ち 90 秒)、SDK の `connectionTimeout` の発火 (接続失敗の通知) が再接続待ちの wait の内側で処理されること。SDK の `connectionTimeout` とテストの待ち時間の関係がコード上で読み取れること、およびテスト終了後に遅延コールバックが残らないこと。
- `e2e` job を、本件の失敗が再現しない状態で 5 回以上 success させること (再実行を含めてよい)。失敗した run は原因を記録したうえで再実行し、成功した回だけを数える。あわせて、`tsan` job でも同じテストの `connectionTimeout` 失敗が再現しないことを確認すること (run 38504592116 では `tsan` job で失敗している。データ競合などの他因で赤くなった run は本件の検証には数えず、issue 0188 等の対象とする)。
- テストの検証内容 (RPC 呼び出しと disconnect を競合させても、すべての RPC が timeout 以内に終端すること) を変えないこと。
- SDK の実装・公開 API を変えないこと。
- 変更後に `SoraTests` が Simulator で失敗 0 であること。

## 解決方法

2026-10-16 に対応する。原因はテスト側の再接続手順にあり、SDK の実装・公開 API は変更していない。`SoraTests/RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll` を次のとおり修正した。

- 2 回目以降の各試行で、再接続の前に前試行の切断完了 (`onDisconnect`) を待つようにした (`waitForDisconnectCompletion(channel:timeout:)` を追加)。切断完了を待たずに同じ `channelId` へ接続シグナリングを送ると、Sora 側で前のセッションが解放される前に新しい接続が届き、接続が成立しないまま SDK の `connectionTimeout` で終端し得る
  - 待ち方は `E2ETestBase.disconnectAll(channels:)` と同じにし、`state` の確認とハンドラ設定の間で切断が完了して `onDisconnect` を発火済みの場合を取りこぼさない。上限は同メソッドと同じ 10 秒とし、待ち切れなかった場合は失敗を記録したうえで後始末する
- 再接続の待ち時間を SDK の `connectionTimeout` の内包値にした。`sendonlyConfig` / `recvonlyConfig` に `connectionTimeout` 60 秒を明示し (SDK の既定値 30 秒に依存しない)、接続と再接続の待ちを `connectionTimeout + 30` の 90 秒にした。これにより `ConnectionTimer` による `connectionTimeout` の発火 (接続失敗の通知) は wait の内側で処理され、テスト終了後に遅延コールバックが残らない
- `MediaChannelHandlers` は同じ `Configuration` から作ったチャンネル間で共有されるため、待ちで設定する `onDisconnect` / `onDataChannelOpened` を待ち終了時に外し、fulfill を 1 回だけにした。残したままにすると、次の試行のチャンネルの切断・OPEN 通知で同じ closure が呼ばれ、fulfill 済みの expectation を再度 fulfill して XCTest の API violation (over-fulfill) になる
- 接続 callback が wait の終了後に発火した場合に assertion を記録しないフラグを足した (テスト終了後の失敗が次のテストへ誤帰属するのを防ぐ)
- `CHANGES.md` の `## develop` の `### misc` に `[FIX]` を追記した

検証:

- Simulator (iPhone 17 Pro / iOS 26.5) で `SoraTests` を実行し、522 tests / 39 skipped / 0 failures になった (修正の反映ごとに 3 回実行)
- `make fmt-lint`、SwiftLint `--strict` (0 violations)、`prek` の pre-commit フックが通ることを確認した
- 独立レビューを 2 回 (差分の批判レビューと修正の検証レビュー) 実施し、検出した致命的 1 件 (共有ハンドラの二重 fulfill) と重要 1 件 (wait 終了後の遅延 callback) を修正した
- 実 CI (2026-10-16、run 38866197947、sha `f59b6bb8`) で `e2e` job が 5 回すべて success になった (attempt 1 は push による初回、attempt 2〜5 は job の再実行)。各 attempt で当該テストが passed している (4.837 秒 / 5.251 秒 / 4.727 秒 / 4.856 秒 / 5.703 秒)
- 同じ run の `tsan` job も success で、当該テストは passed (4.999 秒)。`connectionTimeout` の失敗は再現していない
- テストの検証内容 (12 回の試行で RPC と disconnect を競合させ、すべての RPC が timeout 以内に終端すること) と試行回数は変えていない

残った懸念:

- クライアント側の `onDisconnect` は SDK が切断処理を終えた時点の通知であり、Sora 側のセッション解放完了を保証するものではない (`SignalingChannel.disconnect` は WebSocket の close を投げた直後に内部の `onDisconnect` を呼ぶ)。`SendonlyE2ETests.testSendonlyReconnect` のような固定時間の待機は、切断完了の検知で足りない場合に限り検討するとして今回は入れていない
- E2E テストは `SORA_SIGNALING_URL` が未設定のローカルではスキップされるため、修正した経路の実行検証は実 CI のみである (ローカルの Simulator 実行ではコンパイルと他のテストの非回帰だけを確認している)
- `E2ETestBase.disconnectAll(channels:)` は共有ハンドラに `onDisconnect` を残す。テスト末尾でのみ使われるため現状は顕在化しないが、同じ `Configuration` で再接続するテストを追加すると同じ over-fulfill を起こし得る
