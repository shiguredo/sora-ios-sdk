# 変更履歴

- UPDATE
    - 下位互換がある変更
- ADD
    - 下位互換がある追加
- CHANGE
    - 下位互換のない変更
- FIX
    - バグ修正

## hotfix/change-condition-to-relay-websocket-error

- [FIX] Sora との接続確立後に WebSocket のエラーが発生した場合、 エラーが正しく伝搬されず、終了処理が実行されないため修正する
    - 接続確立後に WebSocket のエラーが発生した場合、 Sora との接続を切断して終了処理を行うのが正しい処理です
    - 詳細な仕様は https://sora-doc.shiguredo.jp/SORA_CLIENT に記載されています
    - @enm10k

## 2022.1.0

- [UPDATE] システム条件を変更する
    - macOS 12.2 以降
    - Xcode 13.2
    - Swift 5.5.2
    - @miosakuma
- [UPDATE] WebRTC 98.4758.0.0 に上げる
    - @miosakuma
- [UPDATE] MediaStream から MediaChannel にアクセスできるようにする
    - @enm10k
- [ADD] 複数シグナリング URL の指定に対応する
    - `Configuration.url` を廃止して `Configuration.urlCandidates` を追加する
    - `MediaChannel.connectedUrl` を追加する
    - @enm10k
- [ADD] type: rediret に対応する
    - @enm10k
- [CHANGE] スポットライトレガシーを削除する
    - @miosakuma
- [CHANGE] WebSocketChannel プロトコルを廃止する
    - `Configuration.webSocketChannelType` を廃止する
    - `Configuration.allowsURLSessionWebSocketChannel` を廃止する
    - `WebSocketChannelHandlers.onDisconnect` を廃止する
    - `WebSocketChannelHandlers.onPong` を廃止する
    - `WebSocketChannelHandlers.onSend` を廃止する
    - `MediaChannel.webSocketChannel` を廃止する
    - `WebSocketChannelHandlers` を廃止する
    - @enm10k
- [CHANGE] Starscream を削除して、 URLSessionWebSocketTask をデフォルトで使用する
    - @enm10k
- [CHANGE] サポートする iOS のバージョンを13以上に変更する
    - @enm10k
- [CHANGE] `MediaChannel.native` の型を `RTCPeerConnection` から `RTCPeerConnection?` に変更する
    - PeerChannel で force unwrapping している箇所を修正する際に、併せて修正した
    - @enm10k
- [FIX] CameraVideoCapturer で force unwrapping していた箇所を修正する
    - @enm10k
- [FIX] VideoView に debugMode = true を設定した際にメモリー・リークが発生する問題を修正する
    - @szktty @enm10k
    
## 2021.3.1

- [FIX] RTCPeerConnectionState が .failed に遷移した際の切断処理中にクラッシュする問題を修正する
    - BasicPeerChannelContext と PeerChannel の循環参照を防ぐために弱参照を利用していましたが、それが原因で BasicPeerChannelContext より先に PeerChannel が解放されるケースがあり、クラッシュの原因となっていました
    - @enm10k
- [FIX] DataChannel クラスで利用しているデータ圧縮/復号処理にメモリー・リークがあったので修正する
    - @enm10k

## 2021.3.0

- [UPDATE] システム条件を変更する
    - macOS 12.0 以降
    - Xcode 13.1
    - Swift 5.5
    - CocoaPods 1.11.2
    - @miosakuma
- [UPDATE] WebRTC 95.4638.3.0 に上げる
    - @miosakuma
- [ADD] DataChannel シグナリングに対応する
    - `Configuration.dataChannelSignaling` を追加
    - `Configuration.ignoreDisconnectWebSocket` を追加
    - @szktty @enm10k
- [CHANGE] PeerChannel, SignalingChannel protocol を削除する
    - `Configuration.peerChannelType` を廃止
    - `Configuration.signalingChannelType` を廃止
    - `Configuration.peerChannelHandlers` を廃止
    - `Configuration.signalingChannelHandlers` を廃止
    - `MediaChannel.native` を追加
    - `MediaChannel.webSocketChannel` を追加
    - @szktty @enm10k
- [FIX] Sora 接続時に audioEnabled = false を設定すると answer 生成に失敗してしまう問題についてのワークアラウンドを削除する
    - @miosakuma

## 2021.2.1

- [FIX] Swift Package Manager に対応するためバージョニングを修正
    - @miosakuma

## 2021.2

- [UPDATE] Swift Package Manager に対応する
    - @miosakuma @enm10k
- [UPDATE] WebRTC 93.4577.8.0 に上げる
    - @miosakuma
- [UPDATE] システム条件を変更する
    - iOS 12.1 以降
    - @miosakuma
- [UPDATE] Starscream のバージョンを 4.0.4 に更新する
    - @szktty @enm10k
- [UPDATE] シグナリング・メッセージ re-offer, re-answer に対応する
    - @enm10k
- [UPDATE] AES-GCM を有効にする
    - @enm10k
