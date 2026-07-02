# DataChannel の signaling ラベル受信を契機に WebSocket を切断する

- Priority: High
- Created: 2026-06-03
- Completed: 2026-06-27
- Model: Opus 4.8
- Branch: feature/fix-datachannel-signaling-websocket-disconnect
- Polished: 2026-06-22

## 目的

WebSocket シグナリングから DataChannel シグナリングへ切り替える際、WebSocket 切断の契機を `type: switched` の受信から DataChannel の `signaling` ラベルでのメッセージ受信へ変更する。`type: switched` の受信はクライアント側で DataChannel が確立済みであることを保証しないため、現状は DataChannel 確立前に WebSocket が切断され、シグナリング経路が一時的に失われる可能性がある。

## 実装内容

### PeerChannel.swift

- `.switched` case の `asyncAfter` による WebSocket 切断スケジュールブロックを削除
- `nonisolated(unsafe) var webSocketDisconnectScheduled: Bool = false` を追加
- `scheduleWebSocketDisconnectIfNeeded()` を追加（同期ガードチェーン方式、Swift 6 対策で `DispatchQueue.main.async` 不使用）
- `basicDisconnect()` で `webSocketDisconnectScheduled = false` をリセット
- `switchedDisconnectDelay` のコメントを「DataChannel の signaling ラベル受信後...」に更新

### DataChannel.swift

- `signaling` ラベル受信時、`handleSignalingOverDataChannel` の前に `scheduleWebSocketDisconnectIfNeeded()` を呼び出し

### CHANGES.md

```
- [FIX] DataChannel の signaling ラベル受信を契機に WebSocket を切断するようにする
  - @t-miya
```

## 変更ファイル一覧

- `Sora/PeerChannel.swift` — 切断契機変更、`scheduleWebSocketDisconnectIfNeeded()` 追加
- `Sora/DataChannel.swift` — signaling ラベル受信時にフック追加
- `CHANGES.md` — FIX エントリ追加
