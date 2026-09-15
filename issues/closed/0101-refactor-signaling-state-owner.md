# SignalingChannel と URLSessionWebSocketChannel の状態所有者を統一する

- Created: 2026-08-27
- Completed: 2026-09-15
- Branch: feature/refactor-signaling-state-owner
- Polished: 2026-09-02

## 目的

`SignalingChannel` と `URLSessionWebSocketChannel` の mutable state を signaling 専用の 1 つの actor または serial executor へ集約し、接続、送信、redirect、切断、URLSession delegate callback の順序を保証する。

`URLSessionWebSocketChannel: @unchecked Sendable` が依存している未成立の前提を除去し、Swift 6 の isolation を実行経路で説明できる構造にする。

## 現状

`Sora/SignalingChannel.swift` は URLSession delegate callback 用の `OperationQueue` を `maxConcurrentOperationCount = 1` で作成している。

ただし、この queue が直列化するのは URLSession delegate callback だけである。次の操作は同じ queue に限定されていない。

- `connect`
- signaling message の `send`
- `redirect`
- 利用者または `PeerChannel` からの `disconnect`
- WebSocket 切断遅延処理

`Sora/URLSessionWebSocketChannel.swift` は `@unchecked Sendable` で、次の mutable state を保持する。

- internal handler と利用者 handler
- `isClosing`
- `urlSession`
- `webSocketTask`
- delegate callback 由来の終端状態（`didCloseWith` / `didCompleteWithError` の 2 系統）

クラスコメントは「URLSession delegate と `SignalingChannel` が単一の直列 queue を利用する」ことを安全性の根拠としているが、すべての public / internal entry point をその queue へ強制する構造はない。

`didCloseWith`、`didCompleteWithError`、receive completion、send completion、利用者切断が競合した場合に、状態更新と handler の呼び出し順を 1 箇所で決定できない。

## 設計方針

### signaling owner

- signaling の phase、接続 URL、data_channel_signaling / ignore_disconnect_websocket のフラグ、接続中 / 候補の WebSocket 参照を 1 つの owner が保持する。
  - 状態機械 (phase / URL / フラグ) は `SignalingState` + `SignalingEvent` + 純粋な reducer として `Sora/SignalingState.swift` (新規) に置く。0100 の ConnectionLifecycle と同じ構成とする。
  - 非 Sendable な `URLSessionWebSocketChannel` の参照 (current / candidates) は reducer の state に含めず、owner のメソッド (`addCandidate` / `setCurrentChannel` / `removeCandidate` / `clearCandidates`) で直列 queue 上のみで管理する。
  - redirect generation は `0095` / `0100` の transport epoch と整合する概念とし、新たな独立カウンタを追加しない。旧 callback の拒否は `0095` の制約に従い、Channel の `isClosing` で判定する。
- `connect`、`send`、`redirect`、`disconnect` を含むすべての entry point を owner の直列 queue へ enqueue する。queue 外から同期 wait しない。再入 (delegate callback から操作 API を呼ぶ場合) は queue 上かどうかを検出して直接実行し、デッドロックしない。
  - owner queue は `PeerChannel` 経由で呼ぶ `RTCPeerConnection` の API が libwebrtc の signaling thread の完了を待つため、その実行中は signaling thread に依存する。signaling thread は `RTCPeerConnectionDelegate` の callback (`peerConnection(_:didGenerate:)` など) から `send` などの entry point を呼ぶため、queue 外からの同期 wait は owner queue と signaling thread の相互待ちでデッドロックする。
  - entry point の順序は queue への投入順で確定する。非同期で投入しても、単一の直列 queue へ投入する限り順序は保たれる。
