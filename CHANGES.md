# 変更履歴

- UPDATE
    - 下位互換がある変更
- ADD
    - 下位互換がある追加
- CHANGE
    - 下位互換のない変更
- FIX
    - バグ修正

## develop

## 2020.3

- [FIX] マイクが初期化されない事象を修正する
    - @szktty

## 2020.2

- [CHANGE] 受信時にマイクのパーミッションを要求しないようにする
    - @szktty
- [FIX] ``Sora.remove(mediaChannel:)`` 実行時に ``onRemoveMediaChannel`` が呼ばれない事象を修正する
    - @tamiyoshi-naka @szktty

## 2020.1

本バージョンよりバージョン表記を「リリース年.リリース回数」に変更しました。

- [UPDATE] システム条件を更新する
    - Xcode 11.3
    - CocoaPods 1.8.4 以降
    - WebRTC SFU Sora 19.10.3 以降
    - @szktty
- [CHANGE] WebRTC M79 に対応する
    - @szktty
- [CHANGE] Carthage の使用を止める
    - @szktty
- [CHANGE] シグナリングに含める各種バージョン情報を変更する
    - @szktty
- [CHANGE] API: SocketRocket の使用を止めて Starscream を採用する
    - @szktty
- [CHANGE] API: イベントハンドラのプロパティ名を短縮する
    - @szktty
- [CHANGE] API: `Configuration`: `init(url:channelId:role:)` を非推奨にする
    - @szktty
- [CHANGE] API: `Configuration`: `init(url:channelId:role:multistreamEnabled:)` を追加する
    - @szktty
- [CHANGE] API: `Configuration`: `webSocketChannelHandlers`: プロパティを追加する
    - @szktty
- [CHANGE] API: `Configuration`: `multistreamEnabled`: プロパティを追加する
    - @szktty
- [CHANGE] API: `Role`: Sora の仕様に合わせて `sendonly`, `recvonly`, `sendrecv` を追加する
    - @szktty
- [CHANGE] API: `Role`: `publisher`, `subscriber`, `group`, `groupSub` を非推奨にする
    - @szktty

## 2.6.0

- [UPDATE] システム条件を更新した
    - macOS 10.15 以降
    - Xcode 11.1
    - @szktty
- [UPDATE] WebRTC M78 に対応した
    - @szktty

## 2.5.0

- [UPDATE] システム条件を更新した
    - Xcode 11
    - Swift 5.1
    - @szktty

## 2.4.1

- [ADD] 対応アーキテクチャに x86_64 を追加した (シミュレーターの動作は未保証)
    - @szktty
- [ADD] シグナリングに SDK と端末の情報を含めるようにした
    - @szktty
- [CHANGE] 依存するライブラリを変更した (`Cartfile`)
    - sora-webrtc-ios 76.3.1 -> shiguredo-webrtc-ios 76.3.1
    - @szktty
- [CHANGE] 対応アーキテクチャから armv7 を外した
    - @szktty

## 2.4.0

- [UPDATE] システム条件を更新した
    - Xcode 10.3
    - @szktty
- [UPDATE] WebRTC M76 に対応した
    - @szktty
- [ADD] サイマルキャスト機能に対応した
    - @szktty
- [ADD] スポットライト機能に対応した
    - @szktty
- [ADD] 音声ビットレートの指定に対応した
    - @szktty
- [ADD] シグナリングのメタデータに対応した
    - @szktty
- [ADD] API: `Configuration`: `audioBitRate` プロパティを追加した
    - @szktty
- [ADD] API: `Configuration`: `maxNumberOfSpeakers` プロパティを削除した
    - @szktty
- [ADD] API: `Configuration`: `simulcastEnabled` プロパティを追加した
    - @szktty
- [ADD] API: `Configuration`: `simulcastQuality` プロパティを追加した
    - @szktty
- [ADD] API: `Configuration`: `spotlight` プロパティを追加した
    - @szktty
- [ADD] API: `SimulcastQuality`: 追加した
    - @szktty
