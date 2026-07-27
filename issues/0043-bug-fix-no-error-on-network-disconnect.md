# 受信中にネットワークが切断されてもエラー通知がない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-no-error-on-network-disconnect
- Polished: 2026-07-27

## 目的

接続試行中・接続完了後いずれの状態でネットワークが切断された場合でも、エラーが通知されずアプリが待ち続けることがある。ネットワーク切断はアプリが必ず対処すべきイベントであり、`onDisconnect` が確実に呼ばれるよう修正する。

## 優先度根拠

エラー通知がなければユーザーが「なぜ映像が届かないのか」を把握できない。接続試行中は `connectionTimeout`（30 秒）のタイムアウトがバックストップとして機能するが、接続完了後は `connectionTimer` が停止される（`MediaChannel.swift:487`）ため、`RTCPeerConnectionState` が `.disconnected` のまま `.failed` に遷移しない場合 `onDisconnect` が永久に呼ばれない可能性がある。ただし再現条件がネットワーク環境・タイミングに依存するため Medium とする。

## 現状

### コードの実態

`PeerChannel.swift` の `peerConnection(_:didChange newState:RTCPeerConnectionState)` は `RTCPeerConnectionState.failed` に対してのみ `disconnect()` を呼ぶ（`PeerChannel.swift:1493-1496`）。`RTCPeerConnectionState.disconnected` は `default: break` で何もしない。

ネットワーク切断時、`RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しないケースがあり、この場合 `disconnect()` が一切呼ばれず `onDisconnect` ハンドラが発火しない。

`peerConnection(_:didChange newState:RTCIceConnectionState)` はログ出力のみで切断処理を行わない（`PeerChannel.swift:1467-1474`）。

`MediaChannelHandlers` に `onFailure` というプロパティは存在しない。エラー通知に使う API は `onDisconnect: ((SoraCloseEvent) -> Void)?` および `onDisconnectLegacy: ((Error?) -> Void)?` の 2 つのみである。

### 再現条件

- 接続試行中または接続完了後にネットワークを切断する（機内モードへの切り替えまたは Wi-Fi 無効化）
- `RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しない場合に発生
- 再現性はネットワーク環境・タイミングに依存

## 設計方針

推奨方針は **方針 B**（ICE レベルの失敗検出）。方針 A は `disconnected` → `connected` 回復を阻害するリスクがあるため採用前に十分な検証が必要。

**方針 A**: `peerConnection(_:didChange newState:RTCPeerConnectionState)` の `.disconnected` ケースで `disconnect()` を呼ぶ。ただしコメント（`PeerChannel.swift:1498-1503`）にある通り「`disconnected` → `connected` へ遷移する可能性がある」ため、即座の切断は完了条件「`disconnected → connected` 遷移が阻害されないこと」と矛盾する。タイムアウト付き再試行（例: 5 秒間 `failed` または `connected` に遷移しなければ切断）などの工夫が必要になる

**方針 B**: `peerConnection(_:didChange newState:RTCIceConnectionState)` の `failed` ケースで `disconnect()` を呼ぶ（`PeerChannel.swift:1467-1474` の実装を拡張）。`RTCIceConnectionState.failed` は ICE agent が接続確立を諦めたことを示す終端状態であり、ICE restart を実装していない本 SDK では `connected` への回復が見込めない。`RTCPeerConnectionState.disconnected` は一時的状態であり得るため即座の切断が安全ではないが、ICE failed であれば即座の `disconnect()` 呼び出しが安全

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
