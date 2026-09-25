# concurrency runtime stress CI を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-concurrency-runtime-ci
- Polished: 2026-09-24

## 目的

compile-time の Sendable / actor isolation 検査だけでは検出できないデータ競合、callback の二重終端、stale event、teardown 競合を継続的に検出する runtime CI を追加する。

Thread Sanitizer と反復 stress test を補助的な gate とし、Swift 6 対応を「コンパイルできること」だけで完了扱いしない。

## 現状

`.github/workflows/build.yml` は SDK の Release build、`.github/workflows/e2e-test.yml` は実 Sora を使う E2E test を実行するが、Thread Sanitizer を有効にした test job は存在しない (workflow と Makefile と git 履歴のいずれにもない)。

`0092` から `0112` の concurrency 関連 issue のうち、race 修正と shared state / owner の整理を扱った `0092`、`0100`〜`0107`、`0111`、`0112` は、個別に Thread Sanitizer の実行または補助的な有効化を求めている。closed の `0102`〜`0107` と open の `0112`、`0154`、`0165` は実行時検証を本 issue の CI 基盤へ委ねている (例: `0107` は「Thread Sanitizer による runtime stress test は `0119` で扱う」と明記し、`0103` / `0104` / `0105` は「`0119` の基盤が利用可能になった時点で実行する」)。しかし、共通の実行方法、対象 scenario、反復回数、artifact 保存、失敗時の切り分け方針は定められていない。

ただし、現行 develop のテストに Thread Sanitizer を有効にすると完走しない。closed `0102` は、ユニットテストへの TSan 実行で `PeerChannel.onConnect` の data race (現在 open の `0151` が扱う) を検出し、サニタイザがテストプロセスを終了させたためスイートは完走しなかったことを記録している。`0103` / `0104` / `0105` も「`0151` が未完了の間は完走しない」「手動 TSan 実行は `0151` の競合で失敗する」と明記している。`DummyAudioDevice` の共有状態競合を扱った `0121` は修正済み (closed) で、この race によるノイズは解消されている。

## 前提となる issue

- `0151` (open): `PeerChannel.onConnect` のデータ競合の修正。本 issue の完了条件「sanitizer CI が成功すること」は、この修正が反映された状態を前提とする。
- `0121` (closed): `DummyAudioDevice` の共有状態競合の修正。本 issue の TS 実行がこの race によるノイズを出さない前提は整っている (`0121` も本 issue の TS 環境を参照している)。
- `0118` (open): E2E テストの concurrency 診断抑止の除去。本 issue が追加する E2E stress test は既存 E2E test と同じ `E2ETestBase` を共有するため、`0118` の実装が同じファイルを変更し得る。競合の調整は実装時に行い、本 issue の完了は `0118` を待たない。

## 設計方針

- `.github/workflows/e2e-test.yml` に、Simulator で Thread Sanitizer を有効にした専用 job を追加する。実 Sora 接続と Simulator の準備 (boot、`.xctestrun` への環境変数注入、system log 収集) を既に持つ唯一の workflow であり、job と step の失敗は通常の test job と識別できる。Runner と Simulator は既存の `e2e` job と揃える (self-hosted macOS ARM64、iPhone 17 Pro / OS 26.5)。
- 通常 CI と分離し、sanitizer の失敗と通常 test の失敗を識別できるようにする。
- connect / cancel / disconnect、redirect、RPC timeout / cancellation、DataChannel open / close、handler 交換、logger 設定変更を反復する。
- camera、ReplayKit、マイク入力など Simulator で保証できない項目は本 issue の対象から除外し、「スコープ外」に列挙して扱いを明示する。実機 test のチェックリストは本 issue で作らない。`DummyAudioDevice` の AudioUnit (RemoteIO) 再生経路は Simulator で実行できるため、この対象に含めない。
- sanitizer を無効にしなければ通らない test を追加しない。
- race report、crash log、test result bundle を artifact として保存する。
- flaky test の単純 retry で race を隠さない。再現 seed、iteration、scenario をログへ残す。
- workflow では GitHub 公式の action (`actions/*`) を利用し、利用実績のない外部 action を追加しない。

## スコープ外

- 実カメラ、ReplayKit、マイク入力など Simulator で保証できない項目の実行時検証。実機での検証手順と結果は、実機検証を目的とする issue が担う (closed `0134` が実例)。`DummyAudioDevice` の AudioUnit (RemoteIO) 再生経路は Simulator で実行できるため、この対象に含めない。
- 実機 test のチェックリストの作成。リポジトリに実機 test のチェックリストは存在しない (`0070` の「実機検証チェックリスト」はその issue 内の概念、closed `0103` の「実機チェックリスト」はレビュー時のもの) ため、本 issue の成果物にはしない。
- Address Sanitizer など Thread Sanitizer 以外の sanitizer の導入。

## 変更対象

- `.github/workflows/e2e-test.yml`: 専用 job の追加 (Simulator 準備、TSan を有効にした `xcodebuild test` (`-enableThreadSanitizer YES`、build を含む。`test-without-building` では interceptor が働かず race を検出できない)、`.xcresult` と race report の upload)。
- `SoraTests/`: state reducer へ実際の event sequence を入力する test と、実 Sora 接続を反復して検証する E2E stress test。反復方法と対象範囲は、テストのドキュメントコメントと workflow のコメントに記載する。

## テスト方針

モックやスタブは使用しない。

- production の state reducer へ実際の event sequence を入力する test と、実 Sora 接続を利用する E2E stress test を使う。
- 同じ scenario を複数回反復し、順序を変えた場合も exactly-once と stale event rejection を確認する。
- Thread Sanitizer 無効時の通常 test と有効時の専用 test の両方を実行する。
- TS 実行の対象に、`SoraTests/DummyStereoAudioLoopbackTests.swift` のテスト (テストスレッドの `terminateDevice` と ADM / timer callback の交差を再現する) と、`SoraTests/DummyAudioDeviceTests.swift` のテスト (生成器の並行利用) を含める。`SendonlyE2ETests` の切断後の終端状態の検証もテストスレッドから state を読むため対象になる。世代不一致での差し込み棄却と AudioUnit の巻き戻しは契約違反の呼び出しに対する防御で、契約が守られる限り実行されないため TS の検出対象ではない (検証するには production にテスト専用のフックが必要になる)。
- sanitizer job 自体に意図的な race を一時的に入れ、CI が検出できることを導入時に確認する。

## 完了条件

- Thread Sanitizer を有効にした専用 CI job が存在すること。
- concurrency 関連 scenario の反復方法と対象範囲が、専用 job の workflow コメントと `SoraTests/` のテストコメントに文書化されていること。
- race report と test result bundle が失敗時に取得できること。
- retry によって sanitizer failure を隠していないこと。
- Simulator 非対応の実機項目がスコープ外として明記されていること。
- 「前提となる issue」(`0151` / `0121`) の完了を前提として、sanitizer CI と通常 CI が成功すること。

## 解決方法
