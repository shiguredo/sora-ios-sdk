# 変更履歴

- UPDATE
    - 下位互換がある変更
- ADD
    - 下位互換がある追加
- CHANGE
    - 下位互換のない変更
- FIX
    - バグ修正

## 1.2.1

### FIX

- API: ConnectionController: 指定した映像・音声コーデックが UI とシグナリングに反映されない現象を修正した

## 1.2.0

### CHANGE

- WebRTC M60 に対応した
- Bitcode に対応した
- スナップショットに対応した
- リンクするフレームワークに SDWebImage.framework を追加した
- API: Event.EventType: 次のケースを追加した
    - ``case Snapshot``
- API: MediaOption: 次のプロパティを追加した
    - ``var snapshotEnabled``
- API: SignalingEventHandlers: 次のメソッドを追加した
    - ``func onSnapshot(handler: (SignalingSnapshot) -> Void)``
- API: SignalingSnapshot: 追加した
- API: Snapshot: 追加した
- API: VideoFrame
    - ``var width``: ``Int32`` -> ``Int``
    - ``var height``: ``Int32`` -> ``Int``
    - ``var timestamp``: ``CMTime`` -> ``CMTime?``
- API: VideoFrameHandle: 次のプロパティ名を変更した
    - ``case webRTC`` -> ``case WebRTC``
- API: VideoFrameHandle: 次のプロパティを追加した
    - ``case snapshot``
- API: VideoView: スナップショットの描画に対応した
- API: ConnectionController: スナップショットの項目を追加した

## 1.1.0

### CHANGE

- CircleCI を利用した自動ビルドを追加
- examples を削除
- WebRTC M59 に対応した
- ディレクトリ構造を変更し、プロジェクトのファイルをトップレベルに移動した
- シグナリング "notify" に対応した
- イベントログに接続エラーの詳細を出力するようにした
- 次の不要なファイルを削除した
    - ``JSON.swift``
- API: Attendee: 追加した
- API: BuildInfo: 次のプロパティを削除した
    - ``var VP9Enabled``
- API: Connection: 次のプロパティとメソッドを削除した
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
- API: ConnectionError: ``var description`` を追加した
- API: ConnectionController: ビットレートの設定項目を追加した
- API: ConnectionController: イベントログの画面を追加した
- API: ConnectionController: Cancel ボタンを Back ボタンに変更した
- API: Event.EventType: ``ConnectionMonitor`` を追加した
- API: MediaConnection: 次のプロパティとメソッドを追加した
    - ``var numberOfConnections``
    - ``func onAttendeeAdded(handler:)``
    - ``func onAttendeeRemoved(handler:)``
    - ``func onChangeNumberOfConnections(handler:)``
- API: MediaStreamRole: 削除した
- API: Role: 追加した
- API: PeerConnection: 接続状態に関わらず WebSocket のイベントハンドラを実行するようにした
- API: SignalingEventHandlers: ``func onNotify(handler:)`` を追加した
- API: SignalingEventType: 追加した
- API: SignalingNotify: 追加した
- API: SignalingRole: 追加した
- API: VideoFrame
    - ``var width``: ``Int`` -> ``Int32``
    - ``var height``: ``Int`` -> ``Int32``
- API: ConnectionController: リファクタリングを行った
- API: ConnectionController: VP9 の有効・無効を示すセルを削除した

### FIX

- Sora サーバーの URL のプロトコルが ws または wss 以外であればエラーにする
- 接続解除可能な状況でも ``connectionBusy`` のエラーが発生する現象を修正した
- 接続解除後も内部で接続状態の監視を続ける現象を修正した
- API: ConnectionController: 接続画面外で接続が解除されても接続画面では接続状態である現象を修正した
- API: VideoView のサイズの変化に動画のサイズが追従しない現象を修正した

## 1.0.1

### CHANGE

- システム条件を更新した
    - Xcode 8.1 以降 -> 8.3.2 以降
    - Swift 3.0.1 -> 3.1
    - Sora 17.02 -> 17.04

### UPDATE

- SoraApp の Cartfile で利用する shiguredo/sora-ios-sdk を 1.0.1 にアップデートした

