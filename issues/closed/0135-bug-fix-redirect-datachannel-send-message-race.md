# redirect 時の旧 DataChannel 無効化と sendMessage の競合を修正する

- Created: 2026-09-10
- Completed: 2026-10-07
- Branch: feature/fix-redirect-datachannel-send-message-race
- Polished: 2026-09-16
- Updated: 2026-10-01

## 目的

redirect 受理時に旧 DataChannel を無効化しても、`MediaChannel.sendMessage` が無同期で `dataChannels` を参照するため、無効化と並行した送信が旧 DataChannel へ届くデータ競合がある。redirect 後の送信経路を確実に無効化する。

## 現状

- `PeerChannel` は redirect 受信時に `switchedToDataChannel` を `false` にし、`dataChannels.removeAll()` で旧 DataChannel の参照を解放する。この処理は WebSocket の delegate スレッドで実行される。
- `MediaChannel.sendMessage(label:data:)` は利用者のスレッドから `peerChannel.switchedToDataChannel` と `peerChannel.dataChannels[label]` を無同期で読む。
- `dataChannels` は `PeerChannel` の素の辞書であり、次の経路で無同期に読み書きされる。
  - 読み取り: `MediaChannel.sendMessage`
  - 書き込み: `PeerChannel.handleSignalingOverWebSocket` の `.redirect` ケースの `dataChannels.removeAll()`
  - 書き込み: `PeerChannel.peerConnection(_:didOpen:)`
  - 読み取り: `PeerChannel.sendMessageOverDataChannel`
  - 読み取り: `PeerChannel.createAndSendReAnswerOverDataChannel`
  - 読み取り: `BasicDataChannelDelegate` の `dataChannel(_:didReceiveMessageWith:)` (`Sora/DataChannel.swift`)
- `switchedToDataChannel` も素の変数であり、次の経路で無同期に読み書きされる。
  - 読み取り: `MediaChannel.sendMessage`、`PeerChannel.scheduleWebSocketDisconnectIfNeeded`、`PeerChannel.sendDisconnectMessageIfNeeded`
  - 書き込み: `PeerChannel.handleSignalingOverWebSocket` の `.switched` ケース (true) と `.redirect` ケース (false) (両ケースとも WebSocket の delegate スレッドのため、書き込み同士は直列化される)
