# 変更履歴

- UPDATE
    - 下位互換がある変更
- ADD
    - 下位互換がある追加
- CHANGE
    - 下位互換のない変更
- FIX
    - バグ修正

## 2.6.0

### CHANGE

- システム条件を更新した

   - macOS 10.15 以降

   - Xcode 11.1

- WebRTC M78 に対応した

## 2.5.0

### CHANGE

- システム条件を更新した

   - Xcode 11

   - Swift 5.1

## 2.4.1

### CHANGE

- 依存するライブラリを変更した (`Cartfile`)

  - sora-webrtc-ios 76.3.1 -> shiguredo-webrtc-ios 76.3.1

- 対応アーキテクチャから armv7 を外した

- 対応アーキテクチャに x86_64 を追加した (シミュレーターの動作は未保証)

- シグナリングに SDK と端末の情報を含めるようにした

## 2.4.0

### CHANGE

- システム条件を更新した

  - Xcode 10.3
  
- WebRTC M76 に対応した

- サイマルキャスト機能に対応した

- スポットライト機能に対応した

- VAD 機能を削除した

- 音声ビットレートの指定に対応した

- シグナリングのメタデータに対応した

- API: `Configuration`: `audioBitRate` プロパティを追加した

- API: `Configuration`: `maxNumberOfSpeakers` プロパティを削除した

- API: `Configuration`: `simulcastEnabled` プロパティを追加した

- API: `Configuration`: `simulcastQuality` プロパティを追加した

- API: `Configuration`: `spotlight` プロパティを追加した

- API: `SimulcastQuality`: 追加した

- API: シグナリングに関する API の名前を変更した

  - `SignalingMessage` -> `Signaling`
  - `SignalingNotificationEventType` -> `SignalingNotifyEventType`
  - `SignalingConnectMessage` -> `SignalingConnect`
  - `SignalingOfferMessage` -> `SignalingOffer`
  - `SignalingOfferMessage.Configuration` -> `SignalingOffer.Configuration`
  - `SignalingPongMessage` -> `SignalingPong`
  - `SignalingPushMessage` -> `SignalingPush`
  
- API: `SignalingAnswer`: 追加した

- API: `SignalingCandidate`: 追加した

- API: `SignalingClientMetadata`: 追加した

- API: `SignalingMetadata`: 追加した

- API: `SignalingNotifyConnection`: 追加した

- API: `SignalingNotifyNetworkStatus`: 追加した

- API: `SignalingNotifySpotlightChanged`: 追加した

- API: `SignalingOffer.Encoding`: 追加した

- API: `SignalingUpdate`: 追加した

- API: `Signaling`: 追加した
  
## 2.3.2

### CHANGE

- SDP セマンティクスのデフォルトを Unified Plan に変更した

- API: シグナリング "notify" の "connection_id" プロパティに対応した

- API: ``SDPSemantics``: ``case default`` を削除した

- API: ``SignalingNotifyMessage``: ``connectionId`` プロパティを追加した

### FIX

- 接続状態によってシグナリング "notify" が無視される現象を修正する

## 2.3.1

### FIX

- グループ (マルチストリーム) 時、映像を無効にした状態で接続すると落ちる現象を修正した

## 2.3.0

### CHANGE

- システム条件を更新した

  - WebRTC SFU Sora 19.04.0 以降

  - macOS 10.14.4 以降

  - Xcode 10.2

  - Swift 5

- マルチストリーム時に強制的に Plan B に設定していたのを止めた

- 未知のシグナリングメッセージを受信したら例外を発生するように変更した

- シグナリング "notify" の次のイベントに対応した

  - "spotlight.changed"

  - "network.status"

## 2.2.1

### CHANGE

- システム条件を更新した

  - WebRTC SFU Sora 18.10.0 以降

  - macOS 10.14 以降

  - iOS 10.0

  - Xcode 10.1

  - Swift 4.2.1

- シグナリング "push" に対応した

### FIX

- シグナリング "notify" に含まれるメタデータが解析されていない現象を修正した

## 2.2.0

### CHANGE

- システム条件を更新した

  - iOS 12.0

  - Xcode 10.0

  - Swift 4.2

- API: ``ConnectionTask``: 追加した

- API: ``Sora``: ``connect(configuration:webRTCConfiguration:handler:)``: 実行中に接続の試行をキャンセル可能にした

## 2.1.3

### CHANGE

- システム条件を更新した

  - macOS 10.13.6 以降

  - Xcode 9.4

  - Swift 4.1

### FIX

- MediaChannel: 接続解除後、サーバーにしばらく接続が残る可能性がある現象を修正した

## 2.1.2

### CHANGE

- WebRTC SFU Sora 18.04 以降に対応した

- WebRTC M66 に対応した

## 2.1.1

### CHANGE