- [UPDATE] SoraDispatcher を追加する
    - libwebrtc 内部で利用されているディスパッチ・キューをラップし、 SDK のユーザーから利用しやすくした
    - @szktty @enm10k
- [CHANGE] 接続開始時のカメラ・デバイスを指定可能にする
    - `Configuration.cameraSettings.position` に `.front` または `.back` を設定して、接続開始時のカメラ・デバイスを指定します
    - この修正に伴い、以下の API が変更されました
        - `CameraVideoCapturer` の API を破壊的に変更
        - `CameraVideoCapturer.Settings` を `CameraSettings` にリネーム
        - `VideoCapturerHandlers` を `CameraVideoCapturerHandlers` にリネーム
        - `VideoCapturer` を廃止
        - `VideoCapturerDevice` を廃止
        - `CameraPosition` を廃止
        - `Configuration.videoCapturerDevice` を廃止
        - `MediaStream.videoCapturer` を廃止
    - @szktty @enm10k
- [FIX] 接続、切断の検知に RTCPeerConnectionState を参照する
    - @enm10k
- [FIX] 接続終了後に MediaChannel のメモリが解放されずに残り続ける事象を修正する
    - @szktty

## 2021.1

- [UPDATE] システム条件を変更する
    - Xcode 12.5
    - Swift 5.4
    - CocoaPods 1.10.1
    - @miosakuma
- [UPDATE] サイマルキャストで VP8 / H.264 (ハードウェアアクセラレーション含む) に対応する
    - @szktty @enm10k
- [UPDATE] WebRTC 91.4472.9.1 に上げる
    - @enm10k
- [UPDATE] AV1 に対応する
    - @enm10k
- [ADD] libwebrtc のログレベルを設定する API を追加
    - `Sora.setWebRTCLogLevel(_:)`
    - @szktty
- [CHANGE] スポットライトに関する API を変更する
    - Sora のスポットライトレガシー機能を利用するための API を `Sora.useSpotlightLegacy()` に変更
    - `Configuration.activeSpeakerLimit` を非推奨にして、 `Configuration.spotlightNumber` に変更
    - `Configuration.spotlightFocusRid` を追加
    - `Configuration.spotlightUnfocusRid` を追加
    - @enm10k
- [CHANGE] シグナリングに含まれる JSON 型のフィールドを JSONSerialization でデコードする
    - フィールドの型を SignalingMetadata から Any? に変更したため、任意の型にキャストして利用することとなる
    - 対象のフィールド
        - `SignalingNotifyConnection.metadata`
        - `SignalingOffer.metadata`
        - `SignalingPush.data`
    - 修正にともない、 `SignalingClientMetadata` を `SignalingNotifyMetadata` にリネームする
    - @enm10k
- [CHANGES] type: notify のシグナリング・メッセージに対応する struct として SignalingNotify を追加する
    - event_type 毎に定義されていた以下の struct を廃止し、 SignalingNotify に統合する
        - `SignalingNotifyConnection`
        - `SignalingNotifySpotlightChanged`
        - `SignalingNotifyNetworkStatus`
    - @enm10k
- [CHANGE] サイマルキャストのオプションを Sora のアップデートへ追従する
    - `SimulcastQuality` を削除し、 `SimulcastRid` を追加する
    - `Configuration.simulcastQuality` を削除し、 `simulcastRid` を追加する
    - `SignalingConnect.simulcastQuality` を削除し、 `simulcastRid` を追加する
    - @szktty
- [CHANGE] DeviceModel を廃止し、 hw.machine の結果を表示する
    - @enm10k
- [FIX] SignalingNotify に漏れていたフィールドを追加する
    - `SignalingNotify.authnMetadata`
    - `SignalingNotify.authzMetadata`
    - `SignalingNotify.data`
    - `SignalingNotify.turnTransportType`
    - @enm10k
- [FIX] サイマルキャストのパラメーター active: false が無効化されてしまう問題を修正する
    - @enm10k
- [FIX] WebSocketChannel 切断時に MediaChannel を切断する処理が漏れていたので追加する
    - @enm10k

## 2020.7.2

- [ADD] VideoView に解像度とフレームレートを表示するデバッグモードを追加する
    - `VideoView.debugMode` を追加
    - @szktty
- [FIX] SignalingConnect に clientId が漏れていたので追加する
    - @enm10k

## 2020.7.1

- [CHANGE] API: スポットライトに関する API
    - `Configuration.Spotlight`: 追加
    - `Configuration.spotlightEnabled`: 型を `Spotlight` に変更
    - @szktty
- [FIX] スポットライトレガシー機能に対応する
    - @szktty

## 2020.7

- [UPDATE] WebRTC 86.4240.10.0 に上げる
    - @szktty
- [CHANGE] `AudioMode.swift` がターゲット含まれておらずビルドできなかった事象を修正する
    - @szktty

## 2020.6

- [UPDATE] システム条件を更新する
    - Xcode 12.0
    - Swift 5.3
    - CocoaPods 1.9.3
    - @szktty
- [UPDATE] WebRTC M86 に対応する
    - @szktty
