# 公開 API baseline が最新であることを検証する gate を追加する

- Created: 2026-09-24
- Completed:
- Priority: Medium
- Branch: feature/add-api-baseline-freshness-check
- Polished: 2026-09-24

## 目的

commit 済みの公開 API baseline が現在の `Sora` module と一致していることを CI で検証し、公開 API を追加したまま baseline を再生成し忘れた状態を検出できるようにする。

`0107` が追加した `make api-check` の `swift-api-digester -diagnose-sdk` は公開 API の削除・変更・準拠の削除を検出するが追加を報告しない。このため追加と再生成漏れは人手の規約でしか防げておらず、検出する手段が無い。

## 現状

- `.github/workflows/consumer-test.yml` の `swift6-consumer` job は 26.2 leg (`api_check: false`) と 26.6 leg (`api_check: true`) の 2 leg を持ち、API 関連では 26.6 leg の `Check Public API Baseline` step が `make api-check` を呼ぶだけである。baseline の鮮度は検査していない
- 実測 (Xcode 26.6 / `iphoneos26.5`): commit 済み baseline から宣言を 1 件削った JSON に対して `swift-api-digester -diagnose-sdk` を実行しても出力は空で exit 0 になる。`swift-api-digester -dump-sdk` の出力は同一 module と同一 toolchain で再現する
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` は「`make api-check` では API の追加を検出できない。追加時は同じ変更で baseline を再生成する」という人手の規約を書いている
- `Makefile` には dump 直後の JSON を検証する `API_VALIDATE` と、commit 済み baseline の生成情報 (`$(API_BASELINE_INFO)`) と実行環境の一致検査がある

## 前提となる issue

- `0169` の 1 leg 化 (26.2 leg と `api_check` フラグの削除) の前後どちらでも鮮度検査が実行されるようにするため、step は新設せず既存の `Check Public API Baseline` step の `run` を差し替える

## 設計方針

### api-check-fresh target

- `Makefile` に `API_BASELINE_FRESH` (build 配下の dump 先 `$(DERIVED_DATA_ABS)/api-baseline-fresh.json`) と `api-check-fresh` target を追加し、`.PHONY` に `api-check-fresh` を追加する
- `api-check-fresh: api-check` とし、既存 `api-check` の検査 (commit 済み baseline の存在確認、`API_VALIDATE`、実行環境の一致検査、削除・変更の検出) を再利用する。`api-check` のレシピと出力は変更しない
- target 固有 `export DEVELOPER_DIR` の対象に `api-check-fresh` も追加する。`api-check` に宣言した値は `api-check-fresh` 自身のレシピには効かないため、追加しないと `api-check-fresh` の `xcrun` が ambient な Xcode を使う
- `API_CHECK_FRESH_LOG` は `$(DERIVED_DATA_ABS)/api-check-fresh.log` とする。fresh dump の前に `rm -f "$(API_BASELINE_FRESH)"` と `rm -f "$(API_CHECK_FRESH_LOG)"` を行う
- fresh dump のオプションは `api-baseline` と同一とし、出力先 `-o` だけを `$(API_BASELINE_FRESH)` にする
- fresh dump は比較の前に `$(API_VALIDATE) "$(API_BASELINE_FRESH)"` で検証する

### 比較と差分

- commit 済み `$(API_BASELINE)` と fresh dump を `json.load` した値の `==` で比較する (整形や key 順の差では失敗させない)。`children` は JSON 配列で source の宣言順を保つため、並び順の差も検出する
- 差分がある場合は、まず宣言ノード (`declKind` を持つノード) を両方の JSON から再帰的に集め、`declKind` と `usr` を持つノードは `usr` を、`declKind` を持ち `usr` を持たないノード (実測では `Import`) は `(declKind, printedName)` を key として `printedName` 付きの対応表を作る。fresh dump にだけある key (追加) と commit 済み baseline にだけある key (削除) を一覧にする。`conformances` と `declKind` を持たない型参照ノードは `usr` が重複し `printedName` も異なるため使わない (実測で `usr` を持つ宣言ノードの `usr` は一意)。準拠の追加・削除だけの差分では一覧が空になり、行差分だけが出る
- 続けて `json.dumps(value, indent=2, sort_keys=True).splitlines()` の行差分を `'\n'.join(difflib.unified_diff(..., lineterm=""))` で出す。`sort_keys=True` では宣言自身の `name` が自分の children より後ろに来るため、行差分の先頭だけでは宣言を特定できない
- 行差分の全量は Python が `$(API_CHECK_FRESH_LOG)` に書き出し、標準出力には一覧と行差分の先頭 200 行、切り詰めた場合はその旨と総行数を出す。`tee` は使わない (log と標準出力が同一内容になり、全量と先頭 200 行を両立できない)
- Python は差分を検出した場合に終了コード 2、比較自体に失敗した場合 (file が読めない、`ABIRoot` が無い、log を書けないなど) に 1 を返す。レシピは `if python3 -c "$$API_BASELINE_DIFF" ...; then :; else status=$$?; ...; fi` の形にし、`else` の先頭で終了コードを退避してから分岐する。2 の場合だけ `make api-baseline` での再生成を案内し、それ以外の非 0 は「比較を実行できなかった」として別の英語メッセージを出す (AGENTS.md の「ログメッセージは全て英語」)。`else` の 2 つの分岐はどちらも最後に `exit 1` して recipe を失敗させる (`if` の分岐内の `echo` だけでは recipe の終了ステータスは 0 のままになり、gate が無言で成功する。`then` 側は `:` で成功させる)
- Python は `Makefile` 内で `define` して `export` し、レシピで `python3 -c "$$API_BASELINE_DIFF" "$(API_BASELINE)" "$(API_BASELINE_FRESH)" "$(API_CHECK_FRESH_LOG)"` として 3 引数 (commit 済み baseline、fresh dump、log) を渡す。`API_VALIDATE` は `=` と行継続で定義して `$(API_VALIDATE)` と直接展開する別方式であり、変更しない。`define` した値を `$(API_BASELINE_DIFF)` として直接展開すると改行がシェルの行区切りとして解釈されて失敗するため、`export` した環境変数を参照する。Python ソースの `$` は `$$` と書く (export 時に make が展開するため)。`"` はそのまま書いてよい
- `$(API_BASELINE_INFO)` は `xcodebuild -version` の 1 行目と `sdk` と `target` を記録するが Xcode の build 番号までは記録しない。build 番号だけが違う toolchain の差で dump が変わった場合も差分として失敗するので、`make api-baseline` で再生成して解消する
- commit 済み baseline を書き換えない (`api-baseline` を CI から呼ばない) という既存の原則を維持する

