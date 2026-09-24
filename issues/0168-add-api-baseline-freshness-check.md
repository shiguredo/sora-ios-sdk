# 公開 API baseline が最新であることを検証する gate を追加する

- Created: 2026-09-24
- Completed:
- Priority: Medium
- Branch: feature/add-api-baseline-freshness-check
- Polished:

## 目的

commit 済みの公開 API baseline が現在の `Sora` module と一致していることを CI で検証し、公開 API の追加と baseline の更新忘れを検出できるようにする。

`0107` が追加した `make api-check` は `swift-api-digester -diagnose-sdk` による比較で、公開 API の削除・変更・準拠の削除を検出する。しかし `-diagnose-sdk` は**追加を報告しない**ため、公開 API を追加して baseline を再生成し忘れても CI は成功し、新しい API は baseline に現れないまま次の削除検出の基準がずれる。この状態を検出する手段が無い。

## 現状

- `.github/workflows/consumer-test.yml` は 26.6 leg で `make api-check` だけを呼び、baseline の鮮度は検査していない
- 実測: baseline から宣言を 1 件削った JSON (= `Sora` 側に API が追加された状態) に対して `swift-api-digester -diagnose-sdk` を実行すると、出力は空で exit 0 になる。baseline に無い宣言を足した JSON では `API breakage: … has been removed` が出力される
- 実測: `swift-api-digester -dump-sdk` の出力は再現する。2 回の dump がバイト一致し、`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` とも 1,741,873 byte で完全に一致した
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` は「`make api-check` では API の追加を検出できない。追加時は同じ変更で baseline を再生成する」という人手の規約を書いている。`0109` / `0110` / `0120` / `0152` は公開 API を追加する作業で、この規約だけに依存している
- `Makefile` には dump 直後の JSON を検証する `API_VALIDATE` (`ABIRoot.name` / `children` 数 / サイズ) がある

## 設計方針

- 26.6 leg (`matrix.api_check` が true の leg) でのみ実行する。baseline は dump に使った Xcode と SDK の module とだけ比較できるため、既存の `api-check` と同じ leg に置く
- `consumer-build` (既定の `ConsumerCore`, Release) を前提に、`swift-api-digester -dump-sdk` で fresh dump を `$(DERIVED_DATA_ABS)/api-baseline-fresh.json` に出力する。dump のオプションは `api-baseline` と同一 (`-avoid-location` / `-avoid-tool-args` / `-module-cache-path`) とし、絶対パスと実行情報を入れない
- fresh dump は `API_VALIDATE` で検証してから比較に使う (壊れた dump を比較に使わない)。fresh dump は毎回 `rm -f` してから書き出す (`api-baseline` と同じ理由)
- commit 済み `$(API_BASELINE)` と fresh dump を JSON の意味比較で比較する。`json.load` した値の `==` で比較し、整形や key 順の差では失敗させない。実測では byte 比較でも成立するが、環境による整形差を吸収できる意味比較を第一候補とする
- 差分がある場合は、宣言単位の差分を人が読める形でログに出し、「commit 済み baseline が現在の `Sora` module と一致しない。`make api-baseline` で再生成し、同じ変更に含める」と案内して exit 1 にする
- commit 済み baseline を書き換えない (`api-baseline` を CI から呼ばない) という既存の原則を維持する
- 既存の `api-check` は変更しない。役割は「`api-check` = 削除・変更・準拠の削除の検出 (breakage を報告する)」「`api-check-fresh` = baseline が現在の module と一致していることの検証」とする
- `Makefile` に `API_BASELINE_FRESH := $(DERIVED_DATA_ABS)/api-baseline-fresh.json` と `api-check-fresh: consumer-build` を追加し、`.PHONY` を更新する
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` の「追加は検出できない」記述を、2 つの target の役割分担に合わせて更新する

## スコープ外

- 公開 API の削除・変更・準拠の削除の検出と、その breakage メッセージの改善 (既存の `api-check` が担う)
- `make api-baseline` の生成手順と、Xcode を更新したときの baseline 再生成の運用 (既存の手順のまま)
- `Sora` 以外の module や SDK の baseline
- 追加された API の内容 (意図した API かどうか) のレビュー。本 issue は baseline と module の一致だけを検査する

## 変更対象

- `Makefile`: `API_BASELINE_FRESH` 変数と `api-check-fresh` target、`.PHONY` の更新
- `.github/workflows/consumer-test.yml`: `Check Public API Baseline` の後に `if: matrix.api_check` で `make api-check-fresh` を実行する step
- `TestConsumers/Swift6Consumer/README.md`: baseline の節と「追加は `make api-check` では検出できない」記述の更新
- `CODEBASE.md` (develop に既存): 鮮度検査の手順と `make api-baseline` を実行すべきタイミングの追記
- `issues/0107-*.md`: 「`-diagnose-sdk` の出力に API の追加は現れない」記述の更新

## テスト方針

モックやスタブは使用しない。実際の `Sora` module と baseline で検証する。

- `Sora` に公開 API を一時的に追加し、baseline を再生成しない状態で `make api-check-fresh` が exit 1 になり、`make api-baseline` の実行を案内することを確認する
- 確認のための一時変更は 1 コミットとして push して CI run の URL を控え、`git revert` の打ち消しコミットを同じ PR に追加する (`git reset` と force push は行わない)
- `make api-baseline` で再生成した状態では `make api-check` と `make api-check-fresh` の両方が成功することを確認する

## 完了条件

- `make api-check-fresh` が 26.6 leg で実行され、commit 済み baseline が現在の `Sora` module と一致していることを検査すること
- `Sora` に公開 API を一時的に追加して baseline を再生成しない場合に `make api-check-fresh` が exit 1 になり、baseline の再生成を案内すること (その CI run の URL が PR 本文にあること)
- `make api-check-fresh` が commit 済み baseline を書き換えないこと (CI が `api-baseline` を呼ばないこと)
- fresh dump が `API_VALIDATE` を通らない場合は、比較の前に失敗すること
- `make api-check` (削除・変更の検出) の挙動と出力が変わっていないこと
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` に、2 つの target の役割分担と「API を追加する変更では同じ変更で baseline を再生成する」手順が書かれていること

## 解決方法