- `peerChannel.rpcChannel` の参照も無同期である。`MediaChannel.performRPC` (`MediaChannel.rpc` と `MediaChannel.sendableRPC` の共通経路) と `PeerChannel.handleRPCMessage` の読み取りが、`PeerChannel.peerConnection(_:didOpen:)`、`handleSignalingOverWebSocket` の `.redirect` ケース、`basicDisconnect` の書き込み (生成と nil 代入) と並行し得る。
- `RPC` は `RPCChannel` の barrier で pending の登録と invalidate を直列化しているが、`dataChannel.send(data)` は barrier の外にあり、旧 DataChannel への送信そのものは保護していない。`sendMessage` の修正を RPC の barrier と同一視しない。
- `0095` で redirect 受理時の逐次的な無効化 (`switchedToDataChannel = false` / `dataChannels` の解放) は実装済みである。本 issue は無効化と読み取りが並行した場合の排他が未実装である点だけを対象とし、`0095` の挙動を変更しない。既存の `PeerChannelRedirectInvalidationTests` は redirect 完了後の逐次呼び出しのみで、並行競合を検証していない。
- Thread Sanitizer を有効にして `SoraTests` を全件実行する `tsan` job が `.github/workflows/e2e-test.yml` に追加された (`ecadde9b`、2026-09-30、`0119`)。2026-10-01 の develop の実行 (https://github.com/shiguredo/sora-ios-sdk/actions/runs/36848156662 の attempt 1) で、本 issue が扱う `rpcChannel` の競合が `SendableRpcE2ETests.testSendableRPCCancellationTerminatesAll` で実際に検出され、job が失敗した。検出内容は WebRTC の DataChannel スレッドの `PeerChannel.handleRPCMessage` の読み取りと、main thread の `PeerChannel.basicDisconnect` の nil 代入である。同じ run の attempt 2 は `WrapperVideoEncoderFactory` の競合 (`0026` が扱う) で失敗しており、`tsan` job を成功させるには両方の修正が必要である。
- 他の open issue として `0164` (redirect 処理の旧 transport 無効化が到達しない防御コードであることの明記、2026-09-18 起票、2026-09-25 磨き上げ) が追加された。`0164` は redirect が `connect` への応答として接続確立前にのみ届くため `.redirect` ケースの無効化対象は常に空であると主張しつつ、対象が空でも `switchedToDataChannel` / `dataChannels` / `rpcChannel` の書き込みと `MediaChannel.sendMessage` / RPC の読み取りは無同期であり本 issue の排他単位の導入は必要であるとしている。redirect 経路の書き込みの到達性の結論は `0164` に委ねる。

## 設計方針

- `dataChannels`、`switchedToDataChannel`、`rpcChannel` の参照の読み書きを単一の排他単位へ統一する。排他単位は `PeerChannel` が所有し、`MediaChannel.sendMessage` はその単位を取得して「照合から `dc.send(data)` まで」を同一区間で行う。`MediaChannel.performRPC` (`MediaChannel.rpc` と `MediaChannel.sendableRPC` の共通経路) もその単位で `peerChannel.rpcChannel` の参照を読み、以後の pending 登録と送信の終端は `RPCChannel` の barrier と invalidate が保証する。
- 「現状」で列挙した `dataChannels` / `switchedToDataChannel` / `rpcChannel` 参照の全経路を同じ排他単位へ移行する。`sendMessage` と redirect だけを排他すると他経路のデータ競合が残るため、全経路を対象にする。排他単位を保持する区間は参照の読み書きと (`sendMessage` では) 送信までに限り、`DataChannel` の delegate 処理や `RPCChannel` のメソッド呼び出しは排他単位の外で行う。
- 排他単位を保持したまま利用者のハンドラーや RPC の完了を呼ばない。`didOpen` の `onOpenDataChannel` 通知と、`.redirect` / `basicDisconnect` の `rpcChannel.invalidate` (利用者 completion を同期的に呼ぶため) は排他単位の外で実行し、参照の書き込み (nil 代入) だけを排他単位で行う。これによりハンドラーや completion から `sendMessage` / `rpc` が再入しても、非再帰ロックによるデッドロックにならない。
- 世代照合は補助として、取得済み `dc` の世代を送信直前に再確認するために用いる。世代照合だけでは辞書読みのデータ競合は解消しないため、主方針にはしない。
- `dataChannelOpenLock` は `MediaChannel` が OPEN 追跡状態を保護する別目的の私有ロックであり、`PeerChannel.dataChannels` は保護していない。排他単位は別に設ける。
- 公開 API の戻り値 (`SoraError.messagingError`) は既存の契約を維持する。

## 完了条件

- redirect の無効化が完了した後に開始した `sendMessage` は旧 DataChannel へ送信しない。
- `sendMessage` と redirect の無効化を並行実行しても、`dataChannels`、`switchedToDataChannel`、`rpcChannel` 参照へのデータ競合が発生しない。
- Thread Sanitizer を有効にしたテストでデータ競合が検出されない (対象は `.github/workflows/e2e-test.yml` の `tsan` job)。
- 無効化後の `sendMessage` は `SoraError.messagingError` を返す。
- redirect を含む既存の messaging の挙動を壊さない。

## テスト方針

モックやスタブは使用しない。

- `sendMessage` と redirect の無効化を複数スレッドから並行実行するテストを追加し、Thread Sanitizer でデータ競合が検出されないことを確認する。
- `MediaChannel.performRPC` (`MediaChannel.rpc` と `MediaChannel.sendableRPC` の共通経路) の `rpcChannel` 参照取得と redirect の並行実行も同様に Thread Sanitizer の対象とする。
- 既存の `PeerChannelRedirectInvalidationTests` が redirect 完了後の逐次呼び出しのみであることを踏まえ、並行実行のテストを別途追加する。
- 実 Sora での redirect 競合は手動確認とし、自動テストで再現できない項目を未検証として区別する。

## 変更対象

- `Sora/PeerChannel.swift`: 排他単位の導入と `dataChannels` / `switchedToDataChannel` / `rpcChannel` 参照の全経路の移行
- `Sora/MediaChannel.swift`: `sendMessage` の照合から送信までと、`performRPC` (`rpc` / `sendableRPC` の共通経路) の `rpcChannel` 参照取得を排他区間へ移動
- `Sora/DataChannel.swift`: 必要に応じて `dataChannels` の参照経路を移行
- `SoraTests/`: 並行実行の Thread Sanitizer テスト

## 解決方法

2026-10-06 に対応し、2026-10-07 に PR #425 として develop へマージした。2026.4.0 に含まれる。

### 修正内容

- `Sora/PeerChannel.swift` に `PeerChannelMessagingStorage` を追加し、登録済みの `DataChannel` の辞書 / `switchedToDataChannel` / `rpcChannel` を単一の `NSLock` で保護した。変更前は 3 つとも lock 保護のない可変状態だった
  - 読み書きはすべて storage の `withLock(_:)` 配下で行い、lock は葉 lock として保持したまま他の lock を取らない
  - `dataChannels` という辞書プロパティは無くなり、登録済みの参照は `storedDataChannels` に移った。`switchedToDataChannel` と `rpcChannel` は lock 付きの computed property にした
- `Sora/MediaChannel.swift` の `sendMessage(label:data:)` は、`switchedToDataChannel` と登録済み `DataChannel` の照合から `DataChannel.sendWithoutLogging(_:)` までを 1 つの排他区間で行うようにした。redirect の無効化が完了した後に区間へ入る送信は旧 DataChannel を参照せず、`SoraError.messagingError` を返す
- `Sora/MediaChannel.swift` の `performRPC` (`rpc` と `sendableRPC` の共通経路) も同じ排他単位で `peerChannel.rpcChannel` の参照を読むようにした
- `Sora/PeerChannel.swift` の redirect 受理処理を `invalidateMessagingAfterRedirect()` に切り出し、`switchedToDataChannel` の false 化 / 旧 DataChannel の解放 / `rpcChannel` の取り出しを 1 つの排他区間で行うようにした。`RPCChannel.invalidate(reason:)` は利用者の completion を同期的に呼ぶため区間の外で実行する
- `Sora/DataChannel.swift` の delegate、`Sora/PeerChannel.swift` の `handleRPCMessage` / `basicDisconnect` / `didOpen` も同じ排他単位へ移した。lock 区間の中で利用者の handler、completion、Logger を呼ばない
- 公開 API は変更していない。`sendMessage` の戻り値は従来どおり `SoraError.messagingError` である

### 設計方針との差

- 世代照合 (`dataChannelGeneration`) は、非同期処理の完了時に旧接続の結果を破棄する補助として用い、`sendMessage` の送信直前の再確認は行っていない。辞書参照と送信を同一区間で完結させれば旧 DataChannel を掴まないため、世代照合は排他の代わりにならない。この判断は `PeerChannelMessagingStorage` のコメントに明記した
- 対象は redirect 経路だけではない。`tsan` job が実際に検出したのは切断経路の `rpcChannel` の競合 (`PeerChannel.handleRPCMessage` の読み取りと `PeerChannel.basicDisconnect` の nil 代入) であり、本修正は切断経路を含む全経路を対象にしている

### テスト

`SoraTests/PeerChannelMessagingRaceTests.swift` を追加した。モックやスタブは使用せず、実 `RTCPeerConnection` / `DataChannel` で検証する。

- `testSendMessageAndRedirectInvalidationRace`: `sendMessage` と redirect の無効化を複数スレッドから交差させる
- `testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel`: 無効化完了後の送信が旧 DataChannel の対向へ届かず、`SoraError.messagingError` を返すこと
- `testRPCAndRedirectInvalidationRace` / `testRPCChannelMessageAndRedirectInvalidationRace`: `performRPC` と `handleRPCMessage` の `rpcChannel` 参照を redirect の無効化と交差させる
- `testRPCMessageAndDisconnectRace`: `handleRPCMessage` の読み取りと `basicDisconnect` の競合
- `testSendMessageFromOutputHandlerDoesNotDeadlock`: 利用者の出力 handler から `sendMessage` を再入してもデッドロックしないこと
- 既存の `SoraTests/PeerChannelRedirectInvalidationTests.swift` に `testRedirectReleasesRegisteredDataChannels` を追加した

### 検証結果

- CI の `tsan` job と `e2e` job が 2026-10-28 の develop (`78bc94e5`) で成功した: run [40648378038](https://github.com/shiguredo/sora-ios-sdk/actions/runs/40648378038)
  - `tsan` job は TSan report が 1 件でもあれば失敗するため、job の成功は report 0 件を意味する
  - 追加した並行テストも TSan 有効で実行されている
- 完了条件 5 件は上記のテストと CI で満たした

### 残課題

- redirect 受理時の無効化は、`0164` の主張 (redirect は接続確立前にのみ届くため対象が常に空) を前提にすると本番では到達しない防御コードである。`0164` は `dataChannels` / `removeAll()` を前提にしているため、本修正で前提が変わった。`0164` の同期は `0164` 側で行う
  - 完了条件 1 の検証 (`PeerChannelRedirectInvalidationTests` と `PeerChannelMessagingRaceTests` の一部) は、production では到達しない状態を人工的に作った検証である。`0164` が案 2 (無効化の削除) を採る場合は、当該テストの扱いを `0164` で決める
- 実 Sora 環境で redirect を発生させた手動確認は記録していない。redirect のタイミングはサーバー構成に依存し、`0164` の前提では接続確立後には発生しない
- `WrapperVideoEncoderFactory` の競合は本 issue ではなく `0185` が 2026-10-02 に修正した。本文の「`tsan` job を成功させるには両方の修正が必要」は、本 issue と `0185` の 2 件で満たされた

### 変更履歴

`CHANGES.md` の 2026.4.0 の `[FIX]` に、担当者行付きで収録済みである。