- URLSession の delegate queue には owner と同じ直列 queue を設定する。delegate callback と操作が同じ queue を通ることで順序を確定する。
- `PeerChannel` / `MediaChannel` が同期参照する `contactUrl`、`connectedUrl`、`state`、`dataChannelSignaling`、`ignoreDisconnectWebSocket` は、`0100` の同期 getter 方針と同じく lock 保護の snapshot で維持し、owner への同期 wait で実現しない。
- `webSocketChannel` の同期 accessor は Channel 参照を返さず、現在使用中の Channel の識別子 (`webSocketChannelIdentifier`) を公開し、切断などの操作は `disconnectWebSocket(identifier:)` を owner の queue へ enqueue する形にする。Channel の状態 (`isClosing` 等) を owner queue 外から操作させない。

### delegate adapter

- `URLSessionWebSocketChannel` 自身が `URLSessionDelegate` / `URLSessionWebSocketDelegate` を実装する (小さい adapter への分離は行わない)。delegate callback は owner と同じ直列 queue 上で呼ばれるため、callback 内で identity を snapshot 化して別の ingress へ渡す必要がない。
- callback ごとに独立した Task を生成しない。
- 古い session / task の callback は Channel の `isClosing` で拒否する。`isClosing` は owner queue 上でのみ読み書きし、redirect や候補の破棄では owner が対象 Channel を `disconnect` してから参照を外すため、「`isClosing == false` の Channel は現在使用中の transport である」が成立する。session / task の identity 比較は行わない (1 インスタンスが作る session / task は 1 つであり、照合しても到達しない経路になるため)。
- Channel の可変状態 (`urlSession` / `webSocketTask` / `isClosing`) は owner の直列 queue 上でのみ読み書きする。

### 終端と callback

- `didCloseWith` と `didCompleteWithError` が両方届いても、1 接続につき切断通知を厳密に 1 回にする。1 回保証は Channel 自身の `isClosing` (owner queue 上でのみ読み書き) で行う。owner に終端済みの台帳 (墓石) は残さない。
- send / receive completion は、owner queue 上で Channel の `isClosing` を再確認し、切断済みの Channel では handler を呼ばない。owner は切断後も切断済みの Channel を current として保持するため (`isClosing == true`)、`isClosing == false` の Channel は現在使用中の transport である (逆は成立しない)。
- handler は状態更新の後に呼ぶ。ここでの「critical section 外」は「状態変更ブロックの外」を意味し、handler 呼び出しも owner queue 上で行う。接続試行を終端させる経路 (CA 証明書のパース失敗など) では take-and-clear した後に呼ぶ。接続成功時は handler を消費しない (redirect では新しい transport の採用時にも同じ handler を呼び、type: connect を再送するため)。handler 内から操作 API を呼ぶ再入は queue 上の直接実行で安全に処理される。handler 内で別スレッドの完了を同期的に待つことは避ける (owner queue を占有するため)。
- redirect では旧 transport を `disconnect` (=`isClosing = true`) してから owner の参照を外し、新しい `URLSessionWebSocketChannel` を生成して接続する。旧 transport の遅延 callback は `isClosing` で切り離す。

### 互換性

- `URLSessionWebSocketChannel` は internal であるため、公開対象は `WebSocketChannelHandlers` などの既存 handler API の公開シグネチャであり、これを維持する。
- `URLSessionWebSocketChannel` の `@unchecked Sendable` は残す。可変状態へのアクセスを owner の直列 queue に限定することでデータ競合が発生しないことを、クラスコメントで説明する。
- proxy、CA 証明書、認証 challenge の既存挙動を変更しない。

## スコープ外

- `MediaChannel` / `PeerChannel` 全体の接続状態所有は `0100` と `0010` が分担する。 (MediaChannel は `0010` の `connectionLifecycleLock`、PeerChannel の接続状態フラグは `0100` の reducer)
- redirect 時の旧 DataChannel / RPC 無効化は `0095` で扱う。
- 公開 callback API の `@Sendable` 化は別 issue とする。
- WebRTC C API への移行は `0070` で扱う。
- WebSocket クライアント証明書対応 (`0063`) は本 issue と同一ファイル・同一 symbol を変更するため、着手前に順序を調整する。`0025` / `0033` の handler symbol 変更も同様に調整する。

