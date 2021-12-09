#!/bin/sh

# ローカルで lint と formatter を実行するスクリプト
# 未フォーマットか lint でルール違反を検出したら終了ステータス 1 を返す
# GitHub Actions では未フォーマット箇所の有無の確認に使う

PODS_ROOT=Pods
SRCROOT=.
FORMAT=${PODS_ROOT}/SwiftFormat/CommandLineTool/swiftformat
LINT=${PODS_ROOT}/SwiftLint/swiftlint

# フォーマットの必要性を確認する
$FORMAT --lint $SRCROOT
format=$?

$FORMAT $SRCROOT
$LINT --fix $SRCROOT
$LINT --strict $SRCROOT
lint=$?

test $format -eq 0 -a $lint -eq 0
exit $?