- [CHANGE] API: スポットライトに関する API
    - `Configuration.spotlight`: 非推奨
    - `Configuration.spotlightEnabled`: 追加
    - `Configuration.activeSpeakerLimit`: 追加
    - @szktty
- [CHANGE] API: 音声モードに関する API
    - `Sora.setAudioMode(_:options:)`: 追加
    - `AudioMode`: 追加
    - `AudioOutput`: 追加
    - @szktty
- [FIX] API: `Sora.connect()`: タイムアウト時にハンドラが実行されない事象を修正する
    - @szktty

## 2020.5

- [UPDATE] システム条件を更新する
    - Xcode 11.6
    - Swift 5.2.4
    - WebRTC SFU Sora 2020.1 以降
    - @szktty
- [UPDATE] WebRTC M84 に対応する
    - @szktty
- [CHANGE] シグナリング pong に統計情報を含める
    - @szktty
- [CHANGE] API: 次のイベントハンドラのクラスにコンストラクタを追加する
    - ``MediaChannelHandlers``
    - ``MediaStreamHandlers``
    - ``PeerChannelHandlers``
    - ``SignalingChannelHandlers``
    - ``SoraHandlers``
    - ``VideoCapturerHandlers``
    - ``WebSocketChannelHandlers``
    - @itoyama @szktty
- [FIX] API: `Sora.connect()`: 接続先ホストが存在しない場合にハンドラが実行されない事象を修正する
    - @szktty

## 2020.4.1

- [FIX] 受信したシグナリングの role が ``sendonly``, ``recvonly``, ``sendrecv`` の場合にデコードに失敗する事象を修正する
    - @szktty
- [FIX] API: ``MediaChannel``: ``senderStream``: ストリーム ID が接続時に指定した配信用ストリームID と一致するストリームを返すようにする (変更前はカメラのストリームを返した)
    - @szktty
- [FIX] API: ``MediaChannel``: ``receiverStreams``: ``senderStream`` 以外のストリームを返すようにする (変更前はカメラ以外のストリームを返した)
    - @szktty

## 2020.4

- [CHANGE] iOS 13 以降の場合に URLSession を使って WebSocket 通信を行うようにする
    - @szktty
- [CHANGE] Plan B に関連する API を削除する
    - @szktty
- [CHANGE] シグナリングで送信する JSON にて、 role を upstream/downstream のどちらかで出力するようにする
    - @szktty
- [CHANGE] シグナリングの offer/update/ping を peer connection の状態に関わらず処理する
    - @szktty
- [CHANGE] 端末情報を追加する (iPhone 11, iPhone 11 Pro, iPhone1 11 Pro Max, iPad 7th)
    - @szktty
- [CHANGE] ログに出力される WebSocket のエラー内容を詳細にする
    - @szktty
- [CHANGE] API: ``MediaChannel``: ``senderStream`` プロパティを追加する
    - @szktty
- [CHANGE] API: ``MediaChannel``: ``receiverStreams`` プロパティを追加する
    - @szktty

## 2020.3

- [FIX] マイクが初期化されない事象を修正する
    - @szktty

## 2020.2

- [CHANGE] 受信時にマイクのパーミッションを要求しないようにする
    - @szktty
- [FIX] ``Sora.remove(mediaChannel:)`` 実行時に ``onRemoveMediaChannel`` が呼ばれない事象を修正する
    - @tamiyoshi-naka @szktty

## 2020.1

本バージョンよりバージョン表記を「リリース年.リリース回数」に変更する

- [UPDATE] システム条件を更新する
    - Xcode 11.3
    - CocoaPods 1.8.4 以降
    - WebRTC SFU Sora 19.10.3 以降
    - @szktty
- [UPDATE] WebRTC M79 に対応する
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

- [UPDATE] システム条件を更新する
    - macOS 10.15 以降
    - Xcode 11.1
    - @szktty
- [UPDATE] WebRTC M78 に対応する
    - @szktty

## 2.5.0

- [UPDATE] システム条件を更新する
    - Xcode 11
    - Swift 5.1
    - @szktty

## 2.4.1

- [ADD] 対応アーキテクチャに x86_64 を追加する (シミュレーターの動作は未保証)
    - @szktty
- [ADD] シグナリングに SDK と端末の情報を含めるようにする
    - @szktty
- [CHANGE] 依存するライブラリを変更する (`Cartfile`)
    - sora-webrtc-ios 76.3.1 -> shiguredo-webrtc-ios 76.3.1
    - @szktty
- [CHANGE] 対応アーキテクチャから armv7 を外する
    - @szktty

## 2.4.0

- [UPDATE] システム条件を更新する
    - Xcode 10.3
    - @szktty
- [UPDATE] WebRTC M76 に対応する
    - @szktty
- [ADD] サイマルキャスト機能に対応する
    - @szktty
- [ADD] スポットライト機能に対応する
    - @szktty
- [ADD] 音声ビットレートの指定に対応する
    - @szktty
- [ADD] シグナリングのメタデータに対応する
    - @szktty
- [ADD] API: `Configuration`: `audioBitRate` プロパティを追加する
    - @szktty
