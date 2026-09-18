# redirect 処理の旧 transport 無効化が到達しない防御コードであることを明記する

- Created: 2026-09-18
- Completed:
- Priority: Low
- Branch: feature/refactor-document-unreachable-redirect-invalidation
- Polished:

## 目的

redirect は Sora の仕様上 `connect` への応答としてのみ送信され、WebRTC 接続確立後にサーバーからクライアントへ送信して別のノードへリダイレクトさせることはできない。redirect の時点では `MediaStream` も DataChannel も RPC もまだ生成されていないため、`PeerChannel` の redirect 受理処理にある旧 transport の無効化は対象が常に空であり、実際には何も無効化しない。この前提がコードにもテストにも書かれていないため、redirect が接続後にも起こり得ると読めてしまい、production では発生しない状態を手動で作るテストが残っている。前提を明記し、将来の読み手と、redirect の競合を扱う issue の判断材料にする。

この issue では、無効化コードを残すか削除するかを決めずに、両案と判断材料を残す。

## 現状

`Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` の `.redirect` ケースは、旧 transport の無効化として `switchedToDataChannel = false`、`dataChannels.removeAll()`、`rpcChannel.invalidate(reason:)` と `rpcChannel = nil`、`for stream in streams { stream.terminate() }`、`streams.removeAll()` を行う。しかし redirect は `connect` への応答として、`didAdd` / `didOpen` より前に届くため、これらの対象は初期状態のままである。

- `streams` へ追加するのは `PeerChannel.add(stream:)` であり、呼び出し元は `initializeSenderStream(mid:)` と `peerConnection(_:didAdd:)` で、どちらも remote offer の受信後にしか実行されない。redirect 時は `streams` が空なので `stream.terminate()` は 1 度も呼ばれず、`redirect: terminated \(streams.count) streams` のログも出力されない (実機の redirect 確認でも出力されず、`streams` が空だった)。
- `dataChannels` は `peerConnection(_:didOpen:)` で追加され、`switchedToDataChannel` も接続確立後の `switched` 受信で true になるため、redirect 時は空と false のままである。
- `rpcChannel` は `peerConnection(_:didOpen:)` で生成されるため redirect 時は nil で、`redirect: invalidated rpcChannel` のログも出力されない。

`SoraTests/PeerChannelRedirectInvalidationTests.swift` は `peerChannel.switchedToDataChannel = true` を手動で代入して「リダイレクト前の接続済み状態」を作ってから redirect を入力しており、production では到達しない状態を検証している。この意図がコメントから読み取れない。

なお、空の状態への書き込みでも `MediaChannel.sendMessage` と RPC の読み取りとは無同期であるため、`0127` と `0135` が扱う競合は成立する。無効化そのものを削除する判断をする場合は、この 2 件との整合を取る必要がある。

## 設計方針

無効化を残すか削除するかは実装時に決める。どちらの案でも、redirect が接続確立前にのみ発生することと、無効化の対象が常に空であることをコードとテストに明記する。

### 案 1: 防御コードとして残し、到達しないことを明記する

- `Sora/PeerChannel.swift` の redirect 受理処理に、redirect が接続確立前にのみ発生すること、無効化の対象 (`streams` / `dataChannels` / `rpcChannel`) が常に空であること、防御として残す理由 (将来 redirect が別のタイミングで送られる仕様になった場合に旧 transport を確実に無効化する) を書く。
- `SoraTests/PeerChannelRedirectInvalidationTests.swift` に、production では発生しない状態を防御の検証として作っていることを書く。
- 判断材料: 無効化は実行されないが、空の状態への書き込みが `MediaChannel.sendMessage` と RPC の読み取りと競合する経路は残る。防御を残す場合は、この競合の解消 (`0135`) を維持する必要がある。

### 案 2: 到達しない無効化を削除する

- `dataChannels` の参照解放、`rpcChannel` の invalidate と nil 代入、`streams` の `terminate()` と `streams.removeAll()`、および `redirect: terminated N streams` と `redirect: invalidated rpcChannel` のログを削除する。
- 残すのは redirect に必要な `dataChannelGeneration` の更新、`isRedirecting`、`cancelDisconnectTimer()`、`nativeChannel?.close()`、`signalingChannel.redirect(location:)` とする。
- 判断材料: 空の状態への書き込みが消えるため、`0135` が扱う競合の経路も消える。`0135` / `0127` の扱い (競合の解消方法と、close してよいか) を合わせて決める必要がある。将来 redirect が接続後に送られる仕様になった場合は旧 stream の終端が無いままになるため、その時点で設計し直すことになる。

## 完了条件

- `Sora/PeerChannel.swift` と `SoraTests/PeerChannelRedirectInvalidationTests.swift` を読むと、redirect が接続確立前にのみ発生することと、無効化の対象が常に空であることが分かる。
- 案 1 を採る場合は、防御として残す理由と、対象が常に空であることによる競合の扱いが書かれている。
- 案 2 を採る場合は、削除した無効化に依存していた `0127` / `0135` の扱いが issue に記録されている。

## 解決方法
