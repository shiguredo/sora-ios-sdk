# 変更履歴

- UPDATE
    - 下位互換がある変更
- ADD
    - 下位互換がある追加
- CHANGE
    - 下位互換のない変更
- FIX
    - バグ修正

## 1.0.1

- [CHANGE] システム条件を更新した
    - Xcode 8.1 以降 -> 8.3.2 以降
    - Swift 3.0.1 -> 3.1
    - Sora 17.02 -> 17.04
- [UPDATE] SoraApp の Cartfile で利用する shiguredo/sora-ios-sdk を 1.0.1 にアップデートした

## 1.0.0

- [CHANGE] WebRTC M57 に対応した

- [CHANGE] 対応アーキテクチャを arm64 のみにした

- [CHANGE] マルチストリームに対応した

- [CHANGE] シグナリング: "notify" に対応した

- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "stats" への対応を廃止した

- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "connect" の "access_token" パラメーターを "metadata" に変更した

- [CHANGE] API: ArchiveFinished: 削除した

- [CHANGE] API: ArchiveFailed: 削除した

- [CHANGE] API: MediaConnection: MediaStream を複数保持するようにした

- [CHANGE] API: MediaConnection: ``multistreamEnabled`` プロパティを追加した

- [CHANGE] API: MediaConnection: 次の変数の型を変更した
  
  - ``webSocketEventHandlers``: ``WebSocketEventHandlers?`` --> ``WebSocketEventHandlers``
  - ``signalingEventHandlers``: ``SignalingEventHandlers?`` --> ``SignalingEventHandlers``
  - ``peerConnectionEventHandlers``: ``PeerConnectionEventHandlers?`` --> ``PeerConnectionEventHandlers``

- [CHANGE] API: MediaConnection: ``connect(accessToken:timeout:handler:)`` メソッドの型を ``connect(metadata:timeout:handler:)`` に変更した

- [CHANGE] API: MediaConnection, MediaStream: 次の API を MediaStream に移行した
  
  - ``var videoRenderer``

  - ``func startConnectionTimer(timeInterval:handler:)``

- [CHANGE] API: MediaConnection.State: 削除した

- [CHANGE] API: MediaOption.AudioCodec: ``unspecified`` を ``default`` に変更した

- [CHANGE] API: MediaOption.VideoCodec: ``unspecified`` を ``default`` に変更した

- [CHANGE] API: MediaPublisher: ``autofocusEnabled`` プロパティを追加した

- [CHANGE] API: MediaStream: RTCPeerConnection のラッパーではなく、 RTCMediaStream のラッパーに変更した

- [CHANGE] API: MediaStream: ``startConnectionTimer(timeInterval:handler:)``: タイマーを起動した瞬間もハンドラーを実行するようにした

- [CHANGE] API: MediaStream.State: 削除した

- [CHANGE] API: PeerConnection: RTCPeerConnection のラッパーとして追加した

- [CHANGE] API: SignalingConnected: 削除した

- [CHANGE] API: SignalingCompleted: 削除した

- [CHANGE] API: SignalingDisconnected: 削除した

- [CHANGE] API: SignalingFailed: 削除した

- [CHANGE] API: StatisticsReport: RTCStatsReport の変更 (名前が RTCLegacyStatsReport に変更された) に伴い削除した

- [CHANGE] API: VideoView: 映像のアスペクト比を保持するようにした

- [UPDATE] API: MediaCapturer: 同一の RTCPeerConnectionFactory で再利用するようにした

- [UPDATE] API: MediaCapturer: 映像トラック名と音声トラック名を自動生成するようにした

- [UPDATE] API: VideoRenderer: 描画処理をメインスレッドで実行するようにした

- [UPDATE] API: VideoView: UI の設計に Nib ファイルを利用するようにした

- [UPDATE] API: VideoView: バックグラウンド (ビューがキーウィンドウに表示されていない) では描画処理を中止するようにした

- [ADD] API: BuildInfo: 追加した

- [ADD] API: ConnectionController: 追加した

- [ADD] API: Connection: 次の API を追加した
  
  - ``var numberOfConnections``

  - ``func onChangeNumberOfConnections(handler:)``

- [ADD] API: Connection, MediaConnection, MediaStream, PeerConnection: 次のイベントで (NotificationCenter による) 通知を行うようにした

  - onConnect
  - onDisconnect
  - onFailure

- [ADD] API: WebSocketEventHandlers, SignalingEventHandlers, PeerConnectionEventHandlers: イニシャライザーを追加した

- [FIX] シグナリング: 音声コーデック Opus を指定するためのパラメーターの間違いを修正した

- [FIX] 接続解除後にイベントログを記録しようとして落ちる現象を修正した

- [FIX] 接続失敗時にデバイスを初期化しようとして落ちる現象を修正した (接続成功時のみ初期化するようにした)

- [FIX] 接続試行中にエラーが発生して失敗したにも関わらず、成功と判断されてしまう場合がある現象を修正した

- [FIX] API: MediaConnection: 接続解除後もタイマーが実行されてしまう場合がある現象を修正した (タイマーに関する API は MediaStream に移動した)

- [FIX] API: PeerConnection: 接続失敗時でもタイムアウト時のイベントハンドラが呼ばれる現象を修正した

## 0.1.0

**0.1.0 リリース**