- [ADD] API: `SignalingAnswer`: 追加した
    - @szktty
- [ADD] API: `SignalingCandidate`: 追加した
    - @szktty
- [ADD] API: `SignalingClientMetadata`: 追加した
    - @szktty
- [ADD] API: `SignalingMetadata`: 追加した
    - @szktty
- [ADD] API: `SignalingNotifyConnection`: 追加した
    - @szktty
- [ADD] API: `SignalingNotifyNetworkStatus`: 追加した
    - @szktty
- [ADD] API: `SignalingNotifySpotlightChanged`: 追加した
    - @szktty
- [ADD] API: `SignalingOffer.Encoding`: 追加した
    - @szktty
- [ADD] API: `SignalingUpdate`: 追加した
    - @szktty
- [ADD] API: `Signaling`: 追加した
    - @szktty
- [CHANGE] VAD 機能を削除した
    - @szktty
- [CHANGE] API: シグナリングに関する API の名前を変更した
    - `SignalingMessage` -> `Signaling`
    - `SignalingNotificationEventType` -> `SignalingNotifyEventType`
    - `SignalingConnectMessage` -> `SignalingConnect`
    - `SignalingOfferMessage` -> `SignalingOffer`
    - `SignalingOfferMessage.Configuration` -> `SignalingOffer.Configuration`
    - `SignalingPongMessage` -> `SignalingPong`
    - `SignalingPushMessage` -> `SignalingPush`
    - @szktty

## 2.3.2

- [ADD] API: シグナリング "notify" の "connection_id" プロパティに対応した
    - @szktty
- [ADD] API: ``SignalingNotifyMessage``: ``connectionId`` プロパティを追加した
    - @szktty
- [CHANGE] API: ``SDPSemantics``: ``case default`` を削除した
    - @szktty
- [CHANGE] SDP セマンティクスのデフォルトを Unified Plan に変更した
    - @szktty
- [FIX] 接続状態によってシグナリング "notify" が無視される現象を修正する
    - @szktty

## 2.3.1

- [FIX] グループ (マルチストリーム) 時、映像を無効にした状態で接続すると落ちる現象を修正した
    - @szktty

## 2.3.0

- [UPDATE] システム条件を更新した
    - WebRTC SFU Sora 19.04.0 以降
    - macOS 10.14.4 以降
    - Xcode 10.2
    - Swift 5
    - @szktty
- [CHANGE] マルチストリーム時に強制的に Plan B に設定していたのを止めた
    - @szktty
- [CHANGE] 未知のシグナリングメッセージを受信したら例外を発生するように変更した
    - @szktty
- [ADD] シグナリング "notify" の次のイベントに対応した
    - "spotlight.changed"
    - "network.status"
    - @szktty

## 2.2.1

- [UPDATE] システム条件を更新した
    - WebRTC SFU Sora 18.10.0 以降
    - macOS 10.14 以降
    - iOS 10.0
    - Xcode 10.1
    - Swift 4.2.1
    - @szktty
- [ADD] シグナリング "push" に対応した
    - @szktty
- [FIX] シグナリング "notify" に含まれるメタデータが解析されていない現象を修正した
    - @szktty

## 2.2.0

- [UPDATE] システム条件を更新した
    - iOS 12.0
    - Xcode 10.0
    - Swift 4.2
    - @szktty
- [ADD] API: ``ConnectionTask``: 追加した
    - @szktty
- [UPDATE] API: ``Sora``: ``connect(configuration:webRTCConfiguration:handler:)``: 実行中に接続の試行をキャンセル可能にした
    - @szktty

## 2.1.3

- [UPDATE] システム条件を更新した
    - macOS 10.13.6 以降
    - Xcode 9.4
    - Swift 4.1
    - @szktty
- [FIX] MediaChannel: 接続解除後、サーバーにしばらく接続が残る可能性がある現象を修正した
    - @szktty

## 2.1.2

- [UPDATE] WebRTC M66 に対応した
    - @szktty
- [UPDATE] WebRTC SFU Sora 18.04 以降に対応した
    - @szktty

