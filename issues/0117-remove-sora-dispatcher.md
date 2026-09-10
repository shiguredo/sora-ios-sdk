# SoraDispatcher を削除する

- Created: 2026-08-27
- Completed:
- Branch: feature/remove-sora-dispatcher
- Polished:

## 目的

非推奨期間を完了した `SoraDispatcher` を次期 major version で削除し、libwebrtc の内部 queue identity を SDK の公開 API から除去する。

## 前提

- `0116` が完了し、公開 release で `SoraDispatcher` の非推奨化と移行案内が提供されていること。
- production code が目的別 owner / command へ移行済みであること。
- 次期 major version の作業として着手すること。

上記を満たしていない場合は、本 issue に着手しない。

## 現状

`SoraDispatcher` は `RTCDispatcherQueueType.typeCaptureSession` と `.typeAudioSession` を公開 abstraction として露出する。

この API が残る限り、WebRTC C API や新しい camera / audio owner へ移行した後も、既存の queue identity と generic closure 配送を維持する必要がある。

## 設計方針

- `Sora/SoraDispatcher.swift` と公開 `SoraDispatcher` 型を削除する。
- production code、test、sample、documentation から参照を削除する。
- generic な代替 dispatch API を追加しない。
- WebRTC / camera / audio object は目的別 owner / adapter の外へ返さない。
- `0070` が先に `RTCDispatcher` を撤去している場合は、その内部 thread model を利用し、互換 wrapper を残さない。
- API baseline を次期 major version の意図した破壊的変更として更新する。
- migration guide に、用途別の移行先を記載する。

## スコープ外

- camera owner の実装は `0103` で扱う。
- WebRTC C API への移行は `0070` で扱う。
- raw WebRTC 型を公開 API からすべて削除する作業は本 issue に含めない。
- 利用者指定の汎用 executor API は追加しない。

## テスト方針

モックやスタブは使用しない。

- SDK と全 test target を clean build し、`SoraDispatcher` の残存参照がないことを確認する。
- 実カメラと実 AudioSession を利用する既存機能が、目的別 owner 経由で動作することを確認する。
- `rg` で production code、test、documentation に `SoraDispatcher` が残っていないことを確認する。
- API baseline が `SoraDispatcher` の削除だけを意図した break として検出することを確認する。
- `0070` の migration test で旧 dispatcher への依存が再導入されないことを確認する。

## 完了条件

- `SoraDispatcher` の型と実装ファイルが削除されていること。
- production code、test、documentation に参照が残っていないこと。
- generic な代替 dispatch API を追加していないこと。
- camera / audio 機能が目的別 owner / adapter で動作すること。
- `0070` の thread model と重複する abstraction がないこと。
- migration guide に用途別の移行先が記載されていること。
- API baseline が意図した major change として更新されていること。
- 既存テストがすべて成功すること。

## 解決方法
