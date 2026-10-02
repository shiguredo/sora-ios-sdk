# MediaChannel と WebSocketChannel と CameraVideoCapturer と MediaStream の handler bag の読み書きを排他する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/refactor-handler-bag-exclusion
- Polished: 2026-10-01

## 目的

`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の closure property は `var` を持つ class であり、利用者スレッドの書き込みと配送スレッドの読み込みが排他されていない。データ競合をなくし、実行時の安全性を満たす。これらの型を `Sendable` に準拠させること、closure に `@Sendable` を付けること、callback の executor 契約の明文化は本 issue の対象外とする (新しい Sendable event API と legacy handler の executor 契約 doc は `0110`、`SoraHandlers` の同期は `0111` が扱い、`0110` は既存 handler の class と property の型を変更しない)。

## 現状

`Sora/MediaChannel.swift` の `MediaChannelHandlers` / `Sora/WebSocketChannel.swift` の `WebSocketChannelHandlers` は `public final class`、`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturerHandlers` は非 `final` の `public class`、`Sora/MediaStream.swift` の `MediaStreamHandlers` は `public final class` で、いずれも closure property を `var` として公開している。

`MediaChannel.handlers` は `public var` で、`MediaChannel.init` が `Configuration.mediaChannelHandlers` の参照をそのまま代入する。`SignalingChannel` も `Configuration.webSocketChannelHandlers` の参照を `ws.handlers` へ代入する。

配送は `MediaChannel.swift` の `handlers.onXxx?`、`DataChannel.swift` の `mediaChannel.handlers.onDataChannelMessage`、`URLSessionWebSocketChannel.swift` の `handlers.onReceive`、`MediaStream.swift` の `handlers.onSwitchVideo` / `onSwitchAudio` で、いずれも配送時に bag を読む。利用者は接続成功後に `mediaChannel.handlers.onDisconnect` などを設定する。

`0110` は新しい Sendable event API と legacy handler の executor 契約 doc を対象とし (既存 handler の class と property の型は変更しない)、`0111` は `SoraHandlers` の同期を対象としており、`MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の closure 排他はどちらの対象でもない。`CameraVideoCapturerHandlers` は `0103` が `CameraVideoCapturer.handlers` を lock 付きアクセサにした際に、closure property 自体の排他を本 issue へ委ねている。`MediaStreamHandlers` は `0105` が frame の ingress と renderer 配送だけを扱い、closure property の読み書き排他を本 issue へ委ねている。

## 設計方針

