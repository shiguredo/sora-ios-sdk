# DataChannel の signaling ラベル受信を契機に WebSocket を切断する

- Priority: High
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-datachannel-signaling-websocket-disconnect
- Polished: 2026-06-06

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
      DispatchQueue.global(qos: .background).asyncAfter(
        deadline: .now() + Self.switchedDisconnectDelay
      ) { [weak self] in
        guard let self else { return }
        if state != .closed {
          webSocketChannel.disconnect(error: nil)
        }
      }
    }
  }
```

この切断契機は WebSocket 経由の `type: switched` 受信であり、クライアント側 DataChannel `signaling` ラベルの確立を待っていない。DataChannel のメッセージ受信は次の経路を経て `handleSignalingOverDataChannel` で処理される。

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

## 設計方針

**WebSocket 切断の契機変更**:

- `type: switched` 受信時は `switchedToDataChannel` フラグの設定と `ignoreDisconnectWebSocket` の反映のみを行い、WebSocket 切断のスケジュールは行わない。`Sora/PeerChannel.swift:1073-1094` の `if signalingChannel.ignoreDisconnectWebSocket { ... }` ブロック全体（`asyncAfter` 呼び出しを含む）を削除する。
- DataChannel の `signaling` ラベルで最初のメッセージを受信したタイミングで、`ignoreDisconnectWebSocket` が真の場合に WebSocket 切断をスケジュールする。

**契機として `signaling` ラベルを選ぶ根拠**:

`Sora/DataChannel.swift:206` では `"signaling"`, `"push"`, `"notify"` の 3 ラベルが同一 case に束ねられているが、WebSocket 切断の契機として `signaling` ラベルを選ぶ理由は以下のとおり。Sora サーバーは DataChannel 切り替え後の最初のシグナリングメッセージ（`re-offer` 等）を `signaling` ラベルの DataChannel で送ってくる。このメッセージが届いた時点で DataChannel シグナリング経路が確立済みであることが確実となる。`push` / `notify` は通知メッセージであり、切り替え前後いずれのタイミングでも届く可能性があるため、DataChannel シグナリング確立の証拠としては不適切。

**フック場所の実装方法**:

`Sora/DataChannel.swift:206` の `case "signaling", "push", "notify":` ブロック内で、`decode` が成功した `case .success(let signaling):` パスに入ったあと、`dataChannel.label == "signaling"` の場合のみ WebSocket 切断をスケジュールする。既存の `guard let peerChannel else { return }` （行 151-154）を通過した後のスコープに挿入するため、`peerChannel` は非 optional として利用できる。具体的には `peerChannel.handleSignalingOverDataChannel(signaling)` の呼び出し**前**に以下を追加する:

変更後の `case .success` ブロック全体は以下のようになる:

```swift
case .success(let signaling):
  // signaling ラベルの DataChannel でメッセージを受信した時点を
  // DataChannel シグナリング確立の証拠として WebSocket 切断をスケジュールする
  if dataChannel.label == "signaling" {
    peerChannel.scheduleWebSocketDisconnectIfNeeded()
  }
  peerChannel.handleSignalingOverDataChannel(signaling)