- [ADD] API: `Configuration`: `maxNumberOfSpeakers` プロパティを削除する
    - @szktty
- [ADD] API: `Configuration`: `simulcastEnabled` プロパティを追加する
    - @szktty
- [ADD] API: `Configuration`: `simulcastQuality` プロパティを追加する
    - @szktty
- [ADD] API: `Configuration`: `spotlight` プロパティを追加する
    - @szktty
- [ADD] API: `SimulcastQuality`: 追加する
    - @szktty
- [ADD] API: `SignalingAnswer`: 追加する
    - @szktty
- [ADD] API: `SignalingCandidate`: 追加する
    - @szktty
- [ADD] API: `SignalingClientMetadata`: 追加する
    - @szktty
- [ADD] API: `SignalingMetadata`: 追加する
    - @szktty
- [ADD] API: `SignalingNotifyConnection`: 追加する
    - @szktty
- [ADD] API: `SignalingNotifyNetworkStatus`: 追加する
    - @szktty
- [ADD] API: `SignalingNotifySpotlightChanged`: 追加する
    - @szktty
- [ADD] API: `SignalingOffer.Encoding`: 追加する
    - @szktty
- [ADD] API: `SignalingUpdate`: 追加する
    - @szktty
- [ADD] API: `Signaling`: 追加する
    - @szktty
- [CHANGE] VAD 機能を削除する
    - @szktty
- [CHANGE] API: シグナリングに関する API の名前を変更する
    - `SignalingMessage` -> `Signaling`
    - `SignalingNotificationEventType` -> `SignalingNotifyEventType`
    - `SignalingConnectMessage` -> `SignalingConnect`
    - `SignalingOfferMessage` -> `SignalingOffer`
    - `SignalingOfferMessage.Configuration` -> `SignalingOffer.Configuration`
    - `SignalingPongMessage` -> `SignalingPong`
    - `SignalingPushMessage` -> `SignalingPush`
    - @szktty

## 2.3.2

- [ADD] API: シグナリング "notify" の "connection_id" プロパティに対応する
    - @szktty
- [ADD] API: ``SignalingNotifyMessage``: ``connectionId`` プロパティを追加する
    - @szktty
- [CHANGE] API: ``SDPSemantics``: ``case default`` を削除する
    - @szktty
- [CHANGE] SDP セマンティクスのデフォルトを Unified Plan に変更する
    - @szktty
- [FIX] 接続状態によってシグナリング "notify" が無視される現象を修正する
    - @szktty

## 2.3.1

- [FIX] グループ (マルチストリーム) 時、映像を無効にする状態で接続すると落ちる現象を修正する
    - @szktty

## 2.3.0

- [UPDATE] システム条件を更新する
    - WebRTC SFU Sora 19.04.0 以降
    - macOS 10.14.4 以降
    - Xcode 10.2
    - Swift 5
    - @szktty
- [ADD] シグナリング "notify" の次のイベントに対応する
    - "spotlight.changed"
    - "network.status"
    - @szktty
- [CHANGE] マルチストリーム時に強制的に Plan B に設定していたのを止めた
    - @szktty
- [CHANGE] 未知のシグナリングメッセージを受信するら例外を発生するように変更する
    - @szktty

## 2.2.1

- [UPDATE] システム条件を更新する
    - WebRTC SFU Sora 18.10.0 以降
    - macOS 10.14 以降
    - iOS 10.0
    - Xcode 10.1
    - Swift 4.2.1
    - @szktty
- [ADD] シグナリング "push" に対応する
    - @szktty
- [FIX] シグナリング "notify" に含まれるメタデータが解析されていない現象を修正する
    - @szktty

## 2.2.0

- [UPDATE] システム条件を更新する
    - iOS 12.0
    - Xcode 10.0
    - Swift 4.2
    - @szktty
- [UPDATE] API: ``Sora``: ``connect(configuration:webRTCConfiguration:handler:)``: 実行中に接続の試行をキャンセル可能にする
    - @szktty
- [ADD] API: ``ConnectionTask``: 追加する
    - @szktty

## 2.1.3

- [UPDATE] システム条件を更新する
    - macOS 10.13.6 以降
    - Xcode 9.4
    - Swift 4.1
    - @szktty
- [FIX] MediaChannel: 接続解除後、サーバーにしばらく接続が残る可能性がある現象を修正する
    - @szktty

## 2.1.2

- [UPDATE] WebRTC M66 に対応する
    - @szktty
- [UPDATE] WebRTC SFU Sora 18.04 以降に対応する
    - @szktty

## 2.1.1

- [UPDATE] システム条件を更新する
    - macOS 10.13.2 以降
    - Xcode 9.3
    - Swift 4.1
    - Carthage 0.29.0 以降、または CocoaPods 1.4.0 以降
    - WebRTC SFU Sora 18.02 以降
    - @szktty
- [ADD] API: ``MediaStream``: ``remoteAudioVolume`` プロパティを追加する
    - @szktty
- [CHANGE] API: ``MediaStream``: ``audioVolume`` プロパティを非推奨にする
    - @szktty
