# concurrency runtime stress CI を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-concurrency-runtime-ci
- Polished:

## 目的

compile-time の Sendable / actor isolation 検査だけでは検出できないデータ競合、callback の二重終端、stale event、teardown 競合を継続的に検出する runtime CI を追加する。

Thread Sanitizer と反復 stress test を補助的な gate とし、Swift 6 対応を「コンパイルできること」だけで完了扱いしない。

## 現状

`.github/workflows/build.yml` は SDK の Release build、`.github/workflows/ci.yml` は実 Sora を使う E2E test を実行するが、Thread Sanitizer を有効にした test job は存在しない。

`0092` から `0112` の concurrency 関連 issue は個別に Thread Sanitizer の実行を求めているが、共通の実行方法、対象 scenario、反復回数、artifact 保存、失敗時の切り分け方針がない。

## 設計方針

- Simulator で Thread Sanitizer を有効にした専用 job を追加する。
- 通常 CI と分離し、sanitizer の失敗と通常 test の失敗を識別できるようにする。
- connect / cancel / disconnect、redirect、RPC timeout / cancellation、DataChannel open / close、handler 交換、logger 設定変更を反復する。
- camera、ReplayKit、AudioUnit など Simulator だけで保証できない項目は実機 test のチェックリストと分離する。
- sanitizer を無効にしなければ通らない test を追加しない。
- race report、crash log、test result bundle を artifact として保存する。
- flaky test の単純 retry で race を隠さない。再現 seed、iteration、scenario をログへ残す。
- workflow では既存の GitHub 公式 action を利用し、不要な外部 action を追加しない。

## テスト方針

モックやスタブは使用しない。

- production の state reducer へ実際の event sequence を入力する test と、実 Sora 接続を利用する E2E stress test を使う。
- 同じ scenario を複数回反復し、順序を変えた場合も exactly-once と stale event rejection を確認する。
- Thread Sanitizer 無効時の通常 test と有効時の専用 test の両方を実行する。
- sanitizer job 自体に意図的な race を一時的に入れ、CI が検出できることを導入時に確認する。

## 完了条件

- Thread Sanitizer を有効にした専用 CI job が存在すること。
- concurrency 関連 scenario の反復方法と対象範囲が文書化されていること。
- race report と test result bundle が失敗時に取得できること。
- retry によって sanitizer failure を隠していないこと。
- Simulator 非対応の実機項目が別の検証条件として明記されていること。
- sanitizer CI と通常 CI が成功すること。

## 解決方法
