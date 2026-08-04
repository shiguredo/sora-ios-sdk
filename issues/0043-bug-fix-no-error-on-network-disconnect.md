# 受信中にネットワークが切断されてもエラー通知がない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-no-error-on-network-disconnect
- Polished: 2026-08-04

## 目的

接続完了後にネットワークが切断された場合、 `RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しないと `disconnect()` が呼ばれず、 `onDisconnect` が発火しない。接続完了後のネットワーク切断で `onDisconnect` が確実に呼ばれるよう修正する。

## 優先度根拠

- エラー通知がなければユーザーが「なぜ映像が届かないのか」を把握できない。
- ただし再現条件がネットワーク環境・タイミングに依存するため Medium とする。

## 関連 issue

- 0024: 接続試行中の初期ロック解放漏れを修正（完了済み）。接続試行中（ `RTCPeerConnectionState.failed` 経由）の切断要求が `basicDisconnect` へ確実に到達する前提となるため、本 issue は接続完了後のみを対象とする。なお、 0024 の関連 issue セクションには本 issue について「 `RTCIceConnectionState.failed` トリガーを追加する方針」と記載されているが、これは本 issue の旧方針であり、現行方針（ `.disconnected` 検出 + 猶予タイマー方式）とは異なる。
- 0041: 同じ切断フロー（ `Lock` / `basicDisconnect` ）を扱う。未完了。
- 0042: 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する問題。本 issue の修正で接続完了後の切断が検知されてユーザーが即座に再接続する場合、サーバー側の旧セッション解放とのレースが生じやすくなる。未完了。
- 0047: 切断完了ハンドラ（ `onDisconnectComplete` ）の追加。本 issue とは独立。

## 現状

### コードの実態

`PeerChannel.swift` の `peerConnection(_:didChange newState:RTCPeerConnectionState)` は `RTCPeerConnectionState.failed` に対してのみ `disconnect()` を呼ぶ（ `PeerChannel.swift:1523-1526` ）。 `RTCPeerConnectionState.disconnected` は `default: break` で何もしない（行 1538-1539 ）。

接続完了後にネットワーク切断が発生した場合、 `RTCPeerConnectionState` が `.disconnected` になったまま `.failed` に遷移しないケースがあり、この場合 `disconnect()` が一切呼ばれず `onDisconnect` ハンドラが発火しない。接続完了後は `connectionTimer` が停止済み（ `MediaChannel.swift:487` ）で、そもそも `ConnectionTimer` は発火時に `isConnecting` チェックでスキップする設計（ `ConnectionTimer.swift:52` ）のため、バックストップとして機能しない。

`peerConnection(_:didChange newState:RTCIceConnectionState)` はログ出力のみで切断処理を行わない（ `PeerChannel.swift:1497-1504` ）。

### 失敗経路の分析

`RTCPeerConnectionState` は ICE 状態と DTLS 状態の組み合わせから導出される。このため:

- 「 `.disconnected` のまま `.failed` に遷移しない」ケースでは、 `RTCIceConnectionState` も `.disconnected` のままとなることが多い（両状態の乖離が起きるケースの有無はステップ 1 で確認する）。 `RTCIceConnectionState.failed` を監視する方針では本問題を検出できない
- `RTCIceConnectionState.failed` が発火するケースでは `RTCPeerConnectionState.failed` も連続発火し、既存ハンドラ（ `PeerChannel.swift:1523-1526` ）が既に `disconnect()` を呼ぶため、追加の検出は不要

つまり、本問題を検出できるのは「 `.disconnected` の検出」のみであり、 `.disconnected` → `.connected` の回復を阻害しない猶予タイマー方式が必要になる。

### 再現条件

- **UDP のみ遮断（本問題の主経路）**: 接続完了後に、シグナリング WebSocket （ TCP ）は生きているが ICE のみが死ぬ状態を作る。
  - iOS 実機には UDP のみを選択的に遮断する標準機能がないため、以下のいずれかで実現する:
    - Simulator を使用し、 macOS の pf で Sora サーバー宛ての outbound UDP を drop する（ Simulator はホストのネットワークスタックを共有するため有効）
    - LAN ルーターのファイアウォールで Sora サーバー宛ての UDP を遮断する（実機 Wi-Fi 環境）
  - ICE サーバー構成が TCP relay （ `turns:` ）を含む場合、 UDP を遮断しても TCP 経路が生き残り、 `.disconnected` に張り付かない。再現には TURN 不使用、または UDP-only の TURN 構成が前提
  - 遮断は接続が成立した後に開始する（接続成立前に遮断すると ICE 確立自体が失敗する）
- **DataChannel シグナリング構成でのネットワーク切断**: DataChannel シグナリングではシグナリングも ICE （ DTLS/SCTP ）上を流れるため「 WebSocket は生きている」という前提は成立しない。ネットワーク切断でシグナリング DataChannel の close が検知されると `disconnect(error: nil, reason: .dataChannelClosed)` が呼ばれ（ `DataChannel.swift:136-143` ）、 `SoraCloseEvent.ok` （正常切断扱い）で通知される分岐がある。 `.ok` で通知されるか、検知されず `.disconnected` 張り付きになるかはタイミング依存
- 機内モードへの切り替えは WebSocket も切断されるため、シグナリング経由（ `MediaChannel.swift:404-412` ）で `onDisconnect` が発火し、本問題は再現しない可能性が高い

## 設計方針

**ステップ 1 （調査）: 状態遷移の観測**

実機または Simulator で接続完了後のネットワーク切断を再現し、 `RTCPeerConnectionState` / `RTCIceConnectionState` の遷移をデバッグログ（ `PeerChannel.swift:1501-1503` 、行 1519-1521 ）で観測する。観測には `Logger.shared.level = .debug` の設定が必要（デフォルトの `.info` ではデバッグログは出力されない）。確認項目:

- ネットワーク切断時に両状態がどの順序・タイミングで遷移するか
- 両状態が乖離するケース（例: `RTCIceConnectionState` は `.connected` のまま `RTCPeerConnectionState` のみ `.disconnected` になる DTLS 起因のケース）の有無
- 切断から `.disconnected` の検出までの実測時間（ libwebrtc の内部タイマー依存。ユーザー視点の検出遅延の総量はこの時間と猶予タイマーの合計になる）
- `.disconnected` から `.failed` に遷移するまでの実測時間（猶予タイマーはこの時間より短く設定する必要がある。 `.failed` 遷移が猶予より短い環境では既存ハンドラが先に発火するため）
- `.disconnected` → `.connected` の回復が発生するケースとその時間（ iOS の Wi-Fi / セルラー移行時の一時的な切断を含む）
- シグナリング DataChannel の close 検知が猶予タイマーより先に発生するかどうか
- ネットワーク遮断と回復を繰り返した場合（フラッピング）の状態遷移

**ステップ 2 （修正）**: ステップ 1 の観測結果をもとに修正を実施する。修正の方向性の候補:

- 接続完了後（ `connectedAtLeastOnce == true` 、 `PeerChannel.swift:243` ・1534-1537 の後に `.disconnected` へ遷移した場合のみ）に猶予タイマー（ステップ 1 の観測結果に基づき決定）を開始し、経過後に `.disconnected` のままであれば `disconnect()` を呼ぶ
- タイマーは `ConnectionTimer` とは独立の新規実装とし、 `scheduleWebSocketDisconnectIfNeeded` （ `PeerChannel.swift:1217-1248` ）と同じ `DispatchQueue.global().asyncAfter` + 発火時再チェック方式とする（ `peerConnection(_:didChange:)` は libwebrtc 内部スレッドから呼ばれるため、 Foundation の `Timer` を直接使わない）。 `asyncAfter` はキャンセルできないため、スケジュールした `DispatchWorkItem` を保持して `cancel()` するか、 `webSocketDisconnectScheduled` と同じフラグ方式（ `PeerChannel.swift:201` 、 nonisolated(unsafe)）を採用する
- `.connecting` / `.connected` / `.failed` への遷移でタイマーをキャンセルし、キャンセル後に再び `.disconnected` へ遷移した場合はタイマーを再開始する（二重開始によるデッドライン延長を防ぐため、開始フラグまたはトークンで単一化する。発火時の state 再チェックだけでは、二重に発火したタイマーが両方とも `.disconnected` のままのケースを防げない）
- タイマー発火時に `RTCPeerConnectionState` を再確認し、 `.disconnected` でなければ `disconnect()` を呼ばない（発火と `.connected` 回復の競合対策。 `.connecting` への遷移でもキャンセルしない場合は、この再チェックが誤切断防止の主役になる）
- タイマーの破棄は `basicDisconnect` 内（ `nativeChannel?.close()` より前）で行う。タイマーの開始条件に破棄済みフラグの確認を含め、 close 後に遅延して届く `.disconnected` 通知で再開始しないようにする
- タイマーの開始・キャンセル・破棄のフラグは `webSocketDisconnectScheduled` と同じ `nonisolated(unsafe)` で扱う。既存フラグは「二重実行しても問題ない」前提だが、猶予タイマーは二重開始でデッドラインが延長されるため、フラグ更新の非アトミック性は発火時の再チェックと `waitDisconnect` の `isDisconnecting` ガードで吸収する

修正時の注意:

- `disconnect(error:reason:)` に渡す error は `SoraError.peerChannelError` 相当とし、 `reason` は `DisconnectReason.peerConnectionStateFailed` を流用する（新設しない。 `.peerConnectionStateFailed` と同様に Sora へ切断メッセージを送らない挙動になる）。 error を nil で渡すと `SoraCloseEvent` が `.ok` になり（ `MediaChannel.swift:562-579` ）、アプリから正常切断と区別できなくなる
- タイマー発火と `RTCPeerConnectionState.failed` （既存ハンドラ）の連続発火による `basicDisconnect` の二重実行は、 0024 の修正で追加された `Lock.waitDisconnect` の `isDisconnecting` チェック（ `PeerChannel.swift:111-112` ）で防止されている
- UDP のみ遮断の再現では WebSocket が生存しているが、 `.peerConnectionStateFailed` は `sendDisconnectMessageIfNeeded` で Sora へ切断メッセージを送らない（ `PeerChannel.swift:1357-1358` ）。このためサーバー側セッションはタイムアウトまで残存する（ 0042 の DUPLICATED-CHANNEL-ID レースへの影響は「関連 issue 」参照）
- 修正は接続完了後のネットワーク切断の検出に限定し、接続成功時の挙動は変更しない

## テスト方針

モック・スタブは使用しない。再現手順の操作を実機または Simulator で行い、以下を手動テストで確認すること:

- 接続完了後にネットワークを切断し（再現条件の「 UDP のみ遮断 」の方法による）、猶予タイマー経過後に `onDisconnect` が `SoraCloseEvent.error` として呼ばれること
- 一時的な切断（ `.disconnected` → `.connected` 回復）で `onDisconnect` が呼ばれず、接続が維持されること。回復の再現は、遮断時間を「ステップ 1 で実測した切断 → `.disconnected` 検出時間」より長く、「検出時間 + 猶予タイマー」より短く設定して復旧させる（例: 検出時間が 5 秒なら 7 秒遮断して復旧。検出に達しない短い遮断では `.disconnected` 自体が発火せずテストにならない）
- 通常の切断フロー（アプリからの `disconnect()` 呼び出し）が引き続き正常に動作すること
- 既存の `SoraTests/SignalingE2ETests.swift` のテストに影響がないこと
- 調査用に追加したデバッグログは、調査完了後に削除するか、残す場合はその理由を明記すること

## 完了条件

- 現在の libwebrtc （ m150.7871.3.0 ）で再現を確認すること。再現しない場合は、 TURN 構成（ TCP relay 混在）や host 候補（ mDNS ）による接続成立など環境要因を排除したうえで `.disconnected` 張り付きが発生しないことを確認してから close する
- 接続完了後のネットワーク切断で、 `.disconnected` が継続して `.failed` に遷移しないことを確認したうえで、猶予タイマー経過後に `onDisconnect` が `SoraCloseEvent.error` として呼ばれること
- 一時的な切断（ `.disconnected` → `.connected` 回復）で `onDisconnect` が呼ばれず、接続が維持されること
- 通常の切断フロー（アプリからの `disconnect()` 呼び出し）に影響がないこと
- 調査内容と修正内容を「解決方法」セクションに記載すること
- `CHANGES.md` の `develop` セクションに以下を追記すること:

```
- [FIX] 受信中にネットワークが切断されてもエラー通知がない問題を修正する
  - @voluntas
```

## 解決方法
