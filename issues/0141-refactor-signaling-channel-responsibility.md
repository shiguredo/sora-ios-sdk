# SignalingChannel を WebSocket 接続管理に純化する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-signaling-channel-responsibility
- Polished: {YYYY-MM-DD}

## 目的

`SignalingChannel` の名前と責務が一致していない状態を解消する。過去の設計議論で「WebSocket のプールとしての処理」と「シグナリング関連の処理」が混在しており、名前と責務が乖離していることが指摘されていた。その後の変更でシグナリングの解釈は `PeerChannel` 側へ移ったが、送信メッセージの JSON エンコードと受信メッセージの JSON デコードは依然として `SignalingChannel` に残っている。

`SignalingChannel` を WebSocket の接続管理 (候補 URL のプール、接続確立、redirect、切断、接続状態) に純化し、名前に実態を反映させる。シグナリングメッセージの JSON エンコード / デコードは接続管理から分離する。

## 現状

- `Sora/SignalingChannel.swift` の `SignalingChannel` は、内部クラスとして `webSocketChannel` / `webSocketChannelCandidates` / `contactUrl` / `connectedUrl` / `state` / `dataChannelSignaling` / `ignoreDisconnectWebSocket` を保持する。役割としては WebSocket の接続管理に寄っている。
- 同じ `SignalingChannel` が `send(message:)` で `Signaling` を JSON エンコードし、`handle(message:)` で `Signaling.decode(_:)` を呼んでデコードする。シグナリングメッセージの codec が接続管理と同じ型に同居している。
- シグナリングメッセージの解釈は既に `Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` / `handleSignalingOverDataChannel` に集約されている。`SignalingChannel` はデコード結果を `internalHandlers.onReceive` で `PeerChannel` へ渡すだけである。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` は `PeerChannel` が設定・参照する値であり、`SignalingChannel` の接続管理そのものの状態ではない。
  - 設定: `Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` の `.switched` 分岐
  - 参照: `Sora/PeerChannel.swift` の `scheduleWebSocketDisconnectIfNeeded`、`basicDisconnect`
- 実際の WebSocket の接続・送受信は `Sora/URLSessionWebSocketChannel.swift` の `URLSessionWebSocketChannel` が担う。
- `SignalingChannel` は internal クラスであり公開 API ではない。`Sora/MediaChannel.swift` が生成し、`Sora/PeerChannel.swift` に渡す。

## 前提となる issue

本 issue は `0101` の完了を前提とする。`0101` が `SignalingChannel` と `URLSessionWebSocketChannel` の状態所有者を統一する作業であり、その完了後に接続管理の境界と名前を確定させることで、状態所有の再設計と改名が衝突しないようにする。

## 設計方針

- `Signaling` の JSON エンコード / デコードを、接続管理から独立した型へ分離する。`SignalingChannel.send(message:)` と `SignalingChannel.handle(message:)` から codec の実装を追い出し、接続管理側はバイト列または文字列の送受信だけを知る形にする。
- WebSocket の接続管理を担う型の名前を、実態に合わせて変更する。候補 URL のプール、接続確立、redirect、切断、接続状態、切断理由の通知が責務である。名前は実装時に確定する。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` は `PeerChannel` の関心事であるため、`PeerChannel` 側へ移すか、接続管理の状態からは分離する。`0101` が扱う同期 accessor の方針と整合させる。
- protocol 非依存の新しいシグナリング型は新設しない。シグナリングの解釈は既に `PeerChannel` が担っており、新設すると二重化する。
- 公開 API は変更しない。`SignalingChannel` は internal であり、`SoraError` のメッセージ文字列以外に外部へ露出していない。

## スコープ外

- `SignalingChannel` と `URLSessionWebSocketChannel` の状態所有の統一は `0101` で扱う。
- `PeerChannel` の signaling / SDP 生成処理の切り出しは別 issue とする。`PeerChannel` の行数肥大は本 issue では扱わない。
- `Signaling` の `encode(to:)` 内の type 文字列生成の統一は `0029` で扱う。
- `SignalingChannelInternalHandlers.onSend` の削除は `0025` で扱う。

## テスト方針

モックやスタブは使用しない。

- 改名および codec 分離の前後で、通常接続、切断、redirect、DataChannel シグナリング切り替えが変わらないことを確認する。
- `Signaling` のエンコード / デコードの既存テストが通ることを確認する。
- 公開 API のシグネチャが変更されていないことを確認する。
- 実機で通常接続、クラスタ Sora による redirect、DataChannel シグナリング切り替えを確認する。

## 完了条件

- WebSocket 接続管理を担う型の名前が責務と一致していること。
- `Signaling` の JSON エンコード / デコードが接続管理から分離されていること。
- `dataChannelSignaling` / `ignoreDisconnectWebSocket` が適切な所有者に移っていること。
- 公開 API が変更されていないこと。
- 既存テストがすべて成功すること。

## 変更対象ファイル

- `Sora/SignalingChannel.swift`
- `Sora/PeerChannel.swift`
- `Sora/MediaChannel.swift`
- 分離する codec の新規ファイル

## 解決方法
