# sora-ios-sdk-samples をビデオチャットアプリ 1 種類に集約する

- Created: 2026-09-23
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/remove-simplify-samples
- Polished: {YYYY-MM-DD}

## 目的

検証用途の機能を `sora-ios-sdk-devtools` (DevTools) へ移したうえで、`sora-ios-sdk-samples` から不要な機能を削り、ビデオチャットアプリ 1 種類に集約する。samples を「機能を軽く試したり実装の参考にするためのサンプル」としての位置付けに戻す。

## 現状

- `sora-ios-sdk-samples` は 1 つの SamplesApp に次のサンプルを内包している
  - VideoChatSample
  - SimulcastSample
  - SpotlightSample
  - DataChannelSample
  - DecoStreamingSample
  - ScreenCastSample
  - RPCSample
- DevTools への検証用途機能の移設は別 issue (0054) で扱う

## 設計方針

- devtools へ移した検証用途の機能は samples から削除する
- samples の構成はビデオチャットアプリ 1 種類に集約する

## 完了条件

- `sora-ios-sdk-samples` の SamplesApp がビデオチャットアプリ 1 種類 (VideoChatSample) の構成になっていること
- devtools へ移した検証用途の機能が samples から削除されていること
- `sora-ios-sdk-samples/CHANGES.md` に変更を記載すること