- システム条件を更新した

  - macOS 10.13.2 以降

  - Xcode 9.3

  - Swift 4.1

  - Carthage 0.29.0 以降、または CocoaPods 1.4.0 以降

  - WebRTC SFU Sora 18.02 以降

- API: ``MediaStream``: ``audioVolume`` プロパティを非推奨にした

- API: ``MediaStream``: ``remoteAudioVolume`` プロパティを追加した

### FIX

- API: ``MediaStream``: 配信中に ``videoEnabled`` プロパティまたは ``audioEnabled`` プロパティで映像か音声を無効にすると、有効に戻しても他のクライアントに配信が再開されない現象を修正した

- API: ``WebRTCInfo``: ``shortRevision``: 戻り値の文字列が 7 桁でない現象を修正した

## 2.1.0

### CHANGE

- 視聴のみのマルチストリームに対応した

- 音声検出による映像の動的切替に対応した

- API: ``Role``: ``.groupSub`` を追加した

- API: ``Configuration``: ``maxNumberOfSpeakers`` プロパティを追加した

- API: ``SignalingConnectMessage``: ``maxNumberOfSpeakers`` プロパティを追加した

## 2.0.4

### CHANGE

- WebRTC M64 に対応した

## 2.0.3

### CHANGE

- WebRTC M63 に対応した

- SDWebImage 4.2.2 に対応した

- API: ``WebSocketChannelHandlers``: ``onDisconnectHandler`` を追加した

- API: ``WebSocketChannelHandlers``: ``onFailureHandler`` を削除した

- API: ``SignalingChannelHandlers``: ``onDisconnectHandler`` を追加した

- API: ``SignalingChannelHandlers``: ``onFailureHandler`` を削除した

- API: ``SoraError``: WebSocket に関するエラーを次の二つに分割した

  - ``webSocketClosed(statusCode:reason:)``
    
  - ``webSocketError()``

- API: ``PeerChannelHandlers``: ``onDisconnectHandler`` を追加した

- API: ``PeerChannelHandlers``: ``onFailureHandler`` を削除した

- API: ``MediaChannelHandlers``: ``onFailureHandler`` を削除した

### FIX

- API: ``MediaChannel``: ``PeerChannel`` の接続解除時に ``MediaChannel`` の状態が接続解除にならない現象を修正した

## 2.0.2

### CHANGE

- connect シグナリングメッセージに Offer SDP を含めるようにした

- API: MediaStreamAudioVolume: 追加した

- API: MediaStream: audioVolume プロパティを追加した

### FIX

- API: MediaStream: videoEnabled: 映像をオフにしても VideoView に反映されない現象を修正した

- API: MediaStream: audioEnabled: 音声の可否がサブスクライバーに反映されない現象を修正した

## 2.0.1

### CHANGE

- Xcode 9.1 に対応した

- API: MediaStream: 接続中に映像と音声の送受信を停止・再開するプロパティを追加した

- API: MediaStreamHandlers: 追加した

## 2.0.0

設計と API を大きく見直した。

### CHANGE

- WebRTC M62 に対応した

- アーキテクチャ armv7 に対応した

- iOS 11 に対応した

- Xcode 9 に対応した

- Swift 4 に対応した

- 依存するフレームワークから Unbox.framework を削除した

- WebRTC のネイティブ API (主にクラスやプロトコル名の接頭辞が ``RTC`` の API) を非公開にした

- クライアントの設定を ``Configuration`` にまとめた

- ロールについて、 "パブリッシャー (Publisher)" と "サブスクライバー (Subscriber)" に加えて、マルチストリームで通信を行う "グループ (Group)" を追加した。

- 通信を行うオブジェクト (WebSocket 接続、シグナリング接続、ピア接続、メディアストリーム) をプロトコルに変更した (デフォルトの実装は ``private``)

- 内部で使用する WebSocket の API (SRWebSocket.framework の API) を非公開にした

- 任意の映像キャプチャーの使用を可能にした

- ``CMSampleBuffer`` を映像フレームとして使用可能にした

- 映像フレームの編集を可能にした

### CHANGE (API)

