# redirect 時の旧 DataChannel 無効化と sendMessage を排他する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-redirect-datachannel-send-message-race
- Polished: {YYYY-MM-DD}

## 目的

redirect 受理時に旧 DataChannel を無効化しても、`MediaChannel.sendMessage` が排他なしで旧 DataChannel を参照するため、redirect 直後の送信が旧 DataChannel へ届く可能性がある。redirect 後の送信経路を確実に無効化する。

## 現状

- `PeerChannel` は redirect 受信時に `switchedToDataChannel` を `false` にし、`dataChannels.removeAll()` で旧 DataChannel の参照を解放する。この処理はシグナリングの受信スレッドで実行される。
- `MediaChannel.sendMessage(label:data:)` は利用者のスレッドから `peerChannel.switchedToDataChannel` と `peerChannel.dataChannels[label]` を無同期で読む。
- 両者の間に排他がないため、無効化と並行した `sendMessage` が旧 DataChannel を取得し、`dc.send(data)` まで到達し得る。
- `RPC` は `RPCChannel` の invalidate と barrier で保護されているが、`sendMessage` には同等の保護がない。

## 設計方針

- redirect 時の無効化と `sendMessage` の読み取りを同一の排他単位で直列化する。
- または `sendMessage` に世代 (`dataChannelGeneration`) の照合を追加し、無効化後は送信を拒否する。
- 既存の `dataChannelOpenLock` と同様のロック、または `dataChannels` をロック付きアクセサへ変更する。
- 公開 API の戻り値 (`SoraError.messagingError`) は既存の契約を維持する。

## 完了条件

- redirect と並行して `sendMessage` を呼んでも、旧 DataChannel へ送信されない。
- 無効化後の `sendMessage` は `SoraError.messagingError` を返す。
- redirect を含む既存の messaging の挙動を壊さない。
- 競合を再現するテストを追加すること。モックやスタブは使用しない。

## 解決方法
