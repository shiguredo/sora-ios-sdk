# WrapperVideoEncoderFactory の simulcastEnabled が無同期で読み書きされるデータ競合を修正する

- Created: 2026-10-02
- Completed: 2026-10-02
- Priority: Medium
- Branch: feature/fix-simulcast-enabled-race
- Polished: 2026-10-02

## 目的

`WrapperVideoEncoderFactory` は `@unchecked Sendable` を宣言しているが、`simulcastEnabled` を無同期の可変プロパティとして保持しており、書き込みと libwebrtc 側の読み取りが排他されていない。データ競合 (未定義動作) をなくし、Thread Sanitizer (TSan) を有効にした CI の `tsan` job が race を報告しないようにする。

## 優先度根拠

- 単一接続の通常利用では実害が顕在化しにくい。書き込みは接続開始時と `type: offer` 受信時の 2 箇所で、通常は接続の初期化段階で行われる (redirect で接続途中に offer を受ける場合も同じ経路を通る)
- `tsan` job (`.github/workflows/e2e-test.yml`) は `SoraTests` 全体を対象とし race report 0 件を gate にしている。この job は `push` と `workflow_dispatch` で実行され、`pull_request` では実行されない。検出は確率的で、同一 commit の再実行では成功する場合もある (`36986119037` の attempt 3 (job `110774268777`) は失敗、attempt 4 は成功)。develop の push でも実際に失敗しており (`36848156662` の attempt 2、`36990000719`)、検出時は job が落ちる。CI を安定させる必要があるため Medium とする
- 同種のデータ競合の修正である `0151` も Medium である

## 現状

`Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory` は `static let shared` のシングルトンで、`@unchecked Sendable` を付けて `simulcastEnabled` を無同期の可変プロパティとして保持している。`currentEncoderFactory` は `simulcastEnabled` を読んで `simulcastEncoderFactory` と `defaultEncoderFactory` のどちらを返すかを決める。

書き込みは `Sora/PeerChannel.swift` の 2 箇所である。`connect(handler:)` が `WrapperVideoEncoderFactory.shared.simulcastEnabled = snapshot.simulcastEnabled` を設定し、`handleSignalingOverWebSocket(_:)` が `type: offer` の受信時に `WrapperVideoEncoderFactory.shared.simulcastEnabled = simulcast` で上書きする。読み取りは、libwebrtc から呼ばれる `supportedCodecs()` / `createEncoder(_:)` と、`NativePeerChannelFactory.init` が codec log のために呼ぶ `supportedCodecs()` が `currentEncoderFactory` を経由して行う。

`tsan` job (`.github/workflows/e2e-test.yml`) の 2026-10-02 の実行 (run 36986119037 / job 110774268777) で、次のデータ競合が報告された。

- 書き込み: WebSocket の delegate スレッドの `PeerChannel.handleSignalingOverWebSocket(_:)` (size 1 の write)
- 読み取り: `SendrecvE2ETests.testSendrecvDummyVideo` の接続で `RTCPeerConnectionFactory` が生成したスレッドの `WrapperVideoEncoderFactory.supportedCodecs()` → `currentEncoderFactory.getter`

同じ競合は 2026-10-01 の develop の実行 (run 36848156662) でも報告されている。書き込み側の `handleSignalingOverWebSocket(_:)` は実 Sora 接続でしか呼ばれないため、`SORA_SIGNALING_URL` 未設定のローカルでは再現しない。

`simulcastEnabled` をシングルトンで共有していることによる「複数接続で設定が混線する」問題は `0026` (シングルトン使用箇所の設計を見直す) が扱う。`0026` は接続単位インスタンス化と `static let shared` の削除を主目的とし、Low のままである。`0026` の完了条件には「`simulcastEnabled` の read / write を初期化後不変にするか、同じ同期機構で保護する」が含まれ、その排他の部分を本 issue が先行して実装する。`0135` は本 issue と同じ `tsan` job の失敗を `0026` が扱うと記載しているが、`0026` の着手順序は未定であり、`tsan` job を緑にするには排他が必要である。`0026` が接続単位化する際は本 issue の排他を維持し、初期化後不変にできる場合は置き換える。シングルトンの要否は本 issue では変更しない。

