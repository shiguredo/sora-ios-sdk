# redirect 時の旧 DataChannel 無効化と sendMessage の競合を修正する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-redirect-datachannel-send-message-race
- Polished: 2026-09-10

## 目的

redirect 受理時に旧 DataChannel を無効化しても、`MediaChannel.sendMessage` が無同期で `dataChannels` を参照するため、無効化と並行した送信が旧 DataChannel へ届くデータ競合がある。redirect 後の送信経路を確実に無効化する。

## 現状

- `PeerChannel` は redirect 受信時に `switchedToDataChannel` を `false` にし、`dataChannels.removeAll()` で旧 DataChannel の参照を解放する。この処理は WebSocket の delegate スレッドで実行される。
- `MediaChannel.sendMessage(label:data:)` は利用者のスレッドから `peerChannel.switchedToDataChannel` と `peerChannel.dataChannels[label]` を無同期で読む。
- `dataChannels` は `PeerChannel` の素の辞書であり、少なくとも次の経路で無同期に読み書きされる。
  - `MediaChannel.sendMessage` の読み取り
  - `PeerChannel.peerConnection(_:didOpen:)` の書き込み
  - `PeerChannel.sendMessageOverDataChannel` の参照
  - `PeerChannel.createAndSendReAnswerOverDataChannel` の参照
  - `DataChannel` の `dataChannel(_:didReceiveMessageWith:)` の参照
- `RPC` は `RPCChannel` の barrier で pending の登録と invalidate を直列化しているが、`dataChannel.send(data)` は barrier の外にあり、旧 DataChannel への送信そのものは保護していない。`sendMessage` の修正を RPC の barrier と同一視しない。
- `0095` で redirect 受理時の逐次的な無効化 (`switchedToDataChannel = false` / `dataChannels` の解放) は実装済みである。本 issue は無効化と読み取りが並行した場合の排他が未実装である点だけを対象とし、`0095` の挙動を変更しない。既存の `PeerChannelRedirectInvalidationTests` は redirect 完了後の逐次呼び出しのみで、並行競合を検証していない。

## 設計方針

- `dataChannels` と `switchedToDataChannel` の読み書きを単一の排他単位へ統一する。排他単位は `PeerChannel` が所有し、`sendMessage` 側はその単位を取得して「照合から `dc.send(data)` まで」を同一区間で行う。
- `dataChannels` の全読み書き経路を同じ排他単位へ移行する。対象は上記の 5 経路とする。`sendMessage` と redirect だけを排他すると他経路のデータ競合が残るため、全経路を対象にする。
- 世代照合は補助として、取得済み `dc` の世代を送信直前に再確認するために用いる。世代照合だけでは辞書読みのデータ競合は解消しないため、主方針にはしない。
- `dataChannelOpenLock` は `MediaChannel` が OPEN 追跡状態を保護する別目的の私有ロックであり、`PeerChannel.dataChannels` は保護していない。排他単位は別に設ける。
- 公開 API の戻り値 (`SoraError.messagingError`) は既存の契約を維持する。

## 完了条件

- redirect の無効化が完了した後に開始した `sendMessage` は旧 DataChannel へ送信しない。
- `sendMessage` と redirect の無効化を並行実行しても、`dataChannels` と `switchedToDataChannel` へのデータ競合が発生しない。
- Thread Sanitizer を有効にしたテストでデータ競合が検出されない。
- 無効化後の `sendMessage` は `SoraError.messagingError` を返す。
- redirect を含む既存の messaging の挙動を壊さない。

## テスト方針

モックやスタブは使用しない。

- `sendMessage` と redirect の無効化を複数スレッドから並行実行するテストを追加し、Thread Sanitizer でデータ競合が検出されないことを確認する。
- 既存の `PeerChannelRedirectInvalidationTests` が redirect 完了後の逐次呼び出しのみであることを踏まえ、並行実行のテストを別途追加する。
- 実 Sora での redirect 競合は手動確認とし、自動テストで再現できない項目を未検証として区別する。

## 変更対象

- `Sora/PeerChannel.swift`: 排他単位の導入と `dataChannels` / `switchedToDataChannel` の全経路の移行
- `Sora/MediaChannel.swift`: `sendMessage` の照合から送信までを排他区間へ移動
- `Sora/DataChannel.swift`: 必要に応じて `dataChannels` の参照経路を移行
- `SoraTests/`: 並行実行の Thread Sanitizer テスト

## 解決方法
