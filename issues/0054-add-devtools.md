# iOS SDK 用 DevTools を作成する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-devtools
- Polished: 2026-09-23

## 目的

iOS SDK の開発・デバッグを支援する検証ツール (DevTools) を作成する。接続状態・統計情報・シグナリングメッセージなどを可視化・操作できるようにし、SDK が提供する機能をひととおり確認できるものとする。

## 背景

- 現状は SDK の内部状態やシグナリングの詳細を確認するためにログを読む以外の手段がなく、デバッグ・動作確認に手間がかかる
- `sora-ios-sdk-samples` に検証用の機能を足し続けるのは望ましくない。samples は機能を軽く試したり実装の参考にするためのサンプルであり、検証のためにあるものではない
- Sora には開発者向けの `sora-devtools` (Web) があり、クライアント側にも同等のデバッグ手段があることで問題の切り分けがしやすくなる

## 実装方針

- `sora-ios-sdk-devtools` リポジトリを新設し、検証ツールをそこへ集約する（既存のリポジトリは存在しない）
- SDK 本体には検証用途のコードを入れない。samples にも検証機能を足さない
- SDK の開発版ブランチを試験しやすい構成にする
- 基本コンセプトは `sora-devtools` (Web) と揃え、いきなり全機能を用意するのではなく、検証のたびに項目を追加していく

## 提供候補機能

- `getStats` 結果の構造化・表示
- シグナリングメッセージのログ表示（送受信の JSON を閲覧できる）
- 接続パラメーター（`Configuration` の内容）の確認
- ICE 接続状態・候補の確認

## 作成するもの

- 次の既存サンプルをマージした検証ツールを作成する
  - VideoChatSample
  - SimulcastSample
  - SpotlightSample
  - DataChannelSample
  - DecoStreamingSample
  - ScreenCastSample
  - RPCSample
- 接続中の操作を行えるようにする
  - 接続 / 切断
  - 映像のミュート / アンミュート
  - 音声のミュート / アンミュート
  - データチャネルメッセージの送信
- 接続情報を表示できるようにする
  - connection_id
  - 受信映像の解像度
  - 音量
- 不足している検証項目は、sora-ios-sdk-samples が提供済みの機能（ビットレート指定や音声・映像ミュートボタンなど）を踏襲しながら随時追加する

## 完了条件

- `sora-ios-sdk-devtools` リポジトリが新設されていること
- 検証ツールで接続 / 切断、映像・音声のミュート / アンミュート、データチャネルメッセージの送信が行えること
- 接続情報（connection_id、受信映像の解像度、音量）が表示できること
- SDK 本体に検証用途のコードが追加されておらず、sora-ios-sdk-samples に新規の検証機能が追加されていないこと