接続単位インスタンスにしても、offer 受信時の書き込みを残す限りこの race は解消しない。`WrapperVideoEncoderFactory` を渡した `RTCPeerConnectionFactory` とそのスレッドは `NativePeerChannelFactory.init` (接続開始時) に生成され、`type: offer` の受信より前に存在するためである (接続の `RTCPeerConnection` 自体は offer 受信後の `createAndSendAnswer` で生成される)。`0026` は TODO コメントの要否確認で接続開始時の設定を対象としており、offer 受信時の設定は対象にしていない。offer 受信時の設定を削除して値を初期化後不変にする案は、この設定が `CHANGES.md` の 2024.3.0 の `[FIX]` (`type: offer` の `simulcast` の値が反映されない不具合への対応) で意図的に追加された挙動であり、削除すると同じ不具合に戻るため取れない。現行の仕様では値は初期化後に不変にできない。

## 設計方針

- `simulcastEnabled` の get / set を `NSLock` で排他する (backing store を持ち、get / set だけが lock を取る)。lock を保持したまま libwebrtc を呼ばない
- `currentEncoderFactory` は lock 付き getter を通して factory を選び、返した factory への呼び出し (`supportedCodecs()` / `createEncoder(_:)`) は lock の外で行う。lock を取得した区間の中で lock 付き getter / setter を呼ばない。非再帰の `NSLock` を再取得して self-deadlock するためであり、lock 区間で値が必要な場合は backing store を直接読む。この停止は `NativePeerChannelFactory.init` が codec log のために呼ぶ `supportedCodecs()` で MediaChannel の生成時に必ず踏む
- `defaultEncoderFactory` / `simulcastEncoderFactory` は `init` でしか代入しないため `let` にして「初期化後不変」を型で表す
- `WrapperVideoEncoderFactory` の宣言直前にある `@unchecked Sendable` の根拠コメント (「WebRTC のエンコーダーファクトリーを共有して扱うため、 @unchecked Sendable を付与します。」) を「WebRTC の non-Sendable object を保持するため + 可変状態は `simulcastEnabled` のみで lock が排他する」に更新する (`NativePeerChannelFactory` 側の同種コメントは対象外)
- シングルトンの解消 (接続単位インスタンス化) は `0026` の判断に委ね、本 issue では行わない

## 完了条件

- `simulcastEnabled` の read / write が同じ排他機構で保護されていること
- Thread Sanitizer を有効にした `SoraTests` の実行で `WrapperVideoEncoderFactory` を指す race report が出ないこと。書き込み側は実 Sora 接続でしか呼ばれずローカルでは再現しないため、判定は `tsan` job の artifact (`build/tsan-report.txt`) に `WrapperVideoEncoderFactory` を指す report が無いことで行う
- サイマルキャストあり / なしの映像送信の挙動が変わらないこと (既存テストがすべて成功すること)
- `CHANGES.md` の `## develop` の主リストの `[FIX]` の並び位置に「`WrapperVideoEncoderFactory.shared.simulcastEnabled` が無同期で読み書きされるデータ競合を解消する」を担当者行 (`- @ユーザー名`) 付きで追記していること

## 変更対象

- `Sora/NativePeerChannelFactory.swift`: `WrapperVideoEncoderFactory.simulcastEnabled` の排他、`defaultEncoderFactory` / `simulcastEncoderFactory` の `let` 化、`WrapperVideoEncoderFactory` の宣言直前にある `@unchecked Sendable` の根拠コメントの更新
- `SoraTests/ConcurrencyStressTests.swift`: `testVideoEncoderFactorySimulcastEnabledReadWriteRace` の追加 (実装中に追加。実 Sora 接続なしで読み書きの対を駆動できるため)
- `CHANGES.md`: `## develop` の主リストへの追記

## スコープ外

- `WrapperVideoEncoderFactory` の接続単位インスタンス化と `static let shared` の削除は `0026` で扱う
- `PeerChannel` の `rpcChannel` / `dataChannels` / `switchedToDataChannel` の競合は `0135` で扱う

