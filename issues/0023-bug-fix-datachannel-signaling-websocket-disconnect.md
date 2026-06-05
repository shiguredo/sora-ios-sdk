# DataChannel の signaling ラベル受信を契機に WebSocket を切断する

- Priority: High
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-datachannel-signaling-websocket-disconnect

## 目的

WebSocket シグナリングから DataChannel シグナリングへ切り替える際、WebSocket 切断の契機を `type: switched` の受信から DataChannel の `signaling` ラベルでのメッセージ受信へ変更する。`type: switched` の受信はクライアント側で DataChannel が確立済みであることを保証しないため、現状は DataChannel 確立前に WebSocket が切断され、シグナリング経路が一時的に失われる可能性がある。

## 優先度根拠

- DataChannel 確立前に WebSocket が切断されるとシグナリング経路が失われる可能性があるバグであり、接続信頼性に直接関わる。
- DataChannel への切り替え時のシグナリング経路に関しては、過去に re-answer の送信失敗という類似の実害が発生した領域であり、再発リスクが高い。よって High とする。

## 現状

`.switched` 受信処理で `switchedToDataChannel = true` を立て、`ignoreDisconnectWebSocket` が真の場合に `asyncAfter` で `switchedDisconnectDelay` (10 秒) 後に WebSocket を切断するようスケジュールしている。

```swift
// Sora/PeerChannel.swift:1073-1094
case .switched(let switched):
  switchedToDataChannel = true
  signalingChannel.ignoreDisconnectWebSocket = switched.ignoreDisconnectWebSocket ?? false
  if signalingChannel.ignoreDisconnectWebSocket {
    if let webSocketChannel = signalingChannel.webSocketChannel {
      // DataChannel への切り替え後でも、まだ WebSocket 経由で送信中のメッセージが存在する可能性がある。
      // そのため、余裕を持って指定時間（秒）後に WebSocket を切断するようスケジュールしている。
      // ...
      DispatchQueue.global(qos: .background).asyncAfter(
        deadline: .now() + Self.switchedDisconnectDelay
      ) { [weak self] in
        guard let self else { return }
        // PeerChannel が切断状態の場合は、WebSocket Channel はすでに切断されており、
        // disconnect を呼び出す必要がないため、PeerChannel の状態をチェックしている。
        if state != .closed {
          webSocketChannel.disconnect(error: nil)
        }
      }
    }
  }
```

この切断契機は WebSocket 経由の `type: switched` 受信であり、クライアント側 DataChannel (`signaling` ラベル) の確立を待っていない。DataChannel の `signaling` ラベルのメッセージ受信は次の経路を経て `handleSignalingOverDataChannel` で処理される。

```swift
// Sora/DataChannel.swift:206-217
case "signaling", "push", "notify":
  if let messageJSON {
    peerChannel.internalHandlers.onReceiveSignalingJSON?(messageJSON)
  }
  switch Signaling.decode(data) {
  case .success(let signaling):
    peerChannel.handleSignalingOverDataChannel(signaling)
  case .failure(let error):
    Logger.error(
      type: .dataChannel,
      message: "decode failed (\(error.localizedDescription)) => ")
  }
```

```swift
// Sora/PeerChannel.swift:1109
func handleSignalingOverDataChannel(_ signaling: Signaling) {
```

つまり、`type: switched` から 10 秒以内に DataChannel での `signaling` メッセージ受信が間に合わない場合、DataChannel 経由のシグナリングが確立する前に WebSocket が切断され得る。

## 設計方針

- WebSocket 切断の契機を「`type: switched` 受信」から「DataChannel の `signaling` ラベルでのメッセージ受信」へ変更する。
- `type: switched` 受信時には `switchedToDataChannel` フラグの設定や `ignoreDisconnectWebSocket` の反映など切り替え状態の更新のみを行い、WebSocket 切断のスケジュールは行わない。
- DataChannel の `signaling` ラベルで最初のメッセージを受信したタイミングで、`ignoreDisconnectWebSocket` が真の場合に WebSocket 切断をスケジュールする。
- まだ WebSocket 経由で送信中のメッセージが残る可能性に配慮し、切断には既存の遅延 (`switchedDisconnectDelay`) を維持する。切断時には `state != .closed` を確認してから `disconnect` を呼ぶ既存のガードも維持する。
- WebSocket を一度しか切断しないよう、切断スケジュールが重複しないガード (フラグ等) を `PeerChannel` に追加する。
- DataChannel シグナリングを使わない接続 (`ignoreDisconnectWebSocket` が偽) の場合の挙動は変更しない。後方互換性を維持する。

## 完了条件

- DataChannel の `signaling` ラベルでメッセージを受信した後に WebSocket が切断されること。
- DataChannel 確立前に WebSocket が切断されないこと。
- 切断スケジュールが重複して実行されないこと。
- DataChannel シグナリングを使わない接続では従来どおりの挙動になること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [FIX] DataChannel の signaling ラベル受信を契機に WebSocket を切断するようにする
    - @担当者
  ```

## 解決方法
