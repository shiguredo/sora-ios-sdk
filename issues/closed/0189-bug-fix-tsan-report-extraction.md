# tsan job の TSan report 抽出が不正なバイト列で失敗し artifact が空になる問題を修正する

- Created: 2026-10-14
- Completed: 2026-10-14
- Priority: Medium
- Branch: feature/fix-tsan-report-extraction
- Polished: 2026-10-14

## 目的

TSan が報告を出したときに、その report を artifact へ確実に残す。あわせて、抽出の失敗が job の失敗理由を上書きしないようにする。

## 優先度根拠

report の artifact が空だと、失敗した run の triage が job log 全体の目視に頼ることになる。workflow は「接続情報を含む通常の log を artifact へ持ち出さない」方針で report だけを保存しているため、report が残らないと安全に共有できる証跡が無くなる。抽出の失敗が exit code を上書きするため、失敗理由の切り分けにも時間がかかる。

## 現状

- `.github/workflows/e2e-test.yml` の `Run Thread Sanitizer Tests` step は、`awk` で `WARNING: ThreadSanitizer` の行から `==================` の行までを `build/tsan-report.txt` へ抜き出し、`^WARNING: ThreadSanitizer` に一致する行数 (report の件数) を `TSAN_REPORT_COUNT` として後続の `Check Thread Sanitizer Report` step へ渡している。
- run 38511195252 (https://github.com/shiguredo/sora-ios-sdk/actions/runs/38511195252) では `awk: towc: multibyte conversion failure on: '...Test Case ...'` が出て `awk` が exit 2 になり、`set -e` により step 全体が exit 2 で終了した。`Process completed with exit code 2.` となり、TSan の exit 134 ではなく `awk` の失敗が step の失敗理由になった。
- このとき `build/tsan-report.txt` は空のまま `Upload TSan Report` step で artifact 化され、zip は 146 bytes (空 file) だった。同じ現象は run 37915949613 (https://github.com/shiguredo/sora-ios-sdk/actions/runs/37915949613) でも発生した。
- artifact が残っている失敗 run は 38511195252 / 37915949613 / 38504592116 の 3 件で、いずれも 146 bytes (中身 0 bytes) である (他の失敗 run 36848156662 / 36670380572 の artifact は現存しない)。このうち TSan が report を出したのは 38511195252 だけで、抽出が report の位置に到達する前に失敗して report が失われた。37915949613 は report 0 件のまま抽出が失敗し、38504592116 は抽出に成功したが report 0 件だった (report 0 件でも `awk ... > "$REPORT_PATH"` は空 file を作るため artifact が作られる)。
- `awk` が失敗した時点で step が終了するため、`TSAN_REPORT_COUNT` を `GITHUB_ENV` へ書く行に到達せず、`Check Thread Sanitizer Report` step は skip される。
- 原因は log に現れる不正なバイト列である。simulator と xctest の出力が交錯してマルチバイト文字が分断され、UTF-8 として解釈できないバイト列が `build/tsan.log` に残る。macOS の `awk` は UTF-8 locale でこの行に当たると `towc` で失敗する。
- この欠陥は TSan の報告内容に依存しない。報告が 0 件の run でも不正なバイト列があれば同じ失敗をする。

## 設計方針

- 抽出は `LC_ALL=C` で行い、log をバイト列として扱う。`awk` を使い続ける場合も locale を固定する。
- 抽出の失敗で step を終了させない。抽出の成否と `tsan_exit_code` を分けて扱い、抽出に失敗した場合はその旨を出力する。`Run Thread Sanitizer Tests` step を TSan の exit code で exit させると `Check Thread Sanitizer Report` step が skip され、banner と test 数の判定が失われるため、job の失敗理由は `Check Thread Sanitizer Report` step の判定に残す。TSan の exit code が非 0 の場合はその step の exit code 検査で失敗させる。
- report が 0 件のときは空の artifact を作らない (`Upload TSan Report` step の `if-no-files-found: ignore` を活かし、0 件なら file を作らない)。
- `Check Thread Sanitizer Report` step の判定 (report 行数 / banner / test 数 / exit code) は変更しない。

## 変更対象

- `.github/workflows/e2e-test.yml`: tsan job の `Run Thread Sanitizer Tests` step の report 抽出をバイト安全にし、抽出の失敗で step を終了させず、report が 0 件のときは `build/tsan-report.txt` を作らない。`Upload TSan Report` step は変更しない (`if-no-files-found: ignore` が file の無いときに artifact を作らない設定として働く)。

## テスト方針

- 不正なバイト列 (`\x80` など) を含む行を混ぜた log に対して抽出コマンドを実行し、exit 0 で完了することを確認する。
- report を含む log から抽出した内容が元の report と一致することを確認する。
- report が 0 件の log で空の artifact を作らないことを確認する。
- 抽出の失敗が TSan 実行の exit code を上書きしないことを、report ブロックと不正なバイト列を含む log を使って確認する (run 38511195252 の `build/tsan.log` は runner 上に残らず、job log では不正なバイト列が置換されているため、確認用の log は report ブロックと不正なバイト列から用意する)。

## 完了条件

- 不正なバイト列を含む log でも抽出が exit 0 で完了し、report が欠けない。
- TSan の報告が出た run で artifact に report が入る。
- 抽出の失敗が TSan の exit code を上書きしない。
- 報告が 0 件のときに空の artifact が作られない。

## 前提となる issue

- `0119` (完了): tsan job と report の抽出を追加した。本件はその抽出処理の修正である。

## スコープ外

- thread leak で tsan job が失敗する件は `0188` で扱う。
- tsan job 内で走る E2E テストのフレーキーは別問題とする。

## 解決方法

`.github/workflows/e2e-test.yml` の `Run Thread Sanitizer Tests` step の report 抽出を、log をバイト列として扱う形に直した。`Check Thread Sanitizer Report` step の判定と `Upload TSan Report` step の設定は変更していない。

- step の `env` に `EXTRACT_PATH` (`build/tsan-report.extract.txt`) を追加し、report は一度この file へ抽出する
- 抽出の `awk` を `LC_ALL=C awk` にした。simulator と xctest の出力が交錯した log に残る不正なバイト列を、UTF-8 locale の `awk` が `towc` で変換しようとして exit 2 になっていたためである
- 抽出の失敗で step を終了させないようにした (`|| EXTRACT_STATUS=$?` で受けて理由を出力する)。Run step を TSan の exit code で終了させると `Check Thread Sanitizer Report` step が skip され banner と test 数の判定が失われるため、失敗条件の判定は Check step に残している
- report の件数を `LC_ALL=C grep -c` で数え、0 件のときは `REPORT_PATH` も `EXTRACT_PATH` も作らない。`Upload TSan Report` step の `if-no-files-found: ignore` は変更せず、file が無ければ artifact を作らない

検証:

- 修正前後の step script (修正後は実 YAML から、修正前は `git show HEAD:.github/workflows/e2e-test.yml` から取り出した) を、実 CI の job log から復元した `build/tsan.log` (job log では不正なバイト列が U+FFFD に置換されているため、同じ位置に生のバイト列を戻したもの) に対して実行した。TSan の実行は手元で再現できないため、記録した exit code を返す 1 行に置き換えている
- 不正なバイト列を含む log で抽出が exit 0 で完了し、抽出した report が元の report と一致した (report あり / 0 件の両方)
- report が 0 件の log で `build/tsan-report.txt` を作らないことを確認した
- 抽出の書き込み先を使えない状態にした場合も Run step は exit 0 のままで、`Check Thread Sanitizer Report` step が「TSan 実行の exit code が 134 です」で失敗した (抽出の失敗が TSan の exit code を上書きしない)
- negative control: 修正前の script では report の有無にかかわらず Run step が `awk: towc: multibyte conversion failure` で exit 2、`Check Thread Sanitizer Report` step は skip、`build/tsan-report.txt` は 0 bytes になり、CI で観測した失敗が再現した。修正後は再現しない
- 実 CI (2026-10-14、run 38531719370): `tsan` job が success になった (`Run Thread Sanitizer Tests` success / `Check Thread Sanitizer Report` success / `Upload TSan Report` skipped)。artifact `tsan-report` は作られず、log は `TSan report count: 0`、`Executed tests: 521`、`Thread Sanitizer: no data race detected (521 tests)` である
- `prek` の pre-commit フックが通り、`bash -n` で抽出 script の構文が通ることを確認した

残った懸念:

- TSan が実際に report を出した run で artifact に report が入ることは、検出が確率的なため実 CI では未確認である。抽出した内容が元の report と一致することと、report 0 件で file を作らないことはローカルで確認している