## テスト方針

- deadlock の確認はローカルで行う。`supportedCodecs()` は `NativePeerChannelFactory.init` が codec log のために呼ぶため、`MediaChannel` を生成する既存 test (`LoggerCallUnderLockTests` / `CameraStateOwnerTests` など) が hang せずに成功することで lock の再取得が無いことを確認できる
- `0119` の手順 (`-enableThreadSanitizer YES` の `build-for-testing` + `simctl spawn`) で `SoraTests` 全件を実行する。ローカルでは `SORA_SIGNALING_URL` 未設定で E2E が skip され race を再現しないため、これは回帰 (他の競合を増やしていないこと) の確認である
- race の判定は `tsan` job の artifact (`build/tsan-report.txt`) に `WrapperVideoEncoderFactory` を指す report が無いことで行う。`0135` の競合が同時に残っている間は job 全体が失敗し得るため、job の成否ではなく report の内容で判定する
- `createEncoder(_:)` は libwebrtc から呼ばれるため、`SimulcastE2ETests.testSimulcastDummyVideo` / `SendrecvE2ETests.testSendrecvDummyVideo` が実 Sora 接続で成功することを確認する (ローカルでは skip される)

## 解決方法

### 修正内容

`Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory.simulcastEnabled` を `NSLock` で排他し、`defaultEncoderFactory` / `simulcastEncoderFactory` を `let` にした。公開 API は変更していない。

- `simulcastEnabled` を、lock 保護の確定値 `storedSimulcastEnabled` (private) を持つ computed property にした。代入する側 (`PeerChannel.connect` と `PeerChannel.handleSignalingOverWebSocket`) は同じ setter を通るため変更していない
  - 書き: `PeerChannel.connect(handler:)` と `type: offer` 受信時の 2 箇所
  - 読み: libwebrtc が呼ぶ `createEncoder(_:)` / `supportedCodecs()` (`currentEncoderFactory` 経由) と、`NativePeerChannelFactory.init` の codec log
- lock を取得するのは `simulcastEnabled` の getter / setter だけにした。lock を取得した区間の中では lock 付きの getter / setter を呼ばず確定値を直接読む。非再帰の `NSLock` を再取得して self-deadlock するためであり、`Sora/Logger.swift` の `LoggerStateStorage` と同じ形である
- `currentEncoderFactory` は lock 付き getter を通して factory を選び、返した factory への呼び出し (`supportedCodecs()` / `createEncoder(_:)`) は lock の外で行う。lock を保持したまま libwebrtc を呼ばない
- `defaultEncoderFactory` / `simulcastEncoderFactory` は `init` でしか代入しないため `let` にした。`@unchecked Sendable` の根拠コメントは「この型自身の可変状態は `simulcastEnabled` だけで、その読み書きは lock が排他する (保持する factory の内部状態の thread safety は主張しない)」に限定した
- シングルトン (`static let shared`) と接続単位インスタンス化は変更していない (「スコープ外」のとおり `0026` で扱う)

### 選んだ排他方式

- `NSLock` + 確定値の backing store は、同じく排他が必要な可変状態を持つ既存実装 (`Sora/Logger.swift` の `LoggerStateStorage` / `Sora/MediaStream.swift` の `enabledLock` / `Sora/HandlerStorage.swift`) と同じ形にした
- `Sora/HandlerStorage.swift` の共通 storage は再利用していない。同 storage は「SDK 内部の lock 付きアクセサに閉じ、concurrency domain へ渡さない」ことを契約にしており、`WrapperVideoEncoderFactory` は `RTCPeerConnectionFactory` へ渡って libwebrtc のスレッドから呼ばれる型のため契約に反する
- 値を初期化後不変にする案 (`type: offer` 受信時の設定を削除する) は取らない。この設定は `CHANGES.md` の 2024.3.0 の `[FIX]` (`type: offer` の `simulcast` の値が反映されない不具合への対応) で意図的に追加された挙動であり、削除すると同じ不具合に戻る
- lock 順序: 本 lock は保持したまま他の lock を取らず、他の lock を保持したまま取られる経路も無い (葉 lock)。`PeerChannel` の書き込み 2 箇所はどちらも他の lock を保持していない

