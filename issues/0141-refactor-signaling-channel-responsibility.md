# SignalingChannel を WebSocket 接続管理に純化する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-signaling-channel-responsibility
- Polished: 2026-09-24

## 目的

`SignalingChannel` の名前と責務が一致していない状態を解消する。過去の設計議論で「WebSocket のプールとしての処理」と「シグナリング関連の処理」が混在しており、名前と責務が乖離していることが指摘されていた。その後の変更でシグナリングの解釈は `PeerChannel` 側へ移り、接続状態の所有は 0101 の `SignalingStateOwner` へ集約されたが、送信メッセージの JSON エンコードと受信メッセージの JSON デコードは依然として `SignalingChannel` に残っている。

`SignalingChannel` を WebSocket の接続管理 (接続候補 URL の生成と接続試行、redirect、切断、接続状態の問い合わせ、切断理由の通知) に純化し、名前に実態を反映させる。シグナリングメッセージの JSON エンコード / デコードは接続管理から分離する。

## 現状

- `Sora/SignalingState.swift` の `SignalingStateOwner` が接続状態の単一所有者である (0101)。`SignalingState` (phase / contactUrl / connectedUrl / dataChannelSignaling / ignoreDisconnectWebSocket) と現在使用中の WebSocket・接続候補の `URLSessionWebSocketChannel` を直列 queue 上で管理し、lock 保護の `SignalingSnapshot` (SignalingSnapshotStorage) を同期 getter へ公開する。`SignalingChannel` の `webSocketChannel` / `webSocketChannelCandidates` は 0101 で削除され、外部へは `webSocketChannelIdentifier` (`ObjectIdentifier`) と `disconnectWebSocket(identifier:)` のみを公開する。
- `Sora/SignalingChannel.swift` の `SignalingChannel` は `SignalingStateOwner`・`ConnectionConfigurationSnapshot`・`WebSocketChannelHandlers` を持ち、接続候補 URL ごとの `URLSessionWebSocketChannel` の生成 (`setUpWebSocketChannel(url:proxy:caCertificates:)`)、接続試行、redirect、切断のオーケストレーションと切断理由の通知を担う。
- 同じ `SignalingChannel` が `send(message:)` で `Signaling` を JSON エンコードし、`handle(message:)` で `Signaling.decode(_:)` を呼んでデコードする。シグナリングメッセージの codec が接続管理と同じ型に同居している。
- シグナリングメッセージの解釈は既に `Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` / `handleSignalingOverDataChannel` に集約されている。`SignalingChannel` は `PeerChannel.init` が設定する `internalHandlers.onReceive` (デコード結果の配送) と `internalHandlers.onReceiveJSON` (生 JSON の配送。`MediaChannel.onReceiveSignalingJSON` まで届く) だけを提供する。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` は `SignalingState` のフィールドであり、接続管理と `PeerChannel` の両方が扱う接続状態である。
  - 設定: `Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` の `.offer` 分岐 (`dataChannelSignaling`。offer に `data_channels` があるとき) と `.switched` 分岐 (`ignoreDisconnectWebSocket`)
  - 参照: `Sora/PeerChannel.swift` の `scheduleWebSocketDisconnectIfNeeded`、`sendDisconnectMessageIfNeeded` (basicDisconnect から呼ばれる)、および `Sora/SignalingChannel.swift` の `setUpWebSocketChannel` 内の切断通知ハンドラ (`state.ignoreDisconnectWebSocket` が false なら WS 切断で SDK の接続処理を終了する)
- DataChannel 経路でもシグナリングメッセージの encode / decode が行われる。`Sora/DataChannel.swift` の `didReceiveMessageWith` が `Signaling.decode(data)` を、`Sora/PeerChannel.swift` の `sendMessageOverDataChannel` が `JSONEncoder` を直接使う。
- 実際の WebSocket の接続・送受信は `Sora/URLSessionWebSocketChannel.swift` の `URLSessionWebSocketChannel` が担う。
- `SignalingChannel` は internal クラスであり公開 API ではない。`Sora/MediaChannel.swift` が生成し、`Sora/PeerChannel.swift` に渡す。同じファイルに公開型の `SignalingRole` (シグナリングメッセージで使われる role の列挙) が同居している。

## 前提となる issue

本 issue は 0101 と 0102 の完了を前提とする。両方とも完了済みである (0101: 2026-09-15、0102: 2026-09-16)。

- 0101 は `SignalingChannel` と `URLSessionWebSocketChannel` の状態所有者を `SignalingStateOwner` に統一し、接続状態の同期 getter を lock 保護の `SignalingSnapshot` で実現した。状態所有の再設計は完了しており、本 issue はこの構造の上で接続管理の境界と名前を確定させる。
- 0102 は接続設定の写し取りを `ConnectionConfigurationSnapshot` へ移し、`SignalingChannel` は `Configuration` を保持しなくなった。`send(message:)` の `JSONSerialization` による connect message 全体の再直列化も削除され、現在のエンコードは `JSONEncoder` のみである。

## 設計方針

- `Signaling` の JSON エンコード / デコードを、接続管理から独立した型へ分離する。`SignalingChannel.send(message:)` と `SignalingChannel.handle(message:)` から codec の実装を追い出し、接続管理側は文字列またはバイナリの送受信だけを知る形にする (送信は既存の `send(text:)`、受信は `handle(message:)` が受け取る `WebSocketMessage` のままにする)。codec へは `Signaling` の JSON エンコード (JSONEncoder による Codable エンコード) と `Signaling.decode(_:)` を集約する。
- DataChannel 経路の encode (`PeerChannel.sendMessageOverDataChannel`) / decode (`DataChannel.didReceiveMessageWith`) も同じ codec を使い、シグナリングメッセージの encode / decode 実装を 1 箇所に集約する。
- シグナリングの解釈と公開ハンドラへの配送は変えない。`internalHandlers.onReceiveJSON` は現在 `handle(message:)` で decode より先に呼ばれており、`Signaling` への変換を codec へ移した後も、生 JSON の配送とデコード結果の配送の順序・内容を維持する。
- WebSocket の接続管理を担う型の名前を、実態に合わせて変更する。接続候補 URL の生成、接続試行、redirect、切断、切断理由の通知が責務である。接続状態と候補 URL のプールは既に `SignalingStateOwner` が所有しており名前も責務と一致しているため変更しない。名前は実装時に確定する。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` は `SignalingState` のフィールドとして接続状態に残す。`setUpWebSocketChannel` の切断通知ハンドラが WS 切断で SDK を切断するかどうかをこの値で判定するため、`PeerChannel` 側へ移すと接続管理側が判定できなくなる (0101 が確定した所有のままとする)。
- protocol 非依存の新しいシグナリング型は新設しない。シグナリングの解釈は既に `PeerChannel` が担っており、新設すると二重化する。
- 公開 API は変更しない。`SignalingChannel` は internal であり、`SoraError` のメッセージ文字列以外に外部へ露出していない。同一ファイルに同居する公開型 `SignalingRole` は改名後のファイル構成に合わせて移設されるが、公開 API には影響しない (0107 で整備済みの API baseline で確認する)。