## 2.1.1

- [UPDATE] システム条件を更新した
    - macOS 10.13.2 以降
    - Xcode 9.3
    - Swift 4.1
    - Carthage 0.29.0 以降、または CocoaPods 1.4.0 以降
    - WebRTC SFU Sora 18.02 以降
    - @szktty
- [ADD] API: ``MediaStream``: ``remoteAudioVolume`` プロパティを追加した
    - @szktty
- [CHANGE] API: ``MediaStream``: ``audioVolume`` プロパティを非推奨にした
    - @szktty
- [FIX] API: ``MediaStream``: 配信中に ``videoEnabled`` プロパティまたは ``audioEnabled`` プロパティで映像か音声を無効にすると、有効に戻しても他のクライアントに配信が再開されない現象を修正した
    - @szktty
- [FIX] API: ``WebRTCInfo``: ``shortRevision``: 戻り値の文字列が 7 桁でない現象を修正した
    - @szktty

## 2.1.0

- [ADD] 視聴のみのマルチストリームに対応した
    - @szktty
- [ADD] 音声検出による映像の動的切替に対応した
    - @szktty
- [ADD] API: ``Role``: ``.groupSub`` を追加した
    - @szktty
- [ADD] API: ``Configuration``: ``maxNumberOfSpeakers`` プロパティを追加した
    - @szktty
- [ADD] API: ``SignalingConnectMessage``: ``maxNumberOfSpeakers`` プロパティを追加した
    - @szktty

## 2.0.4

- [UPDATE] WebRTC M64 に対応した
    - @szktty

## 2.0.3

- [UPDATE] WebRTC M63 に対応した
    - @szktty
- [UPDATE] SDWebImage 4.2.2 に対応した
    - @szktty
- [ADD] API: ``WebSocketChannelHandlers``: ``onDisconnectHandler`` を追加した
    - @szktty
- [ADD] API: ``SignalingChannelHandlers``: ``onDisconnectHandler`` を追加した
    - @szktty
- [ADD] API: ``PeerChannelHandlers``: ``onDisconnectHandler`` を追加した
    - @szktty
- [CHANGE] API: ``SoraError``: WebSocket に関するエラーを次の二つに分割した
    - ``webSocketClosed(statusCode:reason:)``
    - ``webSocketError()``
    - @szktty
- [CHANGE] API: ``WebSocketChannelHandlers``: ``onFailureHandler`` を削除した
    - @szktty
- [CHANGE] API: ``SignalingChannelHandlers``: ``onFailureHandler`` を削除した
    - @szktty
- [CHANGE] API: ``PeerChannelHandlers``: ``onFailureHandler`` を削除した
    - @szktty
- [CHANGE] API: ``MediaChannelHandlers``: ``onFailureHandler`` を削除した
    - @szktty
- [FIX] API: ``MediaChannel``: ``PeerChannel`` の接続解除時に ``MediaChannel`` の状態が接続解除にならない現象を修正した
    - @szktty

## 2.0.2

- [ADD] connect シグナリングメッセージに Offer SDP を含めるようにした
    - @szktty
- [ADD] API: MediaStreamAudioVolume: 追加した
    - @szktty
- [ADD] API: MediaStream: audioVolume プロパティを追加した
    - @szktty
- [FIX] API: MediaStream: videoEnabled: 映像をオフにしても VideoView に反映されない現象を修正した
    - @szktty
- [FIX] API: MediaStream: audioEnabled: 音声の可否がサブスクライバーに反映されない現象を修正した
    - @szktty

## 2.0.1

- [UPDATE] Xcode 9.1 に対応した
    - @szktty
- [ADD] API: MediaStream: 接続中に映像と音声の送受信を停止・再開するプロパティを追加した
    - @szktty
- [ADD] API: MediaStreamHandlers: 追加した
    - @szktty

## 2.0.0

設計と API を大きく見直した。

- [UPDATE] WebRTC M62 に対応した
    - @szktty
- [UPDATE] アーキテクチャ armv7 に対応した
    - @szktty
