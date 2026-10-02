# WrapperVideoEncoderFactory の simulcastEnabled が無同期で読み書きされるデータ競合を修正する

- Created: 2026-10-02
- Completed:
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
