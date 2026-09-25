# sora-ios-sdk-samples をビデオチャットアプリ 1 種類に集約する

- Created: 2026-09-23
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/remove-simplify-samples
- Polished: 2026-09-25

## 目的

検証用途の機能を `sora-ios-sdk-devtools` (DevTools) へ移したうえで、`sora-ios-sdk-samples` から検証用途のサンプルを削除し、ビデオチャットアプリ 1 種類 (VideoChatSample) に集約する。samples を「機能を軽く試したり実装の参考にするためのサンプル」としての位置付けに戻す。

## 背景

- `sora-ios-sdk-samples` に検証用の機能を足し続けるのは望ましくない。samples は機能を軽く試したり実装の参考にするためのサンプルであり、検証のためにあるものではない (0054 の方針と同じ)
- 検証用途の機能の DevTools への移設は別 issue (0054) で扱う。0054 は sora-ios-sdk-samples が現状提供している 7 サンプルをマージして検証ツールを作成するため、本 issue は 0054 の完了後に着手する。移設前に samples から削除すると、0054 のマージ元の実装が失われる

## 現状

- `sora-ios-sdk-samples` は 1 つの SamplesApp に次のサンプルを内包している
  - VideoChatSample (ビデオチャット)
  - SimulcastSample (サイマルキャスト)
  - SpotlightSample (スポットライト)
  - DataChannelSample (メッセージング)
  - DecoStreamingSample (デコ動画配信)
  - ScreenCastSample (スクリーンキャスト)
  - RPCSample (RPC 機能)

## 設計方針

- 削除対象は SimulcastSample / SpotlightSample / DataChannelSample / DecoStreamingSample / ScreenCastSample / RPCSample の 6 種類と、削除後に利用されなくなる共通部品 (SamplesApp/Shared/ 配下を含む) とする
- 残すのは VideoChatSample と、それが利用する共通部品のみとする。VideoChatSample が持つ設定 (コーデック選択、映像・音声のミュート、ビットレート指定など) は SDK の利用例として維持し、削除しない
- SamplesApp の起動メニュー (MainMenuView のサンプル一覧) も VideoChatSample のみの構成へ減らす
- `sora-ios-sdk-samples/README.md` のサンプル紹介から削除対象を除く

## 完了条件

- `sora-ios-sdk-samples` の SamplesApp がビデオチャットアプリ 1 種類 (VideoChatSample) の構成になっていること (MainMenuView のサンプル一覧が VideoChatSample のみであることを含む)
- 削除対象の 6 サンプルと、削除後に利用されなくなった共通部品が `sora-ios-sdk-samples` から削除されていること
- `sora-ios-sdk-samples/README.md` に削除対象のサンプル紹介が残っていないこと
- `sora-ios-sdk-samples/CHANGES.md` に変更を記載すること
