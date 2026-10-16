# E2E テストの RPC 切断競合テストが、切断完了を待たずに同一 channelId へ再接続するため断続的に失敗する問題を修正する

- Created: 2026-10-16
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-rpc-race-reconnect-timeout-flake
- Polished: {YYYY-MM-DD}

## 目的

E2E テストの CI が、無関係な変更の push でも断続的に赤くなる問題を解消する。

2026-10-16 の develop への push (run 38833224522) で `RpcE2ETests.testRPCRaceWithDisconnectTerminatesAll` が失敗し、E2E の `e2e` job が赤くなった。同じ commit を再実行した run 38833228062 では同じテストが成功しており、SDK の回帰ではなくテストまたはその実行環境に依存する不安定要因である。

## 現状

失敗した run 38833224522 の `e2e` job (job id 116756446277) のログから確認できた事実は次のとおり。

- 失敗したテストは `SoraTests/RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll`。失敗は 2 件で、いずれも同テスト内の `XCTFail`。
  - `再接続に失敗した : connectionTimeout` — テスト内の再接続処理 (`attempt > 1` の分岐で `sora?.connect(configuration:)` を呼ぶ箇所) のエラーハンドラ
  - `再接続後にメディアチャネルが nil` — 直前のエラーで `reconnectChannel` が設定されないため
- テスト実行のタイムラインは次のとおり。テストは 10:10:14.890 に開始し、10:10:46.413 に `Connection is timeout` (PeerChannel / SignalingChannel / MediaChannel / MediaChannel の `connection timeout`) が記録され、10:10:46.82 に 31.932 秒で失敗した。再接続 1 回あたりが約 30 秒を消費しており、これは `Configuration.connectionTimeout` の既定値 30 秒と一致する。
- 再接続待ちの `wait(for:timeout:)` は 35 秒であり、SDK 側の 30 秒の `connectionTimeout` が先に発火する。したがってこの経路では、テストが待ち時間でタイムアウトするのではなく、SDK の接続タイムアウトがエラーとして返り、そのエラーが `XCTFail` として記録される。
- 失敗した commit `d9cc820` の変更は `Sora/PackageInfo.swift` のバージョン文字列 1 行のみ (`git show --stat d9cc820`)。このテストの失敗を説明できる変更を含まない。
- 同じ commit `d9cc820` の再実行である run 38833228062 の `e2e` job (job id 116756457630) では、同じテストが 5.259 秒で成功している。runner は同じ `macos-m1`。
- 同じ run 38833224522 の並行実行された `tsan` job (job id 116756446075, runner `macos-m1-2`) は、同じテストを 10:10:22 に開始して 10:10:28 に 6.119 秒で成功させている。`e2e` job が 10:10:16 から 10:10:46 まで再接続で固まっていた時間帯と重なる。両 job は同じ Sora サーバーへ接続している。なお両 job のチャンネル ID suffix は `TEST_CHANNEL_ID_SUFFIX` で job ごとに分離済み (`.github/workflows/e2e-test.yml`)。
- 同種の失敗の前例がある。2026-10-09 の run 37915949613 の `e2e` job でも、`testRPCRaceWithDisconnectTerminatesAll` が同じ 2 件の assertion (再接続失敗 / メディアチャネルが nil) で失敗している。このときのエラーは `connectionTimeout` ではなく `webSocketError(NSURLErrorDomain Code=-1011 ...)` であり、失敗の見え方は同じでも下位の原因は異なる。当該 run は issue 0187 の対応中に観測されたもので、0187 の対象 (チャンネル ID 衝突) とは別要因として扱われている。

なお、この run の `Show E2E Crash Diagnostics` step は `xctest` の `EXC_BAD_ACCESS` / `SIGSEGV` (`webrtc::Thread::Get`) の report を 1 件出力している。これは本件の assertion 失敗とは別の report であり、issue 0187 でも同種の crash が本筋の失敗とは別物として扱われているため、本 issue の対象外とする。

### 原因

切断の完了を待たずに、同じ `channelId` で即座に再接続しているためである。

`testRPCRaceWithDisconnectTerminatesAll` は、RPC 呼び出しと `disconnect()` の競合を 12 回試行する。各試行は次の順で進む。

1. `callRPCAndDisconnect` が RPC 呼び出しを開始し、0.1 秒後に `disconnect()` を呼ぶ
2. テストは切断の完了を待たず、RPC の completion を待つだけで次の試行へ進む
3. 次試行の冒頭で `sora?.connect(configuration: recvonlyConfig)` を呼び、前の接続のサーバー側セッション解放が終わっていない同じ `channelId` へ新しい接続を張る

`channelId` はテスト冒頭で `buildChannelId(unique: true)` により 1 回だけ生成し、12 回すべての再接続で同じ値を使い回す。このため、前の接続の解放が終わる前に同一 `channelId` の接続シグナリングが送られ、Sora 側で新しい接続が受け入れられない状態が起こりうる。この状態では接続が進行せず、SDK の `ConnectionTimer` が `Configuration.connectionTimeout` の既定値 30 秒で `beginDisconnect(error: SoraError.connectionTimeout, ...)` を実行し、再接続が `connectionTimeout` で終端する。