- [FIX] API: ``MediaStream``: 配信中に ``videoEnabled`` プロパティまたは ``audioEnabled`` プロパティで映像か音声を無効にすると、有効に戻しても他のクライアントに配信が再開されない現象を修正する
    - @szktty
- [FIX] API: ``WebRTCInfo``: ``shortRevision``: 戻り値の文字列が 7 桁でない現象を修正する
    - @szktty

## 2.1.0

- [ADD] 視聴のみのマルチストリームに対応する
    - @szktty
- [ADD] 音声検出による映像の動的切替に対応する
    - @szktty
- [ADD] API: ``Role``: ``.groupSub`` を追加する
    - @szktty
- [ADD] API: ``Configuration``: ``maxNumberOfSpeakers`` プロパティを追加する
    - @szktty
- [ADD] API: ``SignalingConnectMessage``: ``maxNumberOfSpeakers`` プロパティを追加する
    - @szktty

## 2.0.4

- [UPDATE] WebRTC M64 に対応する
    - @szktty

## 2.0.3

- [UPDATE] WebRTC M63 に対応する
    - @szktty
- [UPDATE] SDWebImage 4.2.2 に対応する
    - @szktty
- [ADD] API: ``WebSocketChannelHandlers``: ``onDisconnectHandler`` を追加する
    - @szktty
- [ADD] API: ``SignalingChannelHandlers``: ``onDisconnectHandler`` を追加する
    - @szktty
- [ADD] API: ``PeerChannelHandlers``: ``onDisconnectHandler`` を追加する
    - @szktty
- [CHANGE] API: ``SoraError``: WebSocket に関するエラーを次の二つに分割する
    - ``webSocketClosed(statusCode:reason:)``
    - ``webSocketError()``
    - @szktty
- [CHANGE] API: ``WebSocketChannelHandlers``: ``onFailureHandler`` を削除する
    - @szktty
- [CHANGE] API: ``SignalingChannelHandlers``: ``onFailureHandler`` を削除する
    - @szktty
- [CHANGE] API: ``PeerChannelHandlers``: ``onFailureHandler`` を削除する
    - @szktty
- [CHANGE] API: ``MediaChannelHandlers``: ``onFailureHandler`` を削除する
    - @szktty
- [FIX] API: ``MediaChannel``: ``PeerChannel`` の接続解除時に ``MediaChannel`` の状態が接続解除にならない現象を修正する
    - @szktty

## 2.0.2

- [ADD] connect シグナリングメッセージに Offer SDP を含めるようにする
    - @szktty
- [ADD] API: MediaStreamAudioVolume: 追加する
    - @szktty
- [ADD] API: MediaStream: audioVolume プロパティを追加する
    - @szktty
- [FIX] API: MediaStream: videoEnabled: 映像をオフにしても VideoView に反映されない現象を修正する
    - @szktty
- [FIX] API: MediaStream: audioEnabled: 音声の可否がサブスクライバーに反映されない現象を修正する
    - @szktty

## 2.0.1

- [UPDATE] Xcode 9.1 に対応する
    - @szktty
- [ADD] API: MediaStream: 接続中に映像と音声の送受信を停止・再開するプロパティを追加する
    - @szktty
- [ADD] API: MediaStreamHandlers: 追加する
    - @szktty

## 2.0.0

設計と API を大きく見直した。

- [UPDATE] WebRTC M62 に対応する
    - @szktty
- [UPDATE] アーキテクチャ armv7 に対応する
    - @szktty
- [UPDATE] iOS 11 に対応する
    - @szktty
- [UPDATE] Xcode 9 に対応する
    - @szktty
- [UPDATE] Swift 4 に対応する
    - @szktty
- [UPDATE] クライアントの設定を ``Configuration`` にまとめる
    - @szktty
- [ADD] ロールについて、 "パブリッシャー (Publisher)" と "サブスクライバー (Subscriber)" に加えて、マルチストリームで通信を行う "グループ (Group)" を追加する
    - @szktty
- [ADD] 任意の映像キャプチャーの使用を可能にする
    - @szktty
- [ADD] ``CMSampleBuffer`` を映像フレームとして使用可能にする
    - @szktty
- [ADD] 映像フレームの編集を可能にする
    - @szktty
- [CHANGE] 依存するフレームワークから Unbox.framework を削除する
    - @szktty
- [CHANGE] WebRTC のネイティブ API (主にクラスやプロトコル名の接頭辞が ``RTC`` の API) を非公開にする
    - @szktty
- [CHANGE] 通信を行うオブジェクト (WebSocket 接続、シグナリング接続、ピア接続、メディアストリーム) をプロトコルに変更する (デフォルトの実装は ``private``)
    - @szktty
- [CHANGE] 内部で使用する WebSocket の API (SRWebSocket.framework の API) を非公開にする
    - @szktty

### API

- [ADD] 次のクラスを追加する
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
- [ADD] 次の構造体を追加する
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
- [ADD] 次の列挙体を追加する
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
- [ADD] 次のプロトコルを追加する
    - ``MediaStream``
    - ``PeerChannel``
    - ``SignalingChannel``
    - ``VideoCapturer``
    - ``ViderFilter``
    - ``WebSocketChannel``
    - @szktty