## スコープ外

- `SignalingChannel` と `URLSessionWebSocketChannel` の状態所有の統一は 0101 で完了済みである。
- `PeerChannel` の signaling / SDP 生成処理の切り出しは本 issue では扱わない。`PeerChannel` の行数肥大は本 issue で扱わない。
- `Signaling` の `encode(to:)` 内の type 文字列生成の統一は 0029 で扱う。
- `SignalingChannelInternalHandlers.onSend` の削除は 0025 で扱う。本 issue が `send(message:)` を codec 側へ移す場合は同一箇所を変更するため、着手順序を調整する。
- `Sora/SignalingChannel.swift` は 0033 (onDisconnectWithError の改名)、0063 (WebSocket クライアント証明書)、0156 (urlCandidates のログマスク) とも変更対象であり、着手順序を調整する。

## テスト方針

モックやスタブは使用しない。

- 改名および codec 分離の前後で、通常接続、切断、redirect、DataChannel シグナリング切り替えが変わらないことを確認する。
- `Signaling` のエンコード / デコードの既存テスト (`SignalingOfferEncodingTests` / `SignalingConnectTests` / `PeerChannelConnectEncodingTests` など) が通ることを確認する。
- 公開 API のシグネチャが変更されていないことを確認する (0107 で整備済みの baseline を使い `make api-check-fresh` で確認する)。
- `MediaChannel.onReceiveSignalingJSON` (生 JSON) と `MediaChannel.onReceiveSignaling` (デコード結果) の配送順序と内容が変わらないことを確認する。
- 実機で通常接続、クラスタ Sora による redirect、DataChannel シグナリング切り替えを確認する。

## 完了条件

- WebSocket 接続管理を担う型の名前が責務と一致していること。
- `Signaling` の JSON エンコード / デコードが接続管理から分離され、WebSocket 経路と DataChannel 経路の両方が同じ codec を使っていること。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` が `SignalingState` のフィールドとして接続状態に残り、接続管理と `PeerChannel` の両方から正しく参照されること。
- 公開 API が変更されていないこと (API baseline の一致を含む)。
- 既存テストがすべて成功すること。

## 変更対象ファイル

- `Sora/SignalingChannel.swift` (codec 分離と改名)
- `Sora/PeerChannel.swift` (codec の利用への移行)
- `Sora/MediaChannel.swift` (生成箇所の更新)
- `Sora/ConnectionTimer.swift` (`ConnectionMonitor.signalingChannel` の型参照の更新)
- `Sora/DataChannel.swift` (codec の利用への移行)
- 分離する codec の新規ファイル (または `Sora/Signaling.swift` への統合。公開 API と既存テストの挙動は変えない。`SignalingRole` は改名後のファイル構成に合わせて移す)
- `SoraTests/SignalingConnectTests.swift` / `PeerChannelConnectEncodingTests.swift` / `ConnectionTaskTests.swift` / `ConnectionTimerLifecycleTests.swift` / `ConnectionConfigurationSnapshotTests.swift` / `PeerChannelRedirectInvalidationTests.swift` / `PeerChannelConnectCompletionTests.swift` (`SignalingChannel` を直接生成しているため)