## テスト方針

モックやスタブは使用しない。

- 実 `URLSessionWebSocketTask` と実 signaling endpoint を使用し、connect、send、receive、disconnect の順序を検証する。
- redirect の実環境検証は `0095` と同様にリダイレクトを発生させるサーバー構成が必要なため自動テスト対象外とし、実機での手動確認とする。
- 利用者切断と `didCloseWith` / `didCompleteWithError` を競合させ、切断通知が 1 回であることを確認する。
- 古い task の receive / send completion が新しい接続の handler を呼ばないことを確認する。
- proxy は自動テスト基盤が存在しないため、認証 challenge の挙動維持は実機での手動確認で担保する。CA 証明書検証は既存の `ConfigurationTests` と実機確認で維持する。
- `SignalingState` / `SignalingEvent` / reducer を実際の transport event 列で入力し、phase / URL / フラグの遷移と stale event の拒否を検証する。
- `SignalingStateOwner` の enqueue が queue 外からの呼び出しをブロックしないこと、queue 上からの再入がその場で実行されること、投入順が保たれることを検証する。
- Thread Sanitizer を補助的に有効化する。
- テストには、delegate queue の直列化だけでは entry point 全体を保護できない理由を日本語コメントで明記する。

## 完了条件

- signaling の mutable state の所有者が 1 つであること (`SignalingStateOwner`)。
- `connect`、`send`、`redirect`、`disconnect`、delegate callback が同じ ordered ingress (owner の直列 queue) を通ること (queue 外からの投入は呼び出し元をブロックしない enqueue で行う)。
- 古い session / task の callback が current state を変更しないこと (Channel の `isClosing` で拒否)。
- `didCloseWith` と `didCompleteWithError` が競合しても切断通知が厳密に 1 回であること (Channel の `isClosing` を owner queue で保護)。
- handler が状態変更ブロックの外 (状態更新の後) で呼ばれていること。接続試行を終端させる経路では take-and-clear の後で呼ばれていること。
- `PeerChannel` / `MediaChannel` からの同期読み取り (`contactUrl`、`connectedUrl`、`state`、`dataChannelSignaling`、`ignoreDisconnectWebSocket`) が owner への同期 wait なしで成立すること (lock 保護の snapshot)。
- `webSocketChannel` への操作が owner queue 経由で行われ、Channel の状態が owner queue 外から操作されないこと。
- `URLSessionWebSocketChannel` の `@unchecked Sendable` の安全性がクラスコメントで説明されていること (可変状態のアクセスが owner queue に限定される)。
- `SignalingState` / `SignalingEvent` / reducer のテストが存在すること。
- proxy、CA 証明書、redirect の既存挙動が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

### 実装中に検出したデッドロック

最初の実装では owner への投入を `dispatchQueue.sync` による同期 wait で行っていた。この実装では、実接続を行う E2E テスト (`MessagingE2ETests.testSendrecvDataChannelMessaging`) が `started.` の表示後に停止し、CI がジョブのタイムアウト (40 分) で強制終了した。

原因は owner queue と libwebrtc の signaling thread の循環待ちである。

1. owner queue は URLSession の delegate queue でもあるため、受信処理 (`SignalingChannel.handle(message:)` → `PeerChannel.handleSignalingOverWebSocket`) が owner queue 上で動く。この経路は `setConfiguration` / `setRemoteDescription` / `answer(for:)` / `setLocalDescription` / `statistics` / `close` を呼ぶ。
2. libwebrtc の `RTCPeerConnection` の proxy (`pc/proxy.h` の `PROXY_METHOD` / `PROXY_CONSTMETHOD`) は、呼び出し元が signaling thread でない場合 `PostTask` した後に `rtc::Event::Wait(kForever)` で完了を待つ。したがって owner queue は signaling thread の空きを待つ。
3. signaling thread は `RTCPeerConnectionDelegate` の callback から `PeerChannel.peerConnection(_:didGenerate:)` → `SignalingChannel.send` などを呼ぶ。同期 wait の実装ではここで owner queue の空きを待つ。