### 役割分担

- `api-check` = 削除・変更・準拠の削除の検出、`api-check-fresh` = baseline が現在の module と一致していることの検証 (追加を含むすべての差分を検出する)
- `0107` が定めた「CI が呼ぶ make target は `api-check` だけ」という現行ドキュメントの記述は本 issue で更新する (closed の `0107` のファイルは履歴として変更しない)
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` の検出範囲と「CI が呼ぶのは `api-check` だけ」という記述、README の公開 API baseline の target 一覧、`ApiBaseline/` の担当表を 2 つの target の役割分担に合わせて更新する。`CODEBASE.md` の baseline を更新する手順と Xcode を更新するときの手順に「再生成後に `make api-check-fresh` が成功することを確認する」を加え、baseline を更新する手順に「`children` は宣言順を保つため、公開 API を変えない並べ替えでも再生成が必要になる」を加える。更新後の README と `CODEBASE.md` に issue 番号を書かない
- `Makefile` の `api-check` 直前のコメント「CI が呼ぶ唯一の API target」を 2 target の役割に合わせて更新する

### GitHub Actions

- `Check Public API Baseline` step の `run` を `make api-check-fresh XCODE=${{ matrix.xcode }} XCODE_SDK=${{ matrix.sdk }}` に変える。step 名と `if: matrix.api_check` は変えず、`0169` が行う `if` の削除に委ねる (`0169` 完了後に適用する場合は `if` を追加しない)。他の step と matrix は変更しない

## スコープ外

- 公開 API の削除・変更・準拠の削除の検出と breakage メッセージの改善 (既存の `api-check` が担う)
- `make api-baseline` の生成手順と、Xcode を更新したときの baseline 再生成の運用
- `api-baseline` のレシピの共通化
- 公開 API を追加する各 issue の完了条件の更新 (再生成漏れは本 issue の gate が検出する)
- `Sora` 以外の module や SDK の baseline

## 変更対象

- `Makefile`: `API_BASELINE_FRESH` / `API_CHECK_FRESH_LOG` / `API_BASELINE_DIFF`、`api-check-fresh` target、`.PHONY`、target 固有 `export DEVELOPER_DIR`、`api-check` 直前のコメント
- `.github/workflows/consumer-test.yml`: `Check Public API Baseline` step の `run` のみ
- `TestConsumers/Swift6Consumer/README.md`: 冒頭の検出範囲の箇条書き、「追加は `make api-check` では検出できない」記述、CI が呼ぶ target、公開 API baseline の target 一覧、`ApiBaseline/` の担当表
- `CODEBASE.md`: Makefile の target 表、CI が呼ぶ target、検出範囲、baseline を更新する手順と Xcode を更新するときの手順
- `CHANGES.md`: `## develop` の `### misc` に種別順 (CHANGE → ADD → UPDATE → FIX) の位置で `[ADD]` を担当者行付きで追記する