- `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の closure property の get / set を `NSLock` で排他する。公開シグネチャと配送セマンティクス (接続途中の設定が次の配送から反映される) を維持する。
- 配送側は lock の外で取得値 (closure のコピー) を呼ぶ。lock 保持中に呼ぶと、callback から別の handler を設定したときに deadlock するためである。
- `MediaChannel.handlers` の参照自体も lock 付きアクセサにし、bag の差し替えと配送の競合をなくす。
- closure property と `MediaChannel.handlers` を lock 付きの computed property にすると、公開 API のソース互換 (名前・型・アクセスレベル) は変わらないが、`swift-api-digester` の dump では `HasStorage` / `HasInitialValue` と accessor の `implicit` が変わる。`make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt` を同じ変更内で再生成し、`make api-check-fresh` が成功することを確認する (`CODEBASE.md` の「baseline を更新する手順」)。
- `MediaChannel.internalHandlers` / `PeerChannel.internalHandlers` / `SignalingChannelInternalHandlers` / `WebSocketChannelInternalHandlers` は対象外とする。`MediaChannel.internalHandlers` は型が `MediaChannelHandlers` のため closure property は同じ lock の対象になる (参照の差し替えは無いため lock 付きアクセサは不要)。`PeerChannel.internalHandlers` の `onAddStream` などは `MediaChannel.basicConnect` が非同期 hop の後に設定するが、`peerChannel.connect` を呼ぶ前の 1 回だけであり、配送と並行する書き換えは無い。`SignalingChannelInternalHandlers.onDisconnect` は `PeerChannel.init` と `MediaChannel.connect` の 2 箇所で設定され後者が上書きするが、これも配送開始前である。`URLSessionWebSocketChannel.internalHandlers` は redirect ごとに生成される channel へ設定され `disconnect` で差し替わるが、書込は `SignalingChannel` の `owner.queue` 上の接続処理で行われ、読み出しも同じ queue 上の delegate callback である。
- `SoraHandlers` の同期は `0111`、新しい Sendable event API と legacy handler の executor 契約 doc は `0110` に委ねる。`0110` は既存 handler の closure 型を変更しないため、本 issue でも `@Sendable` を付けない。
- `0102` の完了を前提とする。`0102` が handler bag を snapshot から分離し、明示引数として引き渡す形にする。

## 前提となる issue

- `0102` (完了): handler bag を設定 snapshot から分離する。
- `0103` (完了): カメラ状態の所有者を単一化する。`CameraVideoCapturerHandlers` の closure 排他を本 issue へ委ねている。
- `0105` (完了 2026-09-18): frame の ingress と renderer 配送を整理し、`MediaStreamHandlers` の closure property の読み書き排他を本 issue へ委ねている。
- `0119` (完了 2026-09-30): Thread Sanitizer (TSan) による実行時検証の基盤。`.github/workflows/e2e-test.yml` の `tsan` job が `SoraTests` 全体を実行するが、`0119` は handler bag の読み書きを並行させる stress をスコープ外として本 issue へ委ねている。本 issue が追加する stress test はこの job の対象に入る。
- `0162` (open): `Configuration` の handlers bag が接続間で共有される問題。`0162` が `MediaChannel.handlers` への代入方法を変える場合があるため、`0110` の「実装順序を整合させる」に従い、どちらかを先行させて他方を rebase する。`0162` が扱う bag の共有自体は本 issue の対象外である。

## 完了条件

- `MediaChannelHandlers` / `WebSocketChannelHandlers` / `CameraVideoCapturerHandlers` / `MediaStreamHandlers` の handler property の読み書きが排他されていること。
- 接続開始後に `MediaChannel.handlers` を変更した場合、次の配送から反映される既存挙動が維持されること。`E2ETestBase` の `disconnectAndVerify` / `disconnectAll` が無修正で成功することを回帰条件とする。
- 公開 API のソース互換 (名前・型・アクセスレベル) と配送セマンティクスが変更されていないこと。stored property から lock 付き computed property への変更で `swift-api-digester` の dump は変わるため、再生成した baseline で `make api-check-fresh` が成功すること。
- `SoraTests/ConcurrencyStressTests.swift` に追加した stress test で、handler property の読み書きと配送を複数スレッドから交差させ、Thread Sanitizer を有効にした実行で handler bag を指す race report が出ないこと。CI の `tsan` job は `SoraTests` 全体を対象とするため、本 issue 以外の未修正の競合が残っている間は job 全体が失敗し得る。その場合の判定は handler bag を指す report が無いことで行う。
- `CHANGES.md` に追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 変更対象

- `Sora/MediaChannel.swift`: `MediaChannelHandlers` の closure property の lock 化と `MediaChannel.handlers` の lock 付きアクセサ
- `Sora/WebSocketChannel.swift`: `WebSocketChannelHandlers` の closure property の lock 化
- `Sora/CameraVideoCapturer.swift`: `CameraVideoCapturerHandlers` の closure property の lock 化と `CameraHandlersStorage` の doc の更新
- `Sora/MediaStream.swift`: `MediaStreamHandlers` の closure property の lock 化
- `SoraTests/ConcurrencyStressTests.swift`: handler bag の読み書きを交差させる stress test の追加 (ファイル冒頭の「対象に含めない」という記述も本 issue の完了に合わせて更新する)
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: `make api-baseline` による再生成
- `CHANGES.md`: `## develop` への追記

## 解決方法
