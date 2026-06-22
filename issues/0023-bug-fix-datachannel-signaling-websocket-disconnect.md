# DataChannel の signaling ラベル受信を契機に WebSocket を切断する

- Priority: High
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-datachannel-signaling-websocket-disconnect
- Polished: 2026-06-22

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

- `type: switched` 受信時は `switchedToDataChannel` フラグの設定と `ignoreDisconnectWebSocket` の反映のみを行い、WebSocket 切断のスケジュールは行わない。`Sora/PeerChannel.swift:1073-1075`（`case .switched`、`switchedToDataChannel = true`、`signalingChannel.ignoreDisconnectWebSocket = ...`）は残し、`1076-1094` の `if signalingChannel.ignoreDisconnectWebSocket { ... }` ブロック全体（`asyncAfter` 呼び出しを含む）を削除する。
- DataChannel の `signaling` ラベルで最初のメッセージを受信したタイミングで、`switchedToDataChannel` が真かつ `ignoreDisconnectWebSocket` が真の場合に WebSocket 切断をスケジュールする。

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

挿入位置は `DataChannel.swift:212`（`peerChannel.handleSignalingOverDataChannel(signaling)`）の直前に、周囲のコードと同じインデント（12 スペース）で追加する。

`scheduleWebSocketDisconnectIfNeeded()` は `PeerChannel` に新たに追加する `internal` メソッドとする。`DataChannel.swift` と `PeerChannel.swift` は同一モジュール（`Sora`）内にあるため `internal` アクセスで呼び出しが可能。メソッドの本体は `DispatchQueue.main.async` でラップして main キューで直列実行する。完全な実装は以下のとおり:

```swift
// Sora/PeerChannel.swift: Properties セクションに追加
private var webSocketDisconnectScheduled: Bool = false

// Sora/PeerChannel.swift: handleSignalingOverDataChannel(_:) (現在 1109-1129 行目) の直後に追加
func scheduleWebSocketDisconnectIfNeeded() {
  DispatchQueue.main.async { [weak self] in
    guard let self else { return }

    // 1. 既にスケジュール済みであれば早期 return する
    if self.webSocketDisconnectScheduled {
      Logger.info(
        type: .peerChannel,
        message: "WebSocket disconnect already scheduled, skip")
      return
    }

    // 2. switchedToDataChannel が偽（.switched 未受信）か
    //    ignoreDisconnectWebSocket が偽であれば切断不要
    guard self.switchedToDataChannel,
          self.signalingChannel.ignoreDisconnectWebSocket else {
      Logger.info(
        type: .peerChannel,
        message:
          "switchedToDataChannel is false or ignoreDisconnectWebSocket is false,"
          + " skip scheduling WebSocket disconnect"
      )
      return
    }

    // 3. 既に切断済みであれば何もしない
    //    basicDisconnect() が先に main キューで実行されフラグがリセットされた後に
    //    本ブロックが後着した場合でも、ここで弾く
    guard self.state != .closed else {
      Logger.info(
        type: .peerChannel,
        message:
          "PeerChannel is already closed, skip scheduling WebSocket disconnect")
      return
    }

    // 4. webSocketChannel を取得
    //    フラグを立てる前に nil チェックを行い、フラグだけが立ったままになるのを防ぐ
    guard let webSocketChannel = self.signalingChannel.webSocketChannel else {
      Logger.info(
        type: .peerChannel,
        message: "webSocketChannel is nil, skip scheduling WebSocket disconnect")
      return
    }

    Logger.info(
      type: .peerChannel,
      message:
        "scheduling WebSocket disconnect after \(Self.switchedDisconnectDelay) seconds")

    // 5. フラグを立てて重複スケジュールを防止する
    self.webSocketDisconnectScheduled = true

    // 6. 遅延切断をスケジュールする
    // DataChannel 確立直後も WebSocket 経由の送信キューにメッセージが残っている可能性があるため、
    // 既存の遅延 (switchedDisconnectDelay) を維持する
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + Self.switchedDisconnectDelay
    ) { [weak self] in
      guard let self else { return }
      // PeerChannel が既に切断済みであれば WebSocket 切断は不要
      if self.state != .closed {
        Logger.info(
          type: .peerChannel,
          message: "disconnecting WebSocket after DataChannel signaling established")
        webSocketChannel.disconnect(error: nil)
      }
    }
  }
}
```

`switchedDisconnectDelay` は `PeerChannel` の `private static` 定数であり、同一クラス内のメソッドから `Self.switchedDisconnectDelay` でアクセス可能。

`PeerChannel.basicDisconnect()` の 1216 行目（`dataChannelSignalingClose = nil`）の直後に以下を追加し、万が一 PeerChannel が再利用された場合にフラグが残留しないようにする:

```swift
DispatchQueue.main.async { [weak self] in
    self?.webSocketDisconnectScheduled = false
}
```

これにより `webSocketDisconnectScheduled` への全アクセス（読み取り・書き込み・リセット）が `DispatchQueue.main.async` 内で直列化され、データ競合は発生しない。`Lock` メカニズムは `basicDisconnect` 自体の同時多重実行を防ぐためだけのものであり、`webSocketDisconnectScheduled` の保護には使えない点に注意。

