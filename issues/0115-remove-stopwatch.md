# Utilities.Stopwatch を削除する

- Created: 2026-08-27
- Completed:
- Branch: feature/remove-stopwatch
- Polished:

## 目的

非推奨期間を完了した `Utilities.Stopwatch` を次期 major version で削除し、未使用かつ concurrency-safe でない一般 utility を SDK の保守対象から外す。

## 前提

- `0114` が完了し、公開 release で `Utilities.Stopwatch` の非推奨化と移行案内が提供されていること。
- 次期 major version の作業として着手すること。

上記を満たしていない場合は、本 issue に着手しない。

## 現状

`Sora/Utilities.swift` の `Utilities.Stopwatch` は SDK 内で利用されていない。

Timer lifecycle、retain cycle、再実行、executor 契約に問題があるが、Sora SDK 固有の機能ではないため、修正して公開 abstraction として維持するより削除する方が責務を明確にできる。

## 設計方針

- `Utilities.Stopwatch` の型定義を削除する。
- Stopwatch 専用の code、documentation、test、consumer fixture scenario を削除する。
- `Utilities.randomString`、`PairTable`、`Optional.unwrap` は変更しない。
- 代替 timer abstraction を SDK へ追加しない。
- API baseline を次期 major version の意図した破壊的変更として更新する。
- 利用者向け migration guide に、用途に応じて Foundation Timer、Swift Clock / Duration、アプリ側 timer を選択する旨を記載する。

## スコープ外

- `ConnectionTimer` は `0096` で扱う。
- `Utilities.swift` 内の他の API の整理は行わない。
- Swift concurrency 用の timer wrapper は追加しない。

## テスト方針

モックやスタブは使用しない。

- SDK と全 test target を clean build し、Stopwatch への残存参照がないことを確認する。
- `rg` で production code、test、documentation に `Stopwatch` の参照が残っていないことを確認する。
- API baseline が `Utilities.Stopwatch` の削除だけを意図した break として検出することを確認する。
- `Utilities` の残る API に対する既存テストを実行する。

## 完了条件

- `Utilities.Stopwatch` が削除されていること。
- production code、test、documentation に Stopwatch の参照が残っていないこと。
- 不要な代替 timer abstraction を追加していないこと。
- `Utilities` の他の API に意図しない変更がないこと。
- migration guide に代替方針が記載されていること。
- API baseline が意図した major change として更新されていること。
- 既存テストがすべて成功すること。

## 解決方法