この 2 と 3 が同時に成立すると相互待ちでデッドロックする。Simulator 上で実 libwebrtc と `SignalingStateOwner` を使った再現実験で確認した (signaling thread から `owner.sync` しない場合は 17 件の ICE candidate を処理して完了し、`owner.sync` する場合は 1 件目で停止した)。

### 対策

owner への投入を `SignalingStateOwner.enqueue` に変更し、queue 外からの entry point は呼び出し元をブロックしない非同期投入にした。queue 上で実行中の場合はその場で実行するため、再入でもデッドロックしない。entry point の順序は queue への投入順で確定し、非同期でも順序は保たれる。

`SignalingChannel` の `connect` / `redirect` / `disconnect` / `send(message:)` / `send(text:)` / `setConnectedUrl` / `disconnectWebSocket(identifier:)` と、`dataChannelSignaling` / `ignoreDisconnectWebSocket` の setter をすべて `enqueue` に統一した。`sync` は誤用を防ぐため削除した。

`SignalingStateOwnerTests` で、queue 外からの enqueue が呼び出し元をブロックしないこと、queue 上からの再入がその場で実行されること、投入順が保たれることを検証する。

### 終端処理のテストと receive の isClosing ガード

`URLSessionWebSocketChannel` の終端処理を検証可能にするため、`send` / `receive` の完了処理を `handleSendCompletion(_:)` / `handleReceiveResult(_:)` として切り出した (`PeerChannel.invokeConnectHandler` と同じく、テストから呼び出すため internal としている)。

`receive` の成功完了は利用者 handler (`WebSocketChannelHandlers.onReceive`) を `isClosing` で確認していなかった。`disconnect` は `internalHandlers` しか空にしないため、切断要求の直前に届いたメッセージの完了が切断後に実行されると利用者 handler が呼ばれ得る。`handleReceiveResult` の先頭で `isClosing` を確認するようにした (設計方針「send / receive completion は切断済みの Channel では handler を呼ばない」の実装)。

`URLSessionWebSocketChannelTests` を追加した。

- `didCloseWith` と `didCompleteWithError` が両方届いても切断通知が 1 回であること
- 利用者切断の後に close callback が届いても切断通知が発火しないこと
- 切断後に届いた受信結果で利用者 / 内部 handler が呼ばれないこと
- 切断後に届いた送信完了で切断通知が増えないこと

実 `URLSession` / `URLSessionWebSocketTask` (未 resume) を注入し、delegate メソッドと完了ハンドラを直接呼ぶため、ネットワークに依存せず決定的に検証できる。モックやスタブは使用しない。`handleReceiveResult` の `isClosing` ガードを一時的に外すと `testReceiveResultAfterDisconnectDoesNotCallHandlers` が失敗することを確認している。

Thread Sanitizer も補助的に実行した。0101 の変更箇所にはデータ競合は検出されず、検出された `PeerChannel.onConnect` の競合は別 issue (`0151`) として起票した。

### delegate 設計の変更に伴い削除した要求

設計方針の更新 (`f9805fd3` 設計方針を単一 owner の構成に合わせて更新する) で、delegate の設計を「`URLSessionDelegate` / `URLSessionWebSocketDelegate` を小さい adapter へ分離し、callback 内で session / task identity を snapshot 化して ordered ingress へ渡す」から「`URLSessionWebSocketChannel` 自身が delegate を実装する (1 インスタンスが 1 つの session / task を持つ)」へ変更した。

