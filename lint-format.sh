#!/bin/sh

# ローカルで lint と formatter を実行するスクリプト
# 未フォーマットか lint でルール違反を検出したら終了ステータス 1 を返す
# GitHub Actions では未フォーマット箇所の有無の確認に使う

PODS_ROOT=Pods
SRCROOT=.
LINT=${PODS_ROOT}/SwiftLint/swiftlint

# フォーマットリントは未フォーマットでもステータスコード 0 を返すので
# ステータスコードチェックを行わない
swift format lint -r Sora SoraTests
swift format -i -r Sora SoraTests

$LINT --fix $SRCROOT
$LINT --strict $SRCROOT
lint=$?

test $lint -eq 0
exit $?