- [UPDATE] iOS 11 に対応した
    - @szktty
- [UPDATE] Xcode 9 に対応した
    - @szktty
- [UPDATE] Swift 4 に対応した
    - @szktty
- [UPDATE] クライアントの設定を ``Configuration`` にまとめた
    - @szktty
- [ADD] ロールについて、 "パブリッシャー (Publisher)" と "サブスクライバー (Subscriber)" に加えて、マルチストリームで通信を行う "グループ (Group)" を追加した
    - @szktty
- [ADD] 任意の映像キャプチャーの使用を可能にした
    - @szktty
- [ADD] ``CMSampleBuffer`` を映像フレームとして使用可能にした
    - @szktty
- [ADD] 映像フレームの編集を可能にした
    - @szktty
- [CHANGE] 依存するフレームワークから Unbox.framework を削除した
    - @szktty
- [CHANGE] WebRTC のネイティブ API (主にクラスやプロトコル名の接頭辞が ``RTC`` の API) を非公開にした
    - @szktty
- [CHANGE] 通信を行うオブジェクト (WebSocket 接続、シグナリング接続、ピア接続、メディアストリーム) をプロトコルに変更した (デフォルトの実装は ``private``)
    - @szktty
- [CHANGE] 内部で使用する WebSocket の API (SRWebSocket.framework の API) を非公開にした
    - @szktty

### API

- [CHANGE] 次のクラス、構造体、列挙体、プロトコルを削除した
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
    - @szktty
- [ADD] 次のクラスを追加した
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
    - @szktty
- [ADD] 次の構造体を追加した
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
    - @szktty
- [ADD] 次の列挙体を追加した
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
    - @szktty
- [ADD] 次のプロトコルを追加した
    - ``MediaStream``
    - ``PeerChannel``
    - ``SignalingChannel``
    - ``VideoCapturer``
    - ``ViderFilter``
    - ``WebSocketChannel``
    - @szktty
- [CHANGE] ``Notification`` の使用を中止し、次の関連する構造体と列挙体を削除した
    - ``Connection.NotificationKey``
    - ``Connection.NotificationKey.UserInfo``
    - ``MediaConnection.NotificationKey``
    - ``MediaConnection.NotificationKey.UserInfo``
    - ``MediaStream.NotificationKey``
    - ``MediaStream.NotificationKey.UserInfo``
    - @szktty
- [CHANGE] ``AudioCodec``
    - ``.Opus`` を ``.opus`` に変更した
    - ``.PCMU`` を ``.pcmu`` に変更した
    - @szktty
- [CHANGE] ``MediaStream``
    - クラスからプロトコルに変更し、 API を一新した
- [ADD] ``Role``
  - ``.group`` を追加した
    - @szktty
- [CHANGE] ``VideoCodec``
    - ``.VP8`` を ``.vp8`` に変更した
    - ``.VP9`` を ``.vp9`` に変更した
    - ``.H264`` を ``.h264`` に変更した
    - @szktty
- [CHANGE] ``VideoFrame``
    - プロトコルから列挙体に変更し、 API を一新した
    - @szktty
- [CHANGE]] ``VideoRenderer``
    - ``onChangedSize(_:)`` を ``onChange(size:)`` に変更した
    - ``renderVideoFrame(_:)`` を ``render(videoFrame:)`` に変更した
    - @szktty

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

- [UPDATE] WebRTC M59 に対応した
    - @szktty
- [ADD] CircleCI を利用した自動ビルドを追加
    - @szktty
- [ADD] シグナリング "notify" に対応した
    - @szktty
- [ADD] イベントログに接続エラーの詳細を出力するようにした
    - @szktty
- [ADD] API: Attendee: 追加した
    - @szktty
- [ADD] API: ConnectionError: ``var description`` を追加した
    - @szktty
- [ADD] API: ConnectionController: ビットレートの設定項目を追加した
    - @szktty
- [ADD] API: ConnectionController: イベントログの画面を追加した
    - @szktty
- [ADD] API: Event.EventType: ``ConnectionMonitor`` を追加した
    - @szktty