## テスト方針

モックやスタブは使用しない。実際の `Sora` module と baseline で検証する。

- `Sora` に新しい公開型を 1 つ一時的に追加する (空の `public enum` など)。この状態では `make api-check` は exit 0 のまま (追加は `-diagnose-sdk` では検出されない) で、`make api-check-fresh` は差分を検出して失敗し、追加した型の名前が一覧に現れ、`make api-baseline` の実行を案内する
- 一時変更は 1 コミットとして push し、失敗した CI run の URL を控えてから `git revert` の打ち消しコミットを同じ PR に追加する (`git reset` と force push は行わない)
- `make api-baseline` で再生成した状態では `make api-check` と `make api-check-fresh` の両方が成功する
- `$(API_BASELINE_INFO)` の `sdk` を実行環境と異なる値に一時的に書き換え、`make api-check-fresh` が比較の前に環境一致検査で失敗することを確認し、`git checkout --` で元に戻す
- `make api-check-fresh` のレシピの先頭に一時的に `@echo "DEVELOPER_DIR=$$DEVELOPER_DIR"` を足し、`XCODE` で指定した Xcode が表示されることを確認して元に戻す
- fresh dump の `-module` を一時的に存在しない module 名に変え、`make api-check-fresh` が差分の表示ではなく `API_VALIDATE` の失敗で停止することを確認して元に戻す
- `Sora` の source の import を 1 つ一時的に別の module に変え、`make api-check-fresh` の一覧に import の追加と削除が現れることを確認して元に戻す (`usr` を持たない宣言ノードの一覧の確認)
- `grep -E '"/(Users|Applications|usr|private)/' "$(API_BASELINE_FRESH)"` が空であること (fresh dump に絶対パスが含まれないこと) を確認する
- `make api-check-fresh` の前後で `git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること、`git status --short` で一時変更 (`Sora` / `Makefile`) が残っていないことを確認する
- 一時変更を revert した後、commit 済み baseline のまま 26.6 leg の鮮度検査が成功する (CI ランナーでも dump が再現する)

## 完了条件

- `make api-check-fresh` が 26.6 leg (`0169` 完了後は唯一の leg) で skip されずに実行され、commit 済み baseline が現在の `Sora` module と一致していることを検査すること
- `Sora` に公開 API を一時的に追加して baseline を再生成しない場合に `make api-check-fresh` が失敗し、追加した宣言が一覧に現れ、`make api-baseline` での再生成を案内すること (その CI run の URL が PR 本文にあること)
- `make api-check-fresh` が commit 済み baseline を書き換えないこと (CI が `api-baseline` を呼ばないこと)
- fresh dump が比較の前に `API_VALIDATE` で検証され、絶対パスと実行情報を含まないこと
- `make api-check` が削除・変更を検出する既存の挙動と出力を保っていること
- `make api-check-fresh XCODE=...` の `xcrun` が `XCODE` で指定した Xcode を使うこと
- `Check Public API Baseline` step の `run` 以外の CI 記述 (job / matrix / 他 step) が変わっていないこと
- `TestConsumers/Swift6Consumer/README.md` と `CODEBASE.md` に 2 つの target の役割分担が書かれ、`CODEBASE.md` の baseline を更新する手順に再生成後の `make api-check-fresh` の確認が含まれること (更新後に issue 番号が無いこと)
- `CHANGES.md` の `## develop` の `### misc` に `[ADD]` が担当者行付きで追記されていること

## 解決方法
