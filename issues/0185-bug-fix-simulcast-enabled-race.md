# WrapperVideoEncoderFactory の simulcastEnabled が無同期で読み書きされるデータ競合を修正する

- Created: 2026-10-02
- Completed:
- Priority: Medium
- Branch: feature/fix-simulcast-enabled-race
- Polished:

## 目的

`WrapperVideoEncoderFactory` は `@unchecked Sendable` を宣言しているが、`simulcastEnabled` を無同期の可変プロパティとして保持しており、書き込みと libwebrtc のエンコーダースレッドの読み取りが排他されていない。データ競合 (未定義動作) をなくし、Thread Sanitizer (TSan) を有効にした CI の `tsan` job が race を報告しないようにする。

## 優先度根拠

- 単一接続の通常利用では実害が顕在化しにくい (書き込みは接続開始時と `type: offer` 受信時の 2 箇所で、`Bool` の load / store は arm64 では壊れた値を読まないことが多い)。`0026` も同じ理由で Low としている
- ただし `tsan` job は `SoraTests` 全体を対象とし race report 0 件を gate にしているため、この競合が残る限りすべての PR で job が失敗する。CI を復旧させる必要があるため Medium とする

## 現状

`Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory` は `static let shared` のシングルトンで、`@unchecked Sendable` を付けて `simulcastEnabled` を無同期の可変プロパティとして保持している。`currentEncoderFactory` は `simulcastEnabled` を読んで `simulcastEncoderFactory` と `defaultEncoderFactory` のどちらを返すかを決める。

書き込みは `Sora/PeerChannel.swift` の 2 箇所である。`connect(handler:)` が `WrapperVideoEncoderFactory.shared.simulcastEnabled = snapshot.simulcastEnabled` を設定し、`handleSignalingOverWebSocket(_:)` が `type: offer` の受信時に `WrapperVideoEncoderFactory.shared.simulcastEnabled = simulcast` で上書きする。読み取りは、libwebrtc から呼ばれる `supportedCodecs()` と `createEncoder(_:)` が `currentEncoderFactory` を経由して行う。

`tsan` job (`.github/workflows/e2e-test.yml`) の 2026-10-02 の実行 (run 36986119037 / job 110774268777) で、次のデータ競合が報告された。

- 書き込み: WebSocket の delegate スレッドの `PeerChannel.handleSignalingOverWebSocket(_:)` (size 1 の write)
- 読み取り: `SendrecvE2ETests.testSendrecvDummyVideo` が生成したエンコーダースレッドの `WrapperVideoEncoderFactory.supportedCodecs()` → `currentEncoderFactory.getter`

同じ競合は 2026-10-01 の develop の実行 (run 36848156662) でも報告されている。TSan の検出は確率的で、エンコーダーを使う test が実行される CI で再現する。

`simulcastEnabled` をシングルトンで共有していることによる「複数接続で設定が混線する」問題は `0026` (シングルトン使用箇所の設計を見直す) が扱う。本 issue はシングルトンの要否を変更せず、読み書きの排他だけを扱う。接続単位インスタンスにした場合も書き込み側と読み取り側は別スレッドであり続けるため、排他は必要である。

## 設計方針

- `simulcastEnabled` の get / set を `NSLock` で排他する。lock を保持したまま libwebrtc を呼ばない
- `currentEncoderFactory` は lock 区間で `simulcastEnabled` を読んでから factory を選び、返した factory への呼び出し (`supportedCodecs()` / `createEncoder(_:)`) は lock の外で行う
- `defaultEncoderFactory` / `simulcastEncoderFactory` は `init` でしか代入しないため `let` にして「初期化後不変」を型で表す
- `@unchecked Sendable` の根拠コメントを「WebRTC の non-Sendable object を保持するため + 可変状態は `simulcastEnabled` のみで lock が排他する」に更新する
- シングルトンの解消 (接続単位インスタンス化) は `0026` の判断に委ね、本 issue では行わない

## 完了条件

- `simulcastEnabled` の read / write が同じ排他機構で保護されていること
- Thread Sanitizer を有効にした `SoraTests` の実行で `WrapperVideoEncoderFactory` を指す race report が出ないこと
- サイマルキャストあり / なしの映像送信の挙動が変わらないこと (既存テストがすべて成功すること)
- `CHANGES.md` に追記していること

## テスト方針

- `0119` の手順 (`-enableThreadSanitizer YES` の `build-for-testing` + `simctl spawn`) で `SoraTests` 全件を実行し、`WARNING: ThreadSanitizer` が 0 行であることを確認する。`0135` の競合が同時に残っている間は job 全体が失敗し得るため、判定は report の内容で行う
- `SimulcastE2ETests` / `SendrecvE2ETests` が実 Sora 接続で成功することを確認する
- lock の追加による deadlock が無いことを、`createEncoder(_:)` を libwebrtc から呼ぶ経路で確認する

## 解決方法