- [ADD] ``Role``
  - ``.group`` を追加する
    - @szktty
- [CHANGE] 次のクラス、構造体、列挙体、プロトコルを削除する
    - ``Attendee``: 同等の機能を ``MediaChannel`` に実装する
    - ``BuildInfo``: 同等の機能を ``WebRTCInfo`` に実装する
    - ``Connection``: パブリッシャーとサブスクライバーをそれぞれ独立させたため削除する
    - ``ConnectionController``: 同等の機能を削除する
    - ``ConnectionController.Request``
    - ``ConnectionController.Role``
    - ``ConnectionController.StreamType``
    - ``ConnectionError``: 同等の機能を ``SoraError`` に実装する
    - ``Event``: 各イベントをイベントハンドラのみで扱うようにする
    - ``Event.EventType``
    - ``EventLog``: ロギング機能を削除する
    - ``MediaConnection``: 同等の機能を ``MediaChannel`` に実装する
    - ``MediaPublisher``: パブリッシャーを ``MediaChannel`` で扱うようにするため削除する
    - ``MediaSubscriber``: サブスクライバーを ``MediaChannel`` で扱うようにするため削除する
    - ``MediaOption``: 同等の機能を ``Configuration`` に実装する
    - ``Message``: 同等の機能を ``SignalingMessage`` に実装する
    - ``Message.MessageType``
    - ``Messagable``
    - ``PeerConnection``: 同等の機能を ``PeerChannel`` に定義する
    - ``PeerConnectionEventHandlers``: 同等の機能を ``PeerChannelHandlers`` に実装する
    - ``SignalingEventHandlers``: 同等の機能を ``SignalingChannelHandlers`` に実装する
    - ``SignalingNotify``: 同等の機能を ``SignalingNotifyMessage`` に実装する
    - ``SignalingSnapshot``: 同等の機能を ``SignalingSnapshotMessage`` に実装する
    - ``VideoFrameHandle``: 同等の機能を ``VideoFrame`` に実装する
    - ``WebSocketEventHandlers``: 同等の機能を ``WebSocketChannelHandlers`` に実装する
    - @szktty
- [CHANGE] ``Notification`` の使用を中止し、次の関連する構造体と列挙体を削除する
    - ``Connection.NotificationKey``
    - ``Connection.NotificationKey.UserInfo``
    - ``MediaConnection.NotificationKey``
    - ``MediaConnection.NotificationKey.UserInfo``
    - ``MediaStream.NotificationKey``
    - ``MediaStream.NotificationKey.UserInfo``
    - @szktty
- [CHANGE] ``AudioCodec``
    - ``.Opus`` を ``.opus`` に変更する
    - ``.PCMU`` を ``.pcmu`` に変更する
    - @szktty
- [CHANGE] ``MediaStream``
    - クラスからプロトコルに変更し、 API を一新する
- [CHANGE] ``VideoCodec``
    - ``.VP8`` を ``.vp8`` に変更する
    - ``.VP9`` を ``.vp9`` に変更する
    - ``.H264`` を ``.h264`` に変更する
    - @szktty
- [CHANGE] ``VideoFrame``
    - プロトコルから列挙体に変更し、 API を一新する
    - @szktty
- [CHANGE]] ``VideoRenderer``
    - ``onChangedSize(_:)`` を ``onChange(size:)`` に変更する
    - ``renderVideoFrame(_:)`` を ``render(videoFrame:)`` に変更する
    - @szktty

## 1.2.5

- [FIX] CircleCI でのビルドエラーを修正する
    - @szktty

## 1.2.4

- [UPDATE] armv7 に対応する
    - @szktty
- [CHANGE] API: MediaOption を struct に変更する
    - @szktty
- [CHANGE] API: ConnectionController: ロールとストリーム種別の選択制限を削除する
    - @szktty
- [FIX] API: マルチストリーム時、配信者のストリームが二重に生成されてしまう現象を修正する
    - @szktty

## 1.2.3

- [UPDATE] API: VideoView: ``contentMode`` に応じて映像のサイズを変更するようにする
    - @szktty
- [FIX] API: 残っていたデバッグプリントを削除する
    - @szktty

## 1.2.2

- [UPDATE] API: 一部の静的変数を定数に変更する
    - @szktty
- [FIX] API: VideoView: メモリー解放時に Key-Value Observing に関する例外が発生する現象を修正する
    - @szktty
- [FIX] API: VideoView: メモリー解放時にクラッシュする現象を修正する
    - @szktty

## 1.2.1

- [FIX] API: ConnectionController: 指定する映像・音声コーデックが UI とシグナリングに反映されない現象を修正する
    - @szktty

## 1.2.0

- [UPDATE] WebRTC M60 に対応する
    - @szktty
- [UPDATE] Bitcode に対応する
    - @szktty
- [UPDATE] スナップショットに対応する
    - @szktty
- [UPDATE] API: VideoView: スナップショットの描画に対応する
    - @szktty
