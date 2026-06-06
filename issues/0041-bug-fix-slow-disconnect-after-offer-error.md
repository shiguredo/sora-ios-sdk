# offer 受信後にエラーとなった場合すぐに切断されない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-slow-disconnect-after-offer-error
- Polished: 2026-06-06

## 目的

SDP の設定でエラーが発生した場合、切断完了までに約 30 秒かかる。SDP エラーは接続が継続できない致命的なエラーであり、30 秒間ユーザーが応答なしの状態で待たされることになる。エラー発生時は即座に切断処理が完了するよう修正する。

## 優先度根拠

30 秒の遅延はユーザーにとって「アプリが固まった」と見える致命的な UX 劣化だが、接続自体は最終的に切断されるため Medium とする。High に上げるには実際のユーザー報告や接続が永久にハング（切断されない）するケースの確認が必要。

## 現状

### 再現手順

1. iOS SDK が対応していない SDP プロファイルを Sora サーバーが提示する接続を行う（例: iOS が未対応の AV1 profile を指定）
2. 以下のエラーログが出力される

```
PeerChannel DEBUG: failed setting remote description: (Failed to set remote offer sdp: Failed to set remote video description send parameters for m-section with mid='video_...')
```

3. 接続エラーで終了するまでに約 30 秒かかる

再現には接続ロール（`sendonly` / `sendrecv` 等）の指定が必要。`setRemoteDescription` が呼ばれるのは受信側のロールであるため、`sendrecv` または `recvonly` を使うこと。

### 確認済み環境

- libwebrtc バージョン: 要確認（現在の SDK は m148.7778.7.0 を使用。最新版での再現確認が必要）

### コードの実態

30 秒遅延の根本原因は `MediaChannel.swift` の `connectionTimer` によるタイムアウトであると考えられる。

`MediaChannel.basicConnect()` では `peerChannel.connect { ... }` を呼び出した後、`connectionTimer.run { ... }` が `configuration.connectionTimeout`（デフォルト 30 秒）で起動する（`MediaChannel.swift:503`）。`connectionTimer.stop()` は `peerChannel.connect` の完了ハンドラ内（`MediaChannel.swift:481`）と `internalDisconnect()` 内（`MediaChannel.swift:540`）の 2 箇所で呼ばれる。前者の完了ハンドラは `PeerChannel.finishConnecting()` または `basicDisconnect()` で `onConnect` が呼ばれることで実行される。

`setRemoteDescription` エラー後のコードパスでは `handler(nil, error)` → `lock.unlock()` + `disconnect()` → `basicDisconnect()` まで到達すると、`connectionTimer.stop()` に至る経路が 2 つある。

- 経路 A: `basicDisconnect()` 内の `onConnect?(error)` → `MediaChannel.basicConnect` 内の `peerChannel.connect` コールバック（`MediaChannel.swift:481`）→ `connectionTimer.stop()`
- 経路 B: `basicDisconnect()` 内の `internalHandlers.onDisconnect?` → `MediaChannel.internalDisconnect()`（`MediaChannel.swift:408` で設定）→ `connectionTimer.stop()`（`MediaChannel.swift:540`）

実際に 30 秒かかるということはこれらの経路でいずれかの処理が実行されていない可能性がある。特定のコードパスで `lock.unlock()` または `disconnect()` が呼ばれない・または遅延する箇所が存在するかを確認する必要がある。

## 設計方針

1. 現在の libwebrtc m148 環境で再現を確認する。再現しない場合は close する
2. 再現する場合は `setRemoteDescription` エラー後から `connectionTimer.stop()` が呼ばれるまでのコードパスをデバッグログで追い、どの処理で遅延が発生するかを特定する
3. 原因が特定された箇所に修正を加え、エラー発生後に確実かつ即座に切断処理が完了するようにする。変更対象候補は `PeerChannel.swift` の `createAndSendAnswer` のエラーハンドリングおよび `MediaChannel.swift` の `connectionTimer` 停止タイミング

## 完了条件

- m148 環境で再現を確認すること（再現しない場合は close）
- 上記再現手順でエラー発生後の切断が 30 秒かからず（1 秒以内程度で）完了すること（`connectionTimer` タイムアウト待ちではなく即時エラー処理が走ることを確認できれば十分。ネットワーク切断処理自体の遅延は考慮しない）
- 通常の正常系接続・切断フローに影響がないこと
- 遅延の根本原因（どの処理パスで `connectionTimer.stop()` が呼ばれなかったか）が本 issue に記録されること
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] offer 受信後にエラーとなった場合すぐに切断されない問題を修正する
  - @voluntas
```