### テスト

`SoraTests/ConcurrencyStressTests.swift` に `testVideoEncoderFactorySimulcastEnabledReadWriteRace` を追加した。モックやスタブは使わず、実 `WrapperVideoEncoderFactory.shared` を使う。

- 書き込み (接続開始時と `type: offer` 受信時の書き換えに相当) と `supportedCodecs()` 経由の `currentEncoderFactory` の読み取りを、`DispatchQueue.concurrentPerform` で 64 スレッド × 8 ラウンド交差させる
- 書き込み側の `type: offer` は実 Sora 接続でしか起きないため、setter を直接呼んで読み書きの対をローカルで駆動する
- 交差は test 自身が駆動するため、通常の実行ではデータ競合の発生 (TSan の報告) を観測できない。検出は TSan を有効にした実行に依存し、通常の実行では並行区間の後に設定値に対応する factory が選ばれることを検証する
- プロセス全体で共有される singleton のため、開始値を `defer` で元に戻す
- `createEncoder(_:)` 経路の交差は行っていない。`supportedCodecs()` と同じ `currentEncoderFactory` を通るため排他の検証にはならず、実 encoder の生成はコストが高いため
- 追加した test は `CHANGES.md` の `### misc` に記録していない。変更に付随する test 追加にエントリを足さない既存の運用 (`0154` の test 追加コミット) に合わせた

### 検証結果

- 通常 test (ローカル、`SORA_SIGNALING_URL` 未設定): `Executed 473 tests, with 36 tests skipped and 0 failures` (exit 0)
- Thread Sanitizer を有効にした全件実行 (ローカル): `***** Running under ThreadSanitizer` あり、473 件 / skip 36 / 失敗 0、`WARNING: ThreadSanitizer` 0 行、exit 0。追加した test を 30 回反復しても 30 件すべて pass、report 0 件
- 退行検出 (negative control): lock の取得を外した版 (patch は `build/0185-negative-control.patch`) で同じ test を TSan で実行すると、`WrapperVideoEncoderFactory.simulcastEnabled.getter` / `setter` を指す race を報告してプロセスが abort した (exit 134)。lock を戻すと同じ test が成功する
- CI の `tsan` job: run [37003610700](https://github.com/shiguredo/sora-ios-sdk/actions/runs/37003610700) / job `110826671366` が成功。`***** Running under ThreadSanitizer v3` あり、`Executed 473 tests, with 7 tests skipped and 0 failures`、`TSan report count: 0`。skip は 7 件で、実 Sora 接続の E2E (`SendrecvE2ETests.testSendrecvDummyVideo` / `SimulcastE2ETests.testSimulcastDummyVideo`) が実行された状態で report 0 件だった。つまり本番の書き込み経路 (`handleSignalingOverWebSocket`) と libwebrtc 側の読み取りが動いた状態で、この競合は報告されていない
- `make build` (`-warnings-as-errors`): `** BUILD SUCCEEDED **`
- `make fmt-lint`: 成功
- `swiftlint lint --strict`: `Found 0 violations, 0 serious in 68 files`
- `make api-check-fresh`: 公開 API の baseline と一致 (internal 型のため API 変更なし)
- `make consumer-check-negative`: 4 件が期待どおり compile に失敗
- 判定方法の補足: `tsan` job の artifact は job が失敗したときにだけ upload されるため、成功時の判定には使えない。実際の判定は job ログの 4 条件 (TSan が load されたこと、`Executed` の test 数が全件であること、`TSan report count: 0`、step の exit code) で行った。artifact だけを見て「report が無い」と判断すると、空 artifact や artifact 不在を 0 件と誤読し得る (workflow 側の改善は別途)
- 残: `0135` の `rpcChannel` の競合は未修正である。`tsan` job は検出時に失敗し得る (確率的) ため、本 issue の判定は job の成否ではなく report の内容で行った

### 変更履歴

`CHANGES.md` の `## develop` の主リストの `[FIX]` の並び位置に、担当者行付きで追記した。