`PeerChannel.swift:72-75` の `switchedDisconnectDelay` のコメント「type: switched 受信後、WebSocket 切断までの待機時間（秒）」は、切断契機が DataChannel `signaling` ラベル受信に変更されることを反映し、「DataChannel の signaling ラベル受信後、WebSocket 切断までの待機時間（秒）」に更新する。

**重複防止フラグ**:

`Sora/PeerChannel.swift` の `// MARK: - Properties` 以下、`switchedToDataChannel`（行 162）と同じスコープに `private var webSocketDisconnectScheduled: Bool = false` を追加する。フラグは `ignoreDisconnectWebSocket` が真かつ `webSocketChannel` が非 nil であることを確認した後にセットし、`.switched` 受信前に DataChannel の `signaling` メッセージが届いた場合や `webSocketChannel` が nil の場合にフラグが誤って `true` にならないよう保護する。

**スレッドセーフ性**:

`BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` は WebRTC ライブラリの内部スレッドから呼ばれる。`scheduleWebSocketDisconnectIfNeeded()` 内のフラグ読み書きと `basicDisconnect()` 内のフラグリセットはいずれも `DispatchQueue.main.async` で main キューに寄せる。両者の投入順は呼び出しタイミング依存だが、フラグを立てる直前に main キュー上で `state != .closed` を再確認することで、`basicDisconnect` 側のリセットが先に実行された後に本ブロックが後着しても早期 return され、フラグが誤って再セットされることはない。

`asyncAfter` クロージャ（`DispatchQueue.global(qos: .background)` で実行）内の `state != .closed` チェックは既存コードを踏襲する。

**後方互換性**:

`ignoreDisconnectWebSocket` が偽の場合（DataChannel シグナリングを使わない接続）は、`dataChannel.label == "signaling"` のメッセージを受信した際に `scheduleWebSocketDisconnectIfNeeded()` が呼ばれるが、`switchedToDataChannel` または `ignoreDisconnectWebSocket` が偽であれば早期 return されるため、WebSocket 切断はスケジュールされず従来の挙動を変更しない。

**DataChannel メッセージが届かない場合の挙動**:

`type: switched` を受信したが DataChannel の `signaling` ラベルでメッセージが届かない場合、WebSocket 切断はスケジュールされない。この場合、DataChannel が確立できないという別の障害として顕在化し（DataChannel 送信失敗や PeerConnection 状態変化等）、別経路で接続が失敗する。WebSocket を切り続けることは問題ない（切断スケジュールを待たず自然に失敗する）ため、タイムアウト等の追加処理は本 issue のスコープ外とする。

## テスト方針

モック・スタブは使用しない。DataChannel を実際に経由するシグナリングのテストはネットワーク接続が必要なため、以下の手動テストで確認し、結果を `## 解決方法` に記載すること:

テストに必要な Sora サーバー設定:
- `dataChannelSignaling: true`
- `ignoreDisconnectWebSocket: true`
- 接続ロール: `sendrecv`

テストケース:

- **切断タイミング確認（ignoreDisconnectWebSocket: true）**: DataChannel の `signaling` ラベルでメッセージ（`re-offer` 等）を受信した後（10 秒待機後）に WebSocket が切断されることをログで確認すること。ログには `"scheduling WebSocket disconnect after"` と `"disconnecting WebSocket after DataChannel signaling established"` が出力されること。
- **早期切断防止**: `type: switched` 受信直後（DataChannel 確立前）に WebSocket が切断されないことをログで確認すること。`type: switched` 受信後にログ出力される WebSocket disconnect 関連メッセージがないことを確認する。
- **重複スケジュール防止**: 切断スケジュールが 1 回しか実行されないこと（複数の `signaling` ラベルメッセージを受信しても 2 回目以降は `"WebSocket disconnect already scheduled, skip"` が出力されスキップされること）をログで確認すること。
- **ignoreDisconnectWebSocket: false**: `ignoreDisconnectWebSocket: false` の接続では `"switchedToDataChannel is false or ignoreDisconnectWebSocket is false, skip scheduling WebSocket disconnect"` が出力され、WebSocket 切断スケジュールが行われないことを確認すること。

## 完了条件

- DataChannel の `signaling` ラベルでメッセージを受信した後に WebSocket が切断されること。
- DataChannel 確立前に WebSocket が切断されないこと。
- 切断スケジュールが重複して実行されないこと。
- DataChannel シグナリングを使わない接続では従来どおりの挙動になること。
- `webSocketDisconnectScheduled` フラグが `basicDisconnect()` でリセットされること。
- `switchedDisconnectDelay` のコメントが「DataChannel の signaling ラベル受信後...」に更新されていること。
- `scheduleWebSocketDisconnectIfNeeded()` 内の各分岐にログ出力が実装されていること。
- 手動テストの結果を `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [FIX] DataChannel の signaling ラベル受信を契機に WebSocket を切断するようにする
    - @voluntas
  ```

## 解決方法
