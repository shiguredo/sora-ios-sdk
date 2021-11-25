#!/bin/sh

# ローカルで lint と formatter を実行するスクリプト
# すでにフォーマット済みであれば終了ステータス 1 を返す
# GitHub Actions では未フォーマット箇所の有無の確認に使う

PODS_ROOT=Pods
SRCROOT=.
FORMAT=${PODS_ROOT}/SwiftFormat/CommandLineTool/swiftformat
LINT=${PODS_ROOT}/SwiftLint/swiftlint

# フォーマットの必要性を確認する
# フォーマットの必要がなかったら終了ステータスを 1 にする
! $FORMAT --lint $SRCROOT
change=$?

$FORMAT $SRCROOT
$LINT --fix $SRCROOT
$LINT $SRCROOT

exit $change