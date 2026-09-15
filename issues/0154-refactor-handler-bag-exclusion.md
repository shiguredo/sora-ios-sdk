# MediaChannel と WebSocketChannel の handler bag の読み書きを排他する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/refactor-handler-bag-exclusion
- Polished:

## 目的

`MediaChannelHandlers` と `WebSocketChannelHandlers` の closure property は `var` を持つ class であり、利用者スレッドの書き込みと配送スレッドの読み込みが排他されていない。データ競合をなくし、Swift 6 の並行性要件と実行時の安全性を満たす。

## 現状

`Sora/MediaChannel.swift` の `MediaChannelHandlers` と `Sora/WebSocketChannel.swift` の `WebSocketChannelHandlers` は、いずれも `public final class` で closure property を `var` として公開している。

`MediaChannel.handlers` は `public var` で、`MediaChannel.init` が `Configuration.mediaChannelHandlers` の参照をそのまま代入する。`SignalingChannel` も `Configuration.webSocketChannelHandlers` の参照を `ws.handlers` へ代入する。

配送は `MediaChannel.swift` の `handlers.onXxx?`、`DataChannel.swift` の `mediaChannel.handlers.onDataChannelMessage`、`URLSessionWebSocketChannel.swift` の `handlers.onReceive` で、いずれも配送時に bag を読む。利用者は接続成功後に `mediaChannel.handlers.onDisconnect` などを設定する。

`0110` は handler の `@Sendable` 化と Sendable event API を、`0111` は `SoraHandlers` の同期を対象としており、`MediaChannelHandlers` / `WebSocketChannelHandlers` の closure 排他はどちらの対象でもない。

## 設計方針

- closure property の get / set を `NSLock` で排他する。公開シグネチャと配送セマンティクス (接続途中の設定が次の配送から反映される) を維持する。
- 配送側は lock の外で取得値 (closure のコピー) を呼ぶ。lock 保持中に呼ぶと、callback から別の handler を設定したときに deadlock するためである。
- `MediaChannel.handlers` の参照自体も lock 付きアクセサにし、bag の差し替えと配送の競合をなくす。
- `MediaChannel.internalHandlers` / `PeerChannel.internalHandlers` / `SignalingChannelInternalHandlers` は接続処理の同期区間で設定され (`SignalingChannelInternalHandlers.onDisconnect` は `PeerChannel.init` と `MediaChannel.connect` の 2 箇所で設定され後者が上書きする)、接続開始以降に書き換える経路が無いため対象外とする。
- `SoraHandlers` の同期は `0111`、handler の `@Sendable` 化と executor 契約は `0110` に委ねる。
- `0102` の完了を前提とする。`0102` が handler bag を snapshot から分離し、明示引数として引き渡す形にする。

## 前提となる issue

- `0102`: handler bag を設定 snapshot から分離する。
- `0119`: Thread Sanitizer による実行時検証の基盤。

## 完了条件

- handler property の読み書きが排他されていること。
- 接続開始後に `MediaChannel.handlers` を変更した場合、次の配送から反映される既存挙動が維持されること。`E2ETestBase` の `disconnectAndVerify` / `disconnectAll` が無修正で成功することを回帰条件とする。
- 公開 API のシグネチャと配送セマンティクスが変更されていないこと。
- Thread Sanitizer を有効にした test で、handler の読み書きを並行させても race report が出ないこと。
- `CHANGES.md` に追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