- [ADD] API: MediaConnection: 次のプロパティとメソッドを追加した
    - ``var numberOfConnections``
    - ``func onAttendeeAdded(handler:)``
    - ``func onAttendeeRemoved(handler:)``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [ADD] API: Role: 追加した
    - @szktty
- [ADD] API: SignalingEventHandlers: ``func onNotify(handler:)`` を追加した
    - @szktty
- [ADD] API: SignalingEventType: 追加した
    - @szktty
- [ADD] API: SignalingNotify: 追加した
    - @szktty
- [ADD] API: SignalingRole: 追加した
    - @szktty
- [CHANGE] examples を削除
    - @szktty
- [CHANGE] ディレクトリ構造を変更し、プロジェクトのファイルをトップレベルに移動した
    - @szktty
- [CHANGE] API: PeerConnection: 接続状態に関わらず WebSocket のイベントハンドラを実行するようにした
    - @szktty
- [CHANGE] 次の不要なファイルを削除した
    - ``JSON.swift``
    - @szktty
- [CHANGE] API: BuildInfo: 次のプロパティを削除した
    - ``var VP9Enabled``
    - @szktty
- [CHANGE] API: Connection: 次のプロパティとメソッドを削除した
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [CHANGE] API: ConnectionController: Cancel ボタンを Back ボタンに変更した
    - @szktty
- [CHANGE] API: MediaStreamRole: 削除した
    - @szktty
- [CHANGE] API: VideoFrame の型を変更する
    - ``var width``: ``Int`` -> ``Int32``
    - ``var height``: ``Int`` -> ``Int32``
    - @szktty
- [CHANGE] API: ConnectionController: VP9 の有効・無効を示すセルを削除した
    - @szktty
- [FIX] Sora サーバーの URL のプロトコルが ws または wss 以外であればエラーにする
    - @szktty
- [FIX] 接続解除可能な状況でも ``connectionBusy`` のエラーが発生する現象を修正した
    - @szktty
- [FIX] 接続解除後も内部で接続状態の監視を続ける現象を修正した
    - @szktty
- [FIX] API: ConnectionController: 接続画面外で接続が解除されても接続画面では接続状態である現象を修正した
    - @szktty
- [FIX] API: VideoView のサイズの変化に動画のサイズが追従しない現象を修正した
    - @szktty

## 1.0.1

- [UPDATE] システム条件を更新した
    - Xcode 8.1 以降 -> 8.3.2 以降
    - Swift 3.0.1 -> 3.1
    - Sora 17.02 -> 17.04
    - @szktty
- [UPDATE] SoraApp の Cartfile で利用する shiguredo/sora-ios-sdk を 1.0.1 にアップデートした
    - @szktty

## 1.0.0

- [UPDATE] WebRTC M57 に対応した
    - @szktty
- [UPDATE] API: MediaCapturer: 同一の RTCPeerConnectionFactory で再利用するようにした
    - @szktty
- [UPDATE] API: MediaCapturer: 映像トラック名と音声トラック名を自動生成するようにした
    - @szktty
- [UPDATE] API: VideoRenderer: 描画処理をメインスレッドで実行するようにした
    - @szktty
- [UPDATE] API: VideoView: UI の設計に Nib ファイルを利用するようにした
    - @szktty
- [UPDATE] API: VideoView: バックグラウンド (ビューがキーウィンドウに表示されていない) では描画処理を中止するようにした
    - @szktty
- [UPDATE] API: VideoView: 映像のアスペクト比を保持するようにした
    - @szktty
- [UPDATE] API: MediaConnection: MediaStream を複数保持するようにした
    - @szktty
- [ADD] マルチストリームに対応した
    - @szktty
- [ADD] シグナリング: "notify" に対応した
    - @szktty
- [ADD] API: MediaConnection: ``multistreamEnabled`` プロパティを追加した
    - @szktty
- [ADD] API: MediaPublisher: ``autofocusEnabled`` プロパティを追加した
    - @szktty