- 次のクラス、構造体、列挙体、プロトコルを削除した

  - ``Attendee``: 同等の機能を ``MediaChannel`` に実装した
  - ``BuildInfo``: 同等の機能を ``WebRTCInfo`` に実装した
  - ``Connection``: パブリッシャーとサブスクライバーをそれぞれ独立させたため削除した。
  - ``ConnectionController``: 同等の機能を削除した
  - ``ConnectionController.Request``
  - ``ConnectionController.Role``
  - ``ConnectionController.StreamType``
  - ``ConnectionError``: 同等の機能を ``SoraError`` に実装した
  - ``Event``: 各イベントをイベントハンドラのみで扱うようにした
  - ``Event.EventType``
  - ``EventLog``: ロギング機能を削除した
  - ``MediaConnection``: 同等の機能を ``MediaChannel`` に実装した
  - ``MediaPublisher``: パブリッシャーを ``MediaChannel`` で扱うようにしたため削除した
  - ``MediaSubscriber``: サブスクライバーを ``MediaChannel`` で扱うようにしたため削除した
  - ``MediaOption``: 同等の機能を ``Configuration`` に実装した
  - ``Message``: 同等の機能を ``SignalingMessage`` に実装した
  - ``Message.MessageType``
  - ``Messagable``
  - ``PeerConnection``: 同等の機能を ``PeerChannel`` に定義した
  - ``PeerConnectionEventHandlers``: 同等の機能を ``PeerChannelHandlers`` に実装した
  - ``SignalingEventHandlers``: 同等の機能を ``SignalingChannelHandlers`` に実装した
  - ``SignalingNotify``: 同等の機能を ``SignalingNotifyMessage`` に実装した
  - ``SignalingSnapshot``: 同等の機能を ``SignalingSnapshotMessage`` に実装した
  - ``VideoFrameHandle``: 同等の機能を ``VideoFrame`` に実装した
  - ``WebSocketEventHandlers``: 同等の機能を ``WebSocketChannelHandlers`` に実装した

- 次のクラスを追加した

  - ``CameraVideoCapturer``
  - ``CameraVideoCapturer.Settings``
  - ``ICECandidate``
  - ``ICEServerInfo``
  - ``MediaChannel``
  - ``MediaChannelHandlers``
  - ``PeerChannelHandlers``
  - ``SignalingChannelHandlers``
  - ``Sora``
  - ``SoraHandlers``
  - ``VideoCapturerHandlers``
  - ``WebSocketChannelHandlers``

- 次の構造体を追加した

  - ``Configuration``
  - ``MediaConstraints``
  - ``SignalingConnectMessage``
  - ``SignalingNotifyMessage``
  - ``SignalingOfferMessage``
  - ``SignalingOfferMessage.Configuration``
  - ``SignalingPongMessage``
  - ``SignalingSnapshotMessage``
  - ``SignalingUpdateOfferMessage``
  - ``Snapshot``
  - ``WebRTCConfiuration``
  - ``WebRTCInfo``

- 次の列挙体を追加した

  - ``ConnectionState``
  - ``ICETransportPolicy``
  - ``LogLevel``
  - ``NotificationEvent``
  - ``SignalingNotificationEventType``
  - ``SignalingMessage``
  - ``SignalingRole``
  - ``SoraError``
  - ``TLSSecurityPolicy``
  - ``VideoCapturerDecive``
  - ``VideoFrame``
  - ``WebSocketMessage``
  - ``WebSocketMessageStatusCode``

- 次のプロトコルを追加した

  - ``MediaStream``
  - ``PeerChannel``
  - ``SignalingChannel``
  - ``VideoCapturer``
  - ``ViderFilter``
  - ``WebSocketChannel``

- ``Notification`` の使用を中止し、次の関連する構造体と列挙体を削除した

  - ``Connection.NotificationKey``
  - ``Connection.NotificationKey.UserInfo``
  - ``MediaConnection.NotificationKey``
  - ``MediaConnection.NotificationKey.UserInfo``
  - ``MediaStream.NotificationKey``
  - ``MediaStream.NotificationKey.UserInfo``

- ``AudioCodec``

  - ``.Opus`` を ``.opus`` に変更した

  - ``.PCMU`` を ``.pcmu`` に変更した

- ``MediaStream``

  - クラスからプロトコルに変更し、 API を一新した

- ``Role``

  - ``.group`` を追加した

- ``VideoCodec``

  - ``.VP8`` を ``.vp8`` に変更した

  - ``.VP9`` を ``.vp9`` に変更した

  - ``.H264`` を ``.h264`` に変更した

- ``VideoFrame``

  - プロトコルから列挙体に変更し、 API を一新した

- ``VideoRenderer``

  - ``onChangedSize(_:)`` を ``onChange(size:)`` に変更した

  - ``renderVideoFrame(_:)`` を ``render(videoFrame:)`` に変更した

## 1.2.5

### FIX

- CircleCI でのビルドエラーを修正した

## 1.2.4

### CHANGE

- armv7 に対応した

- API: MediaOption を struct に変更した

- API: ConnectionController: ロールとストリーム種別の選択制限を削除した

### FIX

- API: マルチストリーム時、配信者のストリームが二重に生成されてしまう現象を修正した

## 1.2.3

### CHANGE

- API: VideoView: ``contentMode`` に応じて映像のサイズを変更するようにした

### FIX

- API: 残っていたデバッグプリントを削除した

## 1.2.2

### CHANGE

- API: 一部の静的変数を定数に変更した

### FIX

- API: VideoView: メモリー解放時に Key-Value Observing に関する例外が発生する現象を修正した

- API: VideoView: メモリー解放時にクラッシュする現象を修正した

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