- [ADD] リンクするフレームワークに SDWebImage.framework を追加する
    - @szktty
- [ADD] API: Event.EventType: 次のケースを追加する
    - ``case Snapshot``
    - @szktty
- [ADD] API: MediaOption: 次のプロパティを追加する
    - ``var snapshotEnabled``
    - @szktty
- [ADD] API: SignalingEventHandlers: 次のメソッドを追加する
    - ``func onSnapshot(handler: (SignalingSnapshot) -> Void)``
    - @szktty
- [ADD] API: SignalingSnapshot: 追加する
    - @szktty
- [ADD] API: Snapshot: 追加する
    - @szktty
- [ADD] API: VideoFrameHandle: 次のプロパティを追加する
    - ``case snapshot``
    - @szktty
- [ADD] API: ConnectionController: スナップショットの項目を追加する
    - @szktty
- [CHANGE] API: VideoFrame
    - ``var width``: ``Int32`` -> ``Int``
    - ``var height``: ``Int32`` -> ``Int``
    - ``var timestamp``: ``CMTime`` -> ``CMTime?``
    - @szktty
- [CHANGE] API: VideoFrameHandle: 次のプロパティ名を変更する
    - ``case webRTC`` -> ``case WebRTC``
    - @szktty

## 1.1.0

- [UPDATE] WebRTC M59 に対応する
    - @szktty
- [ADD] CircleCI を利用する自動ビルドを追加
    - @szktty
- [ADD] シグナリング "notify" に対応する
    - @szktty
- [ADD] イベントログに接続エラーの詳細を出力するようにする
    - @szktty
- [ADD] API: Attendee: 追加する
    - @szktty
- [ADD] API: ConnectionError: ``var description`` を追加する
    - @szktty
- [ADD] API: ConnectionController: ビットレートの設定項目を追加する
    - @szktty
- [ADD] API: ConnectionController: イベントログの画面を追加する
    - @szktty
- [ADD] API: Event.EventType: ``ConnectionMonitor`` を追加する
    - @szktty
- [ADD] API: MediaConnection: 次のプロパティとメソッドを追加する
    - ``var numberOfConnections``
    - ``func onAttendeeAdded(handler:)``
    - ``func onAttendeeRemoved(handler:)``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [ADD] API: Role: 追加する
    - @szktty
- [ADD] API: SignalingEventHandlers: ``func onNotify(handler:)`` を追加する
    - @szktty
- [ADD] API: SignalingEventType: 追加する
    - @szktty
- [ADD] API: SignalingNotify: 追加する
    - @szktty
- [ADD] API: SignalingRole: 追加する
    - @szktty
- [CHANGE] examples を削除
    - @szktty
- [CHANGE] ディレクトリ構造を変更し、プロジェクトのファイルをトップレベルに移動する
    - @szktty
- [CHANGE] API: PeerConnection: 接続状態に関わらず WebSocket のイベントハンドラを実行するようにする
    - @szktty
- [CHANGE] 次の不要なファイルを削除する
    - ``JSON.swift``
    - @szktty
- [CHANGE] API: BuildInfo: 次のプロパティを削除する
    - ``var VP9Enabled``
    - @szktty
- [CHANGE] API: Connection: 次のプロパティとメソッドを削除する
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [CHANGE] API: ConnectionController: Cancel ボタンを Back ボタンに変更する
    - @szktty
- [CHANGE] API: MediaStreamRole: 削除する
    - @szktty
- [CHANGE] API: VideoFrame の型を変更する
    - ``var width``: ``Int`` -> ``Int32``
    - ``var height``: ``Int`` -> ``Int32``
    - @szktty
- [CHANGE] API: ConnectionController: VP9 の有効・無効を示すセルを削除する
    - @szktty
- [FIX] Sora サーバーの URL のプロトコルが ws または wss 以外であればエラーにする
    - @szktty
- [FIX] 接続解除可能な状況でも ``connectionBusy`` のエラーが発生する現象を修正する
    - @szktty
- [FIX] 接続解除後も内部で接続状態の監視を続ける現象を修正する
    - @szktty
- [FIX] API: ConnectionController: 接続画面外で接続が解除されても接続画面では接続状態である現象を修正する
    - @szktty
- [FIX] API: VideoView のサイズの変化に動画のサイズが追従しない現象を修正する
    - @szktty

## 1.0.1

- [UPDATE] システム条件を更新する
    - Xcode 8.1 以降 -> 8.3.2 以降
    - Swift 3.0.1 -> 3.1
    - Sora 17.02 -> 17.04
    - @szktty
- [UPDATE] SoraApp の Cartfile で利用する shiguredo/sora-ios-sdk を 1.0.1 にアップデートする
    - @szktty

## 1.0.0

- [UPDATE] WebRTC M57 に対応する
    - @szktty
- [UPDATE] API: MediaCapturer: 同一の RTCPeerConnectionFactory で再利用するようにする
    - @szktty
- [UPDATE] API: MediaCapturer: 映像トラック名と音声トラック名を自動生成するようにする
    - @szktty
- [UPDATE] API: VideoRenderer: 描画処理をメインスレッドで実行するようにする
    - @szktty