- [ADD] API: PeerConnection: RTCPeerConnection のラッパーとして追加した
    - @szktty
- [ADD] API: BuildInfo: 追加した
    - @szktty
- [ADD] API: ConnectionController: 追加した
    - @szktty
- [ADD] API: Connection: 次の API を追加した
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [ADD] API: Connection, MediaConnection, MediaStream, PeerConnection: 次のイベントで (NotificationCenter による) 通知を行うようにした
    - onConnect
    - onDisconnect
    - onFailure
    - @szktty
- [ADD] API: WebSocketEventHandlers, SignalingEventHandlers, PeerConnectionEventHandlers: イニシャライザーを追加した
    - @szktty
- [CHANGE] 対応アーキテクチャを arm64 のみにした
    - @szktty
- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "stats" への対応を廃止した
    - @szktty
- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "connect" の "access_token" パラメーターを "metadata" に変更した
    - @szktty
- [CHANGE] API: ArchiveFinished: 削除した
    - @szktty
- [CHANGE] API: ArchiveFailed: 削除した
    - @szktty
- [CHANGE] API: MediaConnection: 次の変数の型を変更した
    - ``webSocketEventHandlers``: ``WebSocketEventHandlers?`` --> ``WebSocketEventHandlers``
    - ``signalingEventHandlers``: ``SignalingEventHandlers?`` --> ``SignalingEventHandlers``
    - ``peerConnectionEventHandlers``: ``PeerConnectionEventHandlers?`` --> ``PeerConnectionEventHandlers``
    - @szktty
- [CHANGE] API: MediaConnection: ``connect(accessToken:timeout:handler:)`` メソッドの型を ``connect(metadata:timeout:handler:)`` に変更した
    - @szktty
- [CHANGE] API: MediaConnection, MediaStream: 次の API を MediaStream に移行した
    - ``var videoRenderer``
    - ``func startConnectionTimer(timeInterval:handler:)``
    - @szktty
- [CHANGE] API: MediaConnection.State: 削除した
    - @szktty
- [CHANGE] API: MediaOption.AudioCodec: ``unspecified`` を ``default`` に変更した
    - @szktty
- [CHANGE] API: MediaOption.VideoCodec: ``unspecified`` を ``default`` に変更した
    - @szktty
- [CHANGE] API: MediaStream: RTCPeerConnection のラッパーではなく、 RTCMediaStream のラッパーに変更した
    - @szktty
- [CHANGE] API: MediaStream: ``startConnectionTimer(timeInterval:handler:)``: タイマーを起動した瞬間もハンドラーを実行するようにした
    - @szktty
- [CHANGE] API: MediaStream.State: 削除した
    - @szktty
- [CHANGE] API: SignalingConnected: 削除した
    - @szktty
- [CHANGE] API: SignalingCompleted: 削除した
    - @szktty
- [CHANGE] API: SignalingDisconnected: 削除した
    - @szktty
- [CHANGE] API: SignalingFailed: 削除した
    - @szktty
- [CHANGE] API: StatisticsReport: RTCStatsReport の変更 (名前が RTCLegacyStatsReport に変更された) に伴い削除した
    - @szktty
- [FIX] シグナリング: 音声コーデック Opus を指定するためのパラメーターの間違いを修正した
    - @szktty
- [FIX] 接続解除後にイベントログを記録しようとして落ちる現象を修正した
    - @szktty
- [FIX] 接続失敗時にデバイスを初期化しようとして落ちる現象を修正した (接続成功時のみ初期化するようにした)
    - @szktty
- [FIX] 接続試行中にエラーが発生して失敗したにも関わらず、成功と判断されてしまう場合がある現象を修正した
    - @szktty
- [FIX] API: MediaConnection: 接続解除後もタイマーが実行されてしまう場合がある現象を修正した (タイマーに関する API は MediaStream に移動した)
    - @szktty
- [FIX] API: PeerConnection: 接続失敗時でもタイムアウト時のイベントハンドラが呼ばれる現象を修正した
    - @szktty

## 0.1.0

**公開**