補足すると、`SignalingChannel.connect` は既に自チャネルが `.connecting` の場合 `SoraError.connectionBusy` を即座に返す。今回返ったのは `connectionBusy` ではなく `connectionTimeout` であるため、SDK 内部の排他で弾かれたのではなく、接続要求は送信されたが Sora からの応答が得られなかったと判断できる。

失敗した run 38833224522 の 30 秒間には、SDK の中間ログ (`disconnected from` / `failed to connect to Sora` / WebSocket エラー) が 1 件も出ていない。E2E テストは `E2ETestBase.setUp` で `Logger.shared.level = .warn` に設定するため INFO / DEBUG は出力されないが、この 30 秒間に ERROR すら出ていないことは、接続が失敗として確定するまで何も進行せず待たされていたことと整合する。

### 同種の前例と回避策

同じリポジトリの `SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` には、まさにこの競合を避けるための待機が入っている。

```
// 1 秒待機してから再接続する (即時再接続による DUPLICATED-CHANNEL-ID レースを避ける)
// 1 秒の待機は main RunLoop 上で行い、Thread.sleep は使用しない
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
  _ = self.sora?.connect(configuration: config) { ... }
}
```

過去の issue 0042 では「切断処理の完了 (サーバー側セッション解放) 前に次の接続シグナリングが送られると競合する」ことが記録されている。ただし 0042 は当該サーバー側エラーが現行 Sora で廃止されたとして対応不要で closed になっており、この待機はその名残である。

`testRPCRaceWithDisconnectTerminatesAll` にはこの待機に相当するものが無い。切断完了を待たずに同一 `channelId` へ再接続する点が、`testSendonlyReconnect` と異なる。

### テスト構造上の問題点

- 次試行の再接続が、前試行の切断処理と重なる。切断完了を待つ仕組みが無い。
- 再接続の待ちに使う `wait(for:timeout:)` の 35 秒は SDK の `connectionTimeout` (30 秒) より長い。SDK の 30 秒タイマーが先に発火すると、テスト自身の待ち時間ではなく SDK の接続タイムアウトがエラーとして返り、それが `XCTFail` として記録される。「接続が遅い」ことと「失敗」が直結する構造になっている。

## 設計方針

原因はテスト側の再接続手順 (切断完了を待たずに同一 `channelId` へ再接続する) にある。SDK の欠陥と断定できる根拠は得られていない。同じ commit の再実行と並行する `tsan` job の双方で同じテストが数秒で成功していることからも、SDK 側の変更ではなくテスト側の手順を直す。

- 次試行の再接続に入る前に、前試行の切断完了を待つ。`E2ETestBase` の `disconnectAll(channels:)` と同様に `onDisconnect` を待つ形にし、「切断完了を待たずに同じ `channelId` へ再接続する」順序を無くす。
- `testSendonlyReconnect` の 1 秒待機と同じく、固定時間の待機を入れる案は採らない。切断完了を検知して待つほうが、必要な分だけ待つ形になり、サーバー側の解放に要する時間が環境で変動しても成立する。切断完了を検知する仕組みで足りない場合に限り、固定待機の追加を検討する。
- テスト自身の再接続待ちより先に SDK の `connectionTimeout` が発火しないようにする。`recvonlyConfig` の `connectionTimeout` を明示的に設定し、テストの待ち時間との関係をコード上で読み取れるようにする (`SendonlyE2ETests` が `connectionTimeout` を明示している扱いと揃える)。
- 上記を行っても再接続が遅い状況そのものが解消しない場合は、それが SDK の欠陥か実行環境依存かを切り分ける。切り分けは実 Sora への接続を伴うため、`e2e` job のログに再接続の所要時間を残すなど、次回失敗時に判断できる情報を増やす。あわせて、切り分けられた結果を本 issue に記録する。
- SDK の実装・公開 API を変えない。テストの検証内容 (RPC の pending が残存しないこと) を弱めない。試行回数を減らして失敗確率を下げるような対処は採らない。

## 完了条件

- 12 回の試行の各回で、前試行の切断完了を待ってから再接続していること。
- `testRPCRaceWithDisconnectTerminatesAll` が、再接続のたびに `connectionTimeout` で失敗しないこと。
- テスト自身の再接続待ちのタイムアウトと SDK の `connectionTimeout` の関係が、コード上で読み取れること。SDK の `connectionTimeout` がテストの待ち時間より先に発火して失敗として記録される状態を解消していること。
- `e2e` job を、本件の失敗が再現しない状態で複数回 success させること (再実行を含めてよい)。失敗した run は原因を記録したうえで数え直す。
- テストの検証内容 (RPC 呼び出しと disconnect を競合させても、すべての RPC が timeout 以内に終端すること) を変えないこと。
- SDK の実装・公開 API を変えないこと。
- 変更後に `SoraTests` が Simulator で失敗 0 であること。

## 解決方法

{YYYY-MM-DD} に対応する。(未対応)