## 1.0.0

### UPDATE

- API: MediaCapturer: 同一の RTCPeerConnectionFactory で再利用するようにした
- API: MediaCapturer: 映像トラック名と音声トラック名を自動生成するようにした
- API: VideoRenderer: 描画処理をメインスレッドで実行するようにした
- API: VideoView: UI の設計に Nib ファイルを利用するようにした
- API: VideoView: バックグラウンド (ビューがキーウィンドウに表示されていない) では描画処理を中止するようにした

### ADD

- API: BuildInfo: 追加した
- API: ConnectionController: 追加した
- API: Connection: 次の API を追加した
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
- API: Connection, MediaConnection, MediaStream, PeerConnection: 次のイベントで (NotificationCenter による) 通知を行うようにした
    - onConnect
    - onDisconnect
    - onFailure
- API: WebSocketEventHandlers, SignalingEventHandlers, PeerConnectionEventHandlers: イニシャライザーを追加した

### CHANGE

- WebRTC M57 に対応した
- 対応アーキテクチャを arm64 のみにした
- マルチストリームに対応した
- シグナリング: "notify" に対応した
- シグナリング: Sora の仕様変更に伴い、 "stats" への対応を廃止した
- シグナリング: Sora の仕様変更に伴い、 "connect" の "access_token" パラメーターを "metadata" に変更した
- API: ArchiveFinished: 削除した
- API: ArchiveFailed: 削除した
- API: MediaConnection: MediaStream を複数保持するようにした
- API: MediaConnection: ``multistreamEnabled`` プロパティを追加した
- API: MediaConnection: 次の変数の型を変更した
    - ``webSocketEventHandlers``: ``WebSocketEventHandlers?`` --> ``WebSocketEventHandlers``
    - ``signalingEventHandlers``: ``SignalingEventHandlers?`` --> ``SignalingEventHandlers``
    - ``peerConnectionEventHandlers``: ``PeerConnectionEventHandlers?`` --> ``PeerConnectionEventHandlers``
- API: MediaConnection: ``connect(accessToken:timeout:handler:)`` メソッドの型を ``connect(metadata:timeout:handler:)`` に変更した
- API: MediaConnection, MediaStream: 次の API を MediaStream に移行した
    - ``var videoRenderer``
    - ``func startConnectionTimer(timeInterval:handler:)``
- API: MediaConnection.State: 削除した
- API: MediaOption.AudioCodec: ``unspecified`` を ``default`` に変更した
- API: MediaOption.VideoCodec: ``unspecified`` を ``default`` に変更した
- API: MediaPublisher: ``autofocusEnabled`` プロパティを追加した
- API: MediaStream: RTCPeerConnection のラッパーではなく、 RTCMediaStream のラッパーに変更した
- API: MediaStream: ``startConnectionTimer(timeInterval:handler:)``: タイマーを起動した瞬間もハンドラーを実行するようにした
- API: MediaStream.State: 削除した
- API: PeerConnection: RTCPeerConnection のラッパーとして追加した
- API: SignalingConnected: 削除した
- API: SignalingCompleted: 削除した
- API: SignalingDisconnected: 削除した
- API: SignalingFailed: 削除した
- API: StatisticsReport: RTCStatsReport の変更 (名前が RTCLegacyStatsReport に変更された) に伴い削除した
- API: VideoView: 映像のアスペクト比を保持するようにした

### FIX

- シグナリング: 音声コーデック Opus を指定するためのパラメーターの間違いを修正した
- 接続解除後にイベントログを記録しようとして落ちる現象を修正した
- 接続失敗時にデバイスを初期化しようとして落ちる現象を修正した (接続成功時のみ初期化するようにした)
- 接続試行中にエラーが発生して失敗したにも関わらず、成功と判断されてしまう場合がある現象を修正した
- API: MediaConnection: 接続解除後もタイマーが実行されてしまう場合がある現象を修正した (タイマーに関する API は MediaStream に移動した)
- API: PeerConnection: 接続失敗時でもタイムアウト時のイベントハンドラが呼ばれる現象を修正した

## 0.1.0

**0.1.0 リリース**
