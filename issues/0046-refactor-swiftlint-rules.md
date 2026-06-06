# SwiftLint ルールを見直す

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/refactor-swiftlint-rules
- Polished:

## 概要

SwiftLint のルール設定を見直し、CI でビルドエラーになったが Lint で検知できなかったケースを Lint で検知できるようにルールを追加・整備する。

## 背景

現在の SwiftLint 設定では、CI のビルドでエラーになるケースが Lint で事前に検知できないことがある。ルールを追加することで開発中に問題を早期発見できるようにする。

## 対応方針

- 直近で CI ビルドエラーになったが Lint で検知できなかったケースを洗い出す
- 対象ケースを検知できる SwiftLint ルールを調査する（`opt-in` ルールを含む）
- 全ルール有効化（`only_rules` や広範な `opt-in` 指定）から不要なルールを無効化していく戦略を検討する
- Swift 6 移行に伴う Lint 設定の変化についても確認しておく

## 根拠

Lint で事前検知できる問題が CI まで流れることは開発効率の低下につながる。ルールの整備はコード品質の継続的な担保に直結する。