```

`decode` 失敗パス（`case .failure`）では DataChannel の健全性を確認できないため、WebSocket 切断のトリガーとしない（`case .success` 内のみで発火する）。

`scheduleWebSocketDisconnectIfNeeded()` は `PeerChannel` に新たに追加する `internal` メソッドとする。`DataChannel.swift` と `PeerChannel.swift` は同一モジュール（`Sora`）内にあるため `internal` アクセスで `peerChannel.scheduleWebSocketDisconnectIfNeeded()` の呼び出しが可能。メソッドの本体は `DispatchQueue.main.async` でラップして main キューで直列実行し、以下を行う:
1. 重複防止フラグ `webSocketDisconnectScheduled` が `true` であれば早期 return する
2. フラグを `true` にセットする
3. `ignoreDisconnectWebSocket` が偽であれば return する
4. `signalingChannel.webSocketChannel` をメソッド呼び出し時点で取得し、`nil` であれば return する（取得したインスタンスを asyncAfter クロージャでキャプチャする）
5. `DispatchQueue.global(qos: .background).asyncAfter` で `Self.switchedDisconnectDelay` (10 秒、`PeerChannel.swift:75` の `private static` 定数。同クラス内なので `Self.` でアクセス可能) 後に `[weak self]` ガードと `state != .closed` チェックを維持して `webSocketChannel.disconnect(error: nil)` をスケジュールする（DataChannel 確立直後も WebSocket 経由の送信キューにメッセージが残っている可能性があるため、既存の遅延を維持する）

**重複防止フラグ**:

`Sora/PeerChannel.swift` に `var webSocketDisconnectScheduled: Bool = false` を追加する。宣言場所は `switchedToDataChannel` （行 162）と同じスコープ（`// MARK: - Properties` 以下）とする。`scheduleWebSocketDisconnectIfNeeded()` は main キューで呼ばれるため、このフラグへのアクセスも main キュー上で完結する。

**スレッドセーフ性**:

`BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` は WebRTC ライブラリの内部スレッドから呼ばれるため、`scheduleWebSocketDisconnectIfNeeded()` 呼び出し自体は内部スレッドで行われる。メソッド本体を `DispatchQueue.main.async` でラップすることで、フラグのチェック・セットおよび `asyncAfter` の発行はすべて main キューで直列実行される。`asyncAfter` クロージャ（`DispatchQueue.global(qos: .background)` で実行）内の `state != .closed` チェックは既存と同様に `[weak self]` ガードのみとする。

**後方互換性**:

`ignoreDisconnectWebSocket` が偽の場合（DataChannel シグナリングを使わない接続）は、`dataChannel.label == "signaling"` のメッセージを受信した際に `scheduleWebSocketDisconnectIfNeeded()` が呼ばれるが、メソッド内の手順 3 の `ignoreDisconnectWebSocket` チェックで早期 return されるため、WebSocket 切断はスケジュールされず従来の挙動を変更しない。

**DataChannel メッセージが届かない場合の挙動**:

`type: switched` を受信したが DataChannel の `signaling` ラベルでメッセージが届かない場合、WebSocket 切断はスケジュールされない。この場合、DataChannel が確立できないという別の障害として顕在化し（DataChannel 送信失敗や PeerConnection 状態変化等）、別経路で接続が失敗する。WebSocket を切り続けることは問題ない（切断スケジュールを待たず自然に失敗する）ため、タイムアウト等の追加処理は本 issue のスコープ外とする。

## テスト方針

モック・スタブは使用しない。DataChannel を実際に経由するシグナリングのテストはネットワーク接続が必要なため、以下の手動テストで確認し、結果を `## 解決方法` に記載すること:

- `ignoreDisconnectWebSocket: true` の接続で DataChannel の `signaling` ラベルでメッセージを受信した後（10 秒待機後）に WebSocket が切断されることをログで確認すること。
- `type: switched` 受信直後（DataChannel 確立前）に WebSocket が切断されないことをログで確認すること。
- 切断スケジュールが 1 回しか実行されないこと（複数の `signaling` ラベルメッセージを受信しても 2 回目以降はスキップされること）をログで確認すること。
- `ignoreDisconnectWebSocket: false` の接続では WebSocket 切断スケジュールが行われないことを確認すること。

## 完了条件

- DataChannel の `signaling` ラベルでメッセージを受信した後に WebSocket が切断されること。
- DataChannel 確立前に WebSocket が切断されないこと。
- 切断スケジュールが重複して実行されないこと。
- DataChannel シグナリングを使わない接続では従来どおりの挙動になること。
- 手動テストの結果を `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [FIX] DataChannel の signaling ラベル受信を契機に WebSocket を切断するようにする
    - @voluntas
  ```

## 解決方法