- [UPDATE] API: VideoView: UI の設計に Nib ファイルを利用するようにする
    - @szktty
- [UPDATE] API: VideoView: バックグラウンド (ビューがキーウィンドウに表示されていない) では描画処理を中止するようにする
    - @szktty
- [UPDATE] API: VideoView: 映像のアスペクト比を保持するようにする
    - @szktty
- [UPDATE] API: MediaConnection: MediaStream を複数保持するようにする
    - @szktty
- [ADD] マルチストリームに対応する
    - @szktty
- [ADD] シグナリング: "notify" に対応する
    - @szktty
- [ADD] API: MediaConnection: ``multistreamEnabled`` プロパティを追加する
    - @szktty
- [ADD] API: MediaPublisher: ``autofocusEnabled`` プロパティを追加する
    - @szktty
- [ADD] API: PeerConnection: RTCPeerConnection のラッパーとして追加する
    - @szktty
- [ADD] API: BuildInfo: 追加する
    - @szktty
- [ADD] API: ConnectionController: 追加する
    - @szktty
- [ADD] API: Connection: 次の API を追加する
    - ``var numberOfConnections``
    - ``func onChangeNumberOfConnections(handler:)``
    - @szktty
- [ADD] API: Connection, MediaConnection, MediaStream, PeerConnection: 次のイベントで (NotificationCenter による) 通知を行うようにする
    - onConnect
    - onDisconnect
    - onFailure
    - @szktty
- [ADD] API: WebSocketEventHandlers, SignalingEventHandlers, PeerConnectionEventHandlers: イニシャライザーを追加する
    - @szktty
- [CHANGE] 対応アーキテクチャを arm64 のみにする
    - @szktty
- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "stats" への対応を廃止する
    - @szktty
- [CHANGE] シグナリング: Sora の仕様変更に伴い、 "connect" の "access_token" パラメーターを "metadata" に変更する
    - @szktty
- [CHANGE] API: ArchiveFinished: 削除する
    - @szktty
- [CHANGE] API: ArchiveFailed: 削除する
    - @szktty
- [CHANGE] API: MediaConnection: 次の変数の型を変更する
    - ``webSocketEventHandlers``: ``WebSocketEventHandlers?`` --> ``WebSocketEventHandlers``
    - ``signalingEventHandlers``: ``SignalingEventHandlers?`` --> ``SignalingEventHandlers``
    - ``peerConnectionEventHandlers``: ``PeerConnectionEventHandlers?`` --> ``PeerConnectionEventHandlers``
    - @szktty
- [CHANGE] API: MediaConnection: ``connect(accessToken:timeout:handler:)`` メソッドの型を ``connect(metadata:timeout:handler:)`` に変更する
    - @szktty
- [CHANGE] API: MediaConnection, MediaStream: 次の API を MediaStream に移行する
    - ``var videoRenderer``
    - ``func startConnectionTimer(timeInterval:handler:)``
    - @szktty
- [CHANGE] API: MediaConnection.State: 削除する
    - @szktty
- [CHANGE] API: MediaOption.AudioCodec: ``unspecified`` を ``default`` に変更する
    - @szktty
- [CHANGE] API: MediaOption.VideoCodec: ``unspecified`` を ``default`` に変更する
    - @szktty
- [CHANGE] API: MediaStream: RTCPeerConnection のラッパーではなく、 RTCMediaStream のラッパーに変更する
    - @szktty
- [CHANGE] API: MediaStream: ``startConnectionTimer(timeInterval:handler:)``: タイマーを起動する瞬間もハンドラーを実行するようにする
    - @szktty
- [CHANGE] API: MediaStream.State: 削除する
    - @szktty
- [CHANGE] API: SignalingConnected: 削除する
    - @szktty
- [CHANGE] API: SignalingCompleted: 削除する
    - @szktty
- [CHANGE] API: SignalingDisconnected: 削除する
    - @szktty
- [CHANGE] API: SignalingFailed: 削除する
    - @szktty
- [CHANGE] API: StatisticsReport: RTCStatsReport の変更 (名前が RTCLegacyStatsReport に変更された) に伴い削除する
    - @szktty
- [FIX] シグナリング: 音声コーデック Opus を指定するためのパラメーターの間違いを修正する
    - @szktty
- [FIX] 接続解除後にイベントログを記録しようとして落ちる現象を修正する
    - @szktty
- [FIX] 接続失敗時にデバイスを初期化しようとして落ちる現象を修正する (接続成功時のみ初期化するようにする)
    - @szktty
- [FIX] 接続試行中にエラーが発生して失敗するにも関わらず、成功と判断されてしまう場合がある現象を修正する
    - @szktty
- [FIX] API: MediaConnection: 接続解除後もタイマーが実行されてしまう場合がある現象を修正する (タイマーに関する API は MediaStream に移動する)
    - @szktty
- [FIX] API: PeerConnection: 接続失敗時でもタイムアウト時のイベントハンドラが呼ばれる現象を修正する
    - @szktty

## 0.1.0

**公開**
