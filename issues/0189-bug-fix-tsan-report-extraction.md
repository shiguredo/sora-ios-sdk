# tsan job の TSan report 抽出が不正なバイト列で失敗し artifact が空になる問題を修正する

- Created: 2026-10-14
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/fix-tsan-report-extraction
- Polished: {YYYY-MM-DD}

## 目的

TSan が報告を出したときに、その report を artifact へ確実に残す。あわせて、抽出の失敗が job の失敗理由を上書きしないようにする。

## 優先度根拠

report の artifact が空だと、失敗した run の triage が job log 全体の目視に頼ることになる。workflow は「接続情報を含む通常の log を artifact へ持ち出さない」方針で report だけを保存しているため、report が残らないと安全に共有できる証跡が無くなる。抽出の失敗が exit code を上書きするため、失敗理由の切り分けにも時間がかかる。

## 現状

- `.github/workflows/e2e-test.yml` の `Run Thread Sanitizer Tests` step は、`awk` で `WARNING: ThreadSanitizer` の行から `==================` の行までを `build/tsan-report.txt` へ抜き出し、その行数を `TSAN_REPORT_COUNT` として後続の `Check Thread Sanitizer Report` step へ渡している。
- run 38511195252 (https://github.com/shiguredo/sora-ios-sdk/actions/runs/38511195252) では `awk: towc: multibyte conversion failure on: '...Test Case ...'` が出て `awk` が exit 2 になり、`set -e` により step 全体が exit 2 で終了した。`Process completed with exit code 2.` となり、TSan の exit 134 ではなく `awk` の失敗が step の失敗理由になった。
- このとき `build/tsan-report.txt` は空のまま `Upload TSan Report` step で artifact 化され、zip は 146 bytes (空 file) だった。同じ現象は run 37915949613 (https://github.com/shiguredo/sora-ios-sdk/actions/runs/37915949613) でも発生し、報告を出した失敗 run 3 件すべてで artifact が空だった。
- `awk` が失敗した時点で step が終了するため、`TSAN_REPORT_COUNT` を `GITHUB_ENV` へ書く行に到達せず、`Check Thread Sanitizer Report` step は skip される。
- 原因は log に現れる不正なバイト列である。simulator と xctest の出力が交錯してマルチバイト文字が分断され、UTF-8 として解釈できないバイト列が `build/tsan.log` に残る。macOS の `awk` は UTF-8 locale でこの行に当たると `towc` で失敗する。
- この欠陥は TSan の報告内容に依存しない。報告が 0 件の run でも不正なバイト列があれば同じ失敗をする。

## 設計方針

- 抽出は `LC_ALL=C` で行い、log をバイト列として扱う。`awk` を使い続ける場合も locale を固定する。
- 抽出の失敗で step を終了させない。抽出の成否と `tsan_exit_code` を分けて扱い、抽出に失敗した場合はその旨を出力したうえで step の失敗理由を TSan の exit code に保つ。
- report が 0 件のときは空の artifact を作らない (`Upload TSan Report` step の `if-no-files-found: ignore` を活かし、0 件なら file を作らない)。
- `Check Thread Sanitizer Report` step の判定 (report 行数 / banner / test 数 / exit code) は変更しない。

## 変更対象

- `.github/workflows/e2e-test.yml`: tsan job の `Run Thread Sanitizer Tests` step の report 抽出をバイト安全にし、抽出の失敗で step を終了させない。`Upload TSan Report` step は空 file を artifact として上げないようにする。

## テスト方針

- 不正なバイト列 (`\x80` など) を含む行を混ぜた log に対して抽出コマンドを実行し、exit 0 で完了することを確認する。
- report を含む log から抽出した内容が元の report と一致することを確認する。
- report が 0 件の log で空の artifact を作らないことを確認する。
- TSan 実行の exit code が抽出の失敗で上書きされないことを、報告を出した log を使って確認する。

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
