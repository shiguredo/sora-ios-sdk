# 対応する最低 Xcode を 26.6 に上げる

- Created: 2026-09-24
- Completed:
- Priority: Medium
- Branch: feature/change-raise-minimum-xcode
- Polished:

## 目的

対応する最低 Xcode を 26.6 に上げ、リポジトリ内の Xcode と SDK の pin を 1 つにそろえる。

現在は README のシステム条件と `build.yml` が Xcode 26.2 / `iphoneos26.2` を指し、`e2e-test.yml` の self-hosted ランナーと開発環境が Xcode 26.6 / `iphoneos26.5` を指している。`consumer-test.yml` はその両方を leg として持っているが、開発環境には Xcode 26.6 と `iphoneos26.5` しか無いため 26.2 の leg はローカルで再現できず、CI でしか確認できない構成になっている。最低要件を 26.6 に上げれば、この leg を削除して 1 つにそろえられる。

## 現状

- `README.md` のシステム条件は `Xcode 26.2`
- `.github/workflows/build.yml` の `build` job は `env.XCODE` / `env.XCODE_SDK` で 26.2 / `iphoneos26.2` を指定して SDK を build している
- `.github/workflows/consumer-test.yml` の matrix は 26.2 (`api_check: false`) と 26.6 (`api_check: true`) の 2 leg。26.2 leg は compile と負例だけ、26.6 leg は公開 API baseline の比較も行う
- `.github/workflows/e2e-test.yml` の `e2e` job は self-hosted ランナーの `/Applications/Xcode.app` (26.6) と `iphoneos26.5` を使っており変更は不要
- `TestConsumers/Swift6Consumer/ApiBaseline/` の baseline は Xcode 26.6 / `iphoneos26.5` で生成済みで、最低要件を 26.6 に上げても再生成は不要
- `0108` は `swift-tools-version` の上限を「README のシステム条件の Xcode 26.2 が読み取れる版」として選ぶ設計になっており、最低要件を上げると上限の根拠が変わる
- `0160` は Xcode 26.2 を現在のシステム条件として言及しており、本 issue の後に記述の整合を確認する必要がある

## 設計方針

- `README.md` のシステム条件を Xcode 26.6 に更新する (Swift 6 言語モードの記述はそのまま)
- `.github/workflows/build.yml` の `env.XCODE` / `env.XCODE_SDK` を 26.6 / `iphoneos26.5` に更新する
- `.github/workflows/consumer-test.yml` の matrix から 26.2 leg を削除して 26.6 の 1 leg にし、1 leg では不要になる `api_check` フラグと `Check Public API Baseline` step の `if` を削除する
- Xcode の版は引き続き明示的に pin する (「利用可能な最新 26.x」を動的に選ばない方針は維持)
- 26.2 の leg を削除することで失われる「最低要件で consumer として compile できること」の検証は行わない。SDK 本体が 26.2 で build できることの検証も本 issue で終了する (最低要件を 26.6 に上げるため)
- `0107` が実装中で 26.2 leg を完了条件に含む場合は、同じ変更で完了条件の該当箇所を 26.6 の 1 leg に合わせる

## スコープ外

- `swift-tools-version` の更新と Swift 6 language mode の適用は `0108` で扱う
- `.xcproj` から JSON 形式へのプロジェクト設定移行は `0160` で扱う
- self-hosted ランナーの Xcode 更新 (既に 26.6 のため対象外)
- 26.2 をサポートし続ける場合の matrix 化は本 issue では行わない

## 変更対象

- `README.md`: システム条件の Xcode の版
- `.github/workflows/build.yml`: `env.XCODE` / `env.XCODE_SDK`
- `.github/workflows/consumer-test.yml`: matrix を 26.6 の 1 leg にし、`api_check` フラグと step の `if` を削除
- `Makefile`: `build` target の `-sdk` を `iphoneos26.5` に更新する (`0107` で `iphoneos26.2` に修正済み。SDK の pin を 1 つにするにはここも追随させる)
- `CHANGES.md`: 対応環境の引き上げなので `## develop` の `[CHANGE]` に担当者行付きで追記する
- `issues/0107-*.md` (実装中の場合のみ): 完了条件の 26.2 leg の記述

## 完了条件

- README のシステム条件が Xcode 26.6 になっていること
- `build.yml` と `consumer-test.yml` と `Makefile` の `build` target の Xcode / SDK が 26.6 / `iphoneos26.5` にそろっていること
- `consumer-test.yml` が 1 leg で、compile、負例、deprecation 検査、公開 API baseline の比較が成功すること
- 26.2 を前提とした記述が残っていないこと (過去の issue と `CHANGES.md` の履歴は除く)
- `0108` の `swift-tools-version` の上限の根拠と `0160` の記述を本 issue に合わせて見直すことになっていること

## 解決方法
