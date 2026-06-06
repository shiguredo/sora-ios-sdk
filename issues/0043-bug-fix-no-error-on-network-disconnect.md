# 受信中にネットワークが切断されてもエラー通知がない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-no-error-on-network-disconnect
- Polished: 2026-06-06

## 目的

接続試行中・接続完了後いずれの状態でネットワークが切断された場合でも、エラーが通知されずアプリが待ち続けることがある。ネットワーク切断はアプリが必ず対処すべきイベントであり、`onDisconnect` が確実に呼ばれるよう修正する。

## 優先度根拠

エラー通知がなければユーザーが「なぜ映像が届かないのか」を把握できない。ただし永久にハングするわけでなく `connectionTimeout`（30 秒）のタイムアウトが最終的に発火するため High ではなく Medium とする。

## 現状

### コードの実態

`PeerChannel.swift` の `peerConnection(_:didChange newState:RTCPeerConnectionState)` は `RTCPeerConnectionState.failed` に対してのみ `disconnect()` を呼ぶ（`PeerChannel.swift:1399-1403`）。`RTCPeerConnectionState.disconnected` は `default: break` で何もしない。

ネットワーク切断時、`RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しないケースがあり、この場合 `disconnect()` が一切呼ばれず `onDisconnect` ハンドラが発火しない。

`peerConnection(_:didChange newState:RTCIceConnectionState)` はログ出力のみで切断処理を行わない（`PeerChannel.swift:1373-1380`）。

`MediaChannelHandlers` に `onFailure` というプロパティは存在しない。エラー通知に使う API は `onDisconnect: ((SoraCloseEvent) -> Void)?` および `onDisconnectLegacy: ((Error?) -> Void)?` の 2 つのみである。

### 再現条件

- 接続試行中または接続完了後にネットワークを切断する（機内モードへの切り替えまたは Wi-Fi 無効化）
- `RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しない場合に発生
- 再現性はネットワーク環境・タイミングに依存

## 設計方針

推奨方針は **方針 B**（ICE レベルの失敗検出）。方針 A は `disconnected` → `connected` 回復を阻害するリスクがあるため採用前に十分な検証が必要。

**方針 A**: `peerConnection(_:didChange newState:RTCPeerConnectionState)` の `.disconnected` ケースで `disconnect()` を呼ぶ。ただしコメント（`PeerChannel.swift:1404-1416`）にある通り「`disconnected` → `connected` へ遷移する可能性がある」ため、即座の切断は完了条件「`disconnected → connected` 遷移が阻害されないこと」と矛盾する。タイムアウト付き再試行（例: 5 秒間 `failed` または `connected` に遷移しなければ切断）などの工夫が必要になる

**方針 B**: `peerConnection(_:didChange newState:RTCIceConnectionState)` の `failed` ケースで `disconnect()` を呼ぶ（`PeerChannel.swift:1373-1380` の実装を拡張）。`RTCIceConnectionState.failed` は `RTCPeerConnectionState.disconnected` とは独立した状態であり、`connected` への回復が見込めない確定的な失敗を示すため、即座の `disconnect()` 呼び出しが安全

**方針 C**: `connectionTimeout` を短縮する暫定対応。根本解決にはならない

## 完了条件

- ネットワーク切断後（機内モード切り替え等）に 30 秒を待たずに `onDisconnect` が呼ばれること
- 通常の切断フロー（アプリからの `disconnect()` 呼び出し）に影響がないこと
- `RTCPeerConnectionState.disconnected` → `connected` 遷移（一時的な切断から回復するケース）が阻害されないこと
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] 受信中にネットワークが切断されてもエラー通知がない問題を修正する
  - @voluntas
```
