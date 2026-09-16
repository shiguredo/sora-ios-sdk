# Sora.connect の設定エラー通知経路の non-Sendable closure capture を解消する

- Created: 2026-09-15
- Completed:
- Priority: Low
- Branch: feature/refactor-connect-error-closure-capture
- Polished: 2026-09-16

## 目的

`Sora.connect` の設定エラー通知経路が非 `@Sendable` な接続 handler を `DispatchQueue.async` へ capture しており、Swift 6 言語モードで `#SendableClosureCaptures` 警告が出る。警告を解消し、strict concurrency と warnings-as-errors のゲートへ近づける。

## 現状

`Sora/Sora.swift` の `Sora.connect` は、接続設定の snapshot 生成または `MediaChannel` の生成に失敗した場合（設定エラーや ADM 初期化エラー）、既存の設定エラー経路で `ConnectionTask.complete()` の後に `DispatchQueue.global().async` の中で接続 handler と `Sora.handlers.onConnect` を呼ぶ。

この closure は `@escaping` だが `@Sendable` ではない接続 handler を capture するため、`SWIFT_VERSION=6` で `#SendableClosureCaptures` 警告が出る。既存の `SignalingQueueBlock` は `Sora/SignalingState.swift` の private 型であり、別ファイルから流用できない。

## 設計方針

- documented な `@unchecked Sendable` box を `Sora/Sora.swift` に新設し、接続 handler を包んで投入する。box の安全性の根拠をコメントに書く。
- 通知順序 (`ConnectionTask.complete()` → handler → `Sora.handlers.onConnect`) と executor を変更しない。
- 公開 API のシグネチャを変更しない。
- `0110` の event API と `0111` の `SoraHandlers` 同期方針と矛盾しないことを確認する。

## 前提となる issue

- `0102`: `Sora.connect` の設定 snapshot 生成経路。`Sora.connect` と設定エラー通知経路を扱うため、本 issue は `0102` の完了後に着手する。
- `0118`: test target の strict concurrency ゲート。

## 完了条件

- 当該経路の `#SendableClosureCaptures` 警告が消えていること。
- 設定エラー時の通知順序と executor が変わらないこと。
- 公開 API のシグネチャが変更されていないこと。
- `CHANGES.md` に追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
