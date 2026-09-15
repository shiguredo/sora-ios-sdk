# Sora.connect の webRTCConfiguration 引数が接続に反映されない問題を修正する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-ignored-webrtc-configuration
- Polished:

## 目的

`Sora.connect(configuration:webRTCConfiguration:handler:)` の `webRTCConfiguration` 引数が接続処理に反映されず、利用者が指定した ICE サーバーや ICE トランスポートポリシーが無視される問題を修正する。

ICE サーバーを設定したつもりで接続できず、TURN 経由の接続が必要な環境で接続に失敗する。

## 現状

`Sora/Configuration.swift` の `Configuration.webRTCConfiguration` と、`Sora/Sora.swift` の `Sora.connect` が受け取る `webRTCConfiguration` 引数の 2 系統がある。

`Sora.connect` は引数を `MediaChannel.connect(webRTCConfiguration:)` へ渡し、`MediaChannel.basicConnect(webRTCConfiguration:)` の引数として宣言されるが、`basicConnect` の本体で一度も参照されない。実際に `RTCPeerConnection` の設定に使われるのは `PeerChannel.init` が読む `Configuration.webRTCConfiguration` だけである。

`webRTCConfiguration` 引数には既定値 `WebRTCConfiguration()` があるため、「未指定」と「既定値を明示指定」を区別できない。単純に引数で `Configuration.webRTCConfiguration` を上書きすると、`Configuration` 側に ICE サーバーを設定している利用者を壊す。

## 設計方針

- どちらを正本にするかを決める。第一候補は `Configuration.webRTCConfiguration` への一本化である。
- 引数を optional にして「未指定」を判別できるようにし、指定時だけ `Configuration.webRTCConfiguration` を上書きする案も検討する。
- 公開 API の破壊的変更を避ける場合は、引数を非推奨化して移行期間を設ける。
- ICE サーバーは offer 受信時にサーバー値で上書きされる既存挙動を変えない。`isInsecure` は `Configuration.insecure` から設定する既存挙動も変えない。
- `0102` の完了を前提とする。`0102` は snapshot を `Configuration.webRTCConfiguration` から生成する。

## 前提となる issue

- `0102`: 接続設定の snapshot 化。本 issue の修正対象と同じ引数を扱う。

## 完了条件

- `Sora.connect(webRTCConfiguration:)` に渡した設定が実際の `RTCConfiguration` に反映されること、または引数が非推奨化され `Configuration.webRTCConfiguration` へ移行する手順が利用者向け文書に記載されていること。
- 既存の `Configuration.webRTCConfiguration` を使う経路の挙動が変わらないこと。
- offer 受信時の ICE サーバー上書きと `Configuration.insecure` の反映が維持されること。
- `CHANGES.md` に修正内容を追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