この変更により session / task の identity 比較は恒真になり、照合しても到達しない経路になる。しかし identity による拒否を求める記述 (設計方針と完了条件) が残っていたため、記述を実装に合わせて `isClosing` による拒否へ修正した。実装は新しい設計どおりで、identity 比較は追加しない。

### レビューで検出した redirect の退行

接続成功時に `owner.takeOnConnect()` で handler を消費していたため、redirect で新しい transport が採用されたときにも handler が呼ばれず、`type: connect` (`redirect: true`) が再送されなかった。

- `PeerChannel` の接続完了 handler (`signalingChannel.connect { ... }`) は、`sdp` がある場合に `redirect: true` で `sendConnectMessage` を呼ぶ。これは redirect で `type: connect` を再送するための経路である
- handler を再登録する経路はない (`signalingChannel.connect` の呼び出しは `PeerChannel.connect` の 1 箇所のみで、`SignalingChannel.redirect` は `setOnConnect` を呼ばない)
- develop では `if let onConnect = weakSelf.onConnect { onConnect(nil) }` で handler を消費していなかったため、この退行は本 issue の実装で作り込んだもの

接続成功時は handler を消費しない `SignalingStateOwner.onConnectOnQueue()` を追加し、終端経路 (CA 証明書のパース失敗) の `takeOnConnect()` は維持した。`SignalingStateOwnerTests` に、接続成功の通知で handler が消費されないことと、`takeOnConnect` が handler を消費することを検証するテストを追加した。

redirect の実環境検証はテスト方針で手動確認としているため CI では検出できない。実 Sora 環境での実機確認を 2026-09-15 に実施した。

### redirect の実機確認

クラスター構成の Sora サーバーで redirect を発生させ、実機 (iPhone14,7 / iOS 26.6.1、Sora iOS SDK 2026.3.0 / Sora 2026.2.0-canary.0) で確認した。ログは次の順に出た。

1. 接続先 (`node1`) へ接続し、`SignalingChannel DEBUG: call connect(handler:)` → `PeerChannel DEBUG: try creating offer SDP` → `did create offer SDP` → `did connect to signaling channel` → `send connect` の順で `type: connect` を送信する (この時点では `redirect` フィールドなし)。
2. `{"type":"redirect","location":"wss://node2/signaling"}` を受信し、`handle signaling over WebSocket => redirect` → `PeerChannel DEBUG: redirect: invalidating old transport (generation => 1)` → `SignalingChannel DEBUG: try redirecting to wss://node2/signaling` の順で処理する。
3. 旧 `node1` の WebSocket が `disconnecting` → `disconnected` となり、その後 `node2` が `connecting` → `connected` となる。
4. 新しい transport の接続成功時に `SignalingChannel DEBUG: call connect(handler:)` が再度呼ばれ、`did connect to signaling channel` → `send connect` の後に `{"sdp":...,"redirect":true,...}` が `node2` へ送信される。接続成功で handler が消費されないため、ここで `type: connect` が再送される (レビューで検出した退行の修正が機能している)。
5. `node2` から `type: offer` を受信して answer を送信し、`PeerChannel DEBUG: did connect` → `MediaChannel DEBUG: call onConnect` → `MediaChannel DEBUG: connection task completed` となる。利用者の connect handler の呼び出しは 1 回だけである。
6. `type: switched` を受信して `switchedToDataChannel => true (generation => 1)` となり、`signaling` / `notify` / `push` / `stats` / `rpc` の data channel がすべて open になる。

`connection timeout` と `DUPLICATED-CHANNEL-ID` は発生していない。旧 `node1` の切断後に同 WebSocket からの受信で handler が呼ばれる経路は発生していない (この競合自体は今回の実行では発生しておらず、`handleReceiveResult` の `isClosing` ガードの妥当性はユニットテストで検証している)。旧接続の TCP 終了に伴う `nw_flow_add_write_request ... Socket is not connected` と `Connection 1: received failure notification` は旧 transport の後始末であり、接続には影響していない。
