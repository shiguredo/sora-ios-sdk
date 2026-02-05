# 変更履歴

- CHANGE
  - 下位互換のない変更
- UPDATE
  - 下位互換がある変更
- ADD
  - 下位互換がある追加
- FIX
  - バグ修正

## develop

- [UPDATE] libwebrtc m144.7559.2.1 に上げる
  - @t-miya
- [UPDATE] Statistics, StatisticsEntry をドキュメント対象として公開する
  - `getStats` メソッドの返り値である `Statistics` のドキュメントを生成するため
  - @t-miya
- [UPDATE] Configuration.simulcastRid を非推奨にする
  - 移行先は `Configuration.simulcastRequestRid`
  - @zztkm
- [UPDATE] MediaChannelHandlers.onReceiveSignaling を非推奨にする
  - 移行先は `MediaChannelHandlers.onReceiveSignalingText`
  - @zztkm
- [ADD] MediaChannel に シグナリング の JSON 文字列 を 受け取る `onReceiveSignalingText` を追加する
  - @zztkm
- [ADD] MediaChannel に音声ソフトミュートを設定する `setAudioSoftMute(_:)` を追加する
  - 送信ストリームの AudioTrack を取得し、MediaStream.audioEnabled を切り替える
    - デジタルサイレンスパケットが送られる状態となり、マイクからの音声は送出されない
  - MediaChannel から AudioTrack の有無判定を行うため、 MediaStream に `hasAudioTrack` を追加する
  - @t-miya
- [ADD] MediaChannel に映像ソフトミュートを設定する `setVideoSoftMute(_:)` を追加する
  - 送信ストリームの VideoTrack を取得し、MediaStream.videoEnabled を切り替える
  - MediaChannel から VideoTrack の有無判定を行うため、 MediaStream に `hasVideoTrack` を追加する
  - @t-miya
- [ADD] MediaChannel に映像ハードミュートを設定する `setVideoHardMute(_:)` を追加する
  - CameraVideoCapturer の `stop` と `restart` のラッパー
    - ハードミュートの複数同時実行を防ぐための Actor `VideoHardMuteActor` を追加する
  - 映像ソフトミュートも併用し、黒塗りフレームの状態で停止させる
  - @t-miya
- [ADD] 音声のハードミュート有効化/無効化機能を追加する
  - iOS 端末のマイクインジケーターを消灯させる
  - AudioDeviceModuleWrapper クラスを追加する
    - RTCAudioDeviceModule の pauseRecording/resumeRecording を実行するためのラッパークラス
    - インスタンスは NativePeerChannelFactory が保持する
  - MediaChannel に setAudioHardMute(_:) を追加する
    - 内部で NativePeerChannelFactory 経由で AudioDeviceModuleWrapper.setAudioHardMute(_:) を呼び出す
  - @t-miya
- [ADD] MediaChannel に libwebrtc の統計情報を取得する `getStats` メソッドを追加する
  - @t-miya
- [ADD] RTCAudioTrack から音声データを受け取るためのコールバックプロトコルである RTCAudioTrackSink を追加する
  - @zztkm
- [ADD] MediaStream に RTCAudioTrackSink を RTCAudioTrack と関連付ける / 関連付けを解除するためのメソッドを追加する
  - 追加したメソッド
    - `addAudioTrackSink(_ sink: RTCAudioTrackSink)`
    - `removeAudioTrackSink(_ sink: RTCAudioTrackSink)`
  - @zztkm
- [ADD] シグナリング接続時に視聴するストリームの rid を指定する `Configuration.simulcastRequestRid: SimulcastRequestRid` を追加する
  - rid を指定できる値の列挙型として SimulcastRequestRid を追加する
    - デフォルト値の `unspecified` の場合はシグナリングパラメータに `simulcast_request_rid` を含めない
  - role が sendrecv または recvonly の場合、かつ simulcast が true の場合にのみ有効
  - @zztkm
- [ADD] サイマルキャストの rid を表す汎用型 `Rid` 列挙型を追加する
  - @zztkm
- [ADD] RPC 機能を追加する
  - RPC メソッドを表す列挙型 `RPCMethod` を追加する
  - `SignalingOffer` に以下の項目を追加する
    - `rpcMethods: [String]?`
  - `MediaChannel` に `rpc` メソッドを追加する
  - `MediaChannel` に `rpcMethods: [RPCMethod]` を追加する
  - RPC メソッドを定義するための `RPCMethodProtocol` プロトコルを追加する
  - `RPCMethodProtocol` に準拠した型を追加する
    - `RequestSimulcastRid`
    - `RequestSpotlightRid`
    - `ResetSpotlightRid`
    - `PutSignalingNotifyMetadata`
    - `PutSignalingNotifyMetadataItem`
  - RPC の ID を表す `RPCID` 列挙型を追加する
    - `int(Int)` と `string(String)` の 2 つのケースをサポート
  - RPC エラー応答の詳細を表す `RPCErrorDetail` 構造体を追加する
  - RPC 成功応答を表す `RPCResponse<Result>` ジェネリック構造体を追加する
  - DataChannel 経由の RPC を扱う `RPCChannel` クラスを追加する
  - `SoraError` に RPC 関連のエラーケースを追加する
    - `rpcUnavailable(reason: String)`
    - `rpcMethodNotAllowed(method: String)`
    - `rpcEncodingError(reason: String)`
    - `rpcDecodingError(reason: String)`
    - `rpcDataChannelClosed(reason: String)`
    - `rpcTimeout`
    - `rpcServerError(detail: RPCErrorDetail)`
  - @zztkm

### misc

- [UPDATE] GitHub Actions のビルド環境を更新する
  - macOS の version を 26 に変更
  - Xcode の version を 26.2 に変更
  - SDK を iOS 26.2 に変更
  - @t-miya
- [UPDATE] SwiftLint を 0.63.0 に上げる
  - @zztkm
- [UPDATE] `Claude Assistant` の `claude-response` を `ubuntu-slim` に移行する
  - @zztkm
- [UPDATE] jazzy の設定ファイルを更新する
  - `module_version` を 2025.3.0 に変更
  - @zztkm
- [ADD] `Package.swift` に `testTarget` を追加する
  - xcodebuild で test を実行するために target を追加
  - @zztkm
- [FIX] GitHub Actions のビルド環境を更新する
  - macOS 15 での利用中に `error: iOS 18.4 Platform Not Installed.` となってしまったため
  - Xcode の version を 16.4 に変更
  - SDK を iOS 18.5 に変更
  - @t-miya

## 2025.2.0

**リリース日**: 2025-09-18

- [CHANGE] connect メッセージの `multistream` を true 固定で送信する処理を削除する破壊的変更
  - Configuration.role に .sendrecv を指定している場合に multistream を true に更新する処理を削除
  - Configuration.spotlightEnabled に .enabled を指定している場合に multistream を true に更新する処理を削除
  - 結果、connect メッセージには Configuration.multistreamEnabled に指定した値が送信される
  - 今後は Configuration.role に .sendrecv を指定している場合または Configuration.spotlightEnabled に .enabled を指定している場合に Configuration.multistreamEnabled に false を指定すると接続エラーになる
  - @zztkm
- [CHANGE] `MediaChannelHandlers` の `onDisconnect: ((Error?) -> Void)?` を `onDisconnectLegacy` という名前に変更し、非推奨にする
  - `onDisconnect: ((SoraCloseEvent) -> Void)?` に移行するため、名前を変更した
  - @zztkm
- [CHANGE] CocoaPods でのライブラリ提供を廃止する
  - `Sora.podspec` を削除した
  - @zztkm
- [UPDATE] WebRTC m138.7204.0.3 に上げる
  - @zztkm
- [UPDATE] `Configuration.multistreamEnabled` を非推奨にする
  - 合わせて `Configuration` のイニシャライザの multistreamEnabled をオプション引数にし、デフォルト値を nil に変更
  - @zztkm
- [UPDATE] WebRTCConfigration.swift を WebRTCConfiguration.swift にリネームする
  - @zztkm
- [UPDATE] Sora との接続を終了した際のイベント情報を表す、SoraCloseEvent を追加する
  - @zztkm
- [UPDATE] `MediaChannelHandlers` に `onDisconnect: ((SoraCloseEvent) -> Void)?` を追加する
  - @zztkm
- [ADD] サイマルキャストの映像のエンコーディングパラメーター `scaleResolutionDownTo` を追加する
  - @zztkm
- [ADD] Sora から DataChannel シグナリングを切断する際に "type": "close" メッセージを受信する機能を追加する
  - DataChannel シグナリングが有効、かつ ignore_disconnect_websocket が true、かつ Sora の設定で data_channel_signaling_close_message が有効な場合に受信することが可能
  - "type": "close" に対応するため、 `Signaling` のケースに `close` を追加した
    - `close` の associated value の型である `SignalingClose` 構造体を追加した
  - `SoraError` に DataChannel シグナリングで "type": "close" を受信して接続が解除されたことを表すケースである `dataChannelClosed` を追加した
  - @zztkm
- [FIX] Sora から切断された場合の切断処理を修正し適切なエラーを ``MediaChannelHandlers.onDisconnect`` で受け取ることができるようにする
  - Sora iOS SDK 2025.1.1 までは Sora から Close Frame を受け取ったり、ネットワークエラーが起きたりしても、WebSocket メッセージ受信失敗に起因する ``SoraError.webSocketError`` しか受信できなかったが、以下の内容を受信できるようになった
    - Sora から Close Frame を受け取った場合のステータスコードと理由
      - ステータスコードが 1000 で正常に切断された場合も ``MediaChannelHandlers.onDisconnect`` で通知する
    - ネットワークエラーや Sora がダウンした場合のエラー内容
  - この変更によって ``MediaChannelHandlers.onDisconnect`` で受信するメッセージの内容は変わるが、コールバックが発火するタイミングに変更はない
  - @zztkm

### misc

- [CHANGE] フォーマッターを swift-format に移行する
  - SwiftFormat のための設定ファイルである .swiftformat と .swift-version を削除
  - フォーマット設定はデフォルトを採用したため、.swift-format は利用しない
  - swift-format のデフォルト設定で、format lint を行った結果、警告が出た部分はすべて修正
  - JSON デコード処理に使う JSON のキー名を指定するための enum の定義については、`AlwaysUseLowerCamelCase` ルールを無効化するためのコメントを追加
    - シグナリングメッセージのキー名にスネークケースが採用されている項目があるため、この対応を行った
  - @zztkm
- [UPDATE] システム条件を変更する
  - CocoaPods 廃止に伴いシステム条件から削除
  - WebRTC SFU Sora 2025.1.0 以降
  - @zztkm
- [UPDATE] SwiftLint の管理を CocoaPods から Swift Package Manager に移行する
  - @zztkm
- [UPDATE] 開発用の依存管理を Swift Package Manager に移行したため Podfile.dev を削除する
  - GitHub Actions で Podfile.dev を利用していたため、利用しないように変更
  - @zztkm
- [UPDATE] GitHub Actions で Lint と Format Lint を行うコマンドを Makefile に変更
  - 今まで lint-format.sh で一括実行したところを Makefile に移行したので、GitHub Actions でも Makefile を利用するように変更
  - @zztkm
- [UPDATE] フォーマッターとリンターの実行を Makefile に移行したため、不要になった lint-format.sh を削除
  - @zztkm
- [UPDATE] GitHub Actions のビルド環境を更新する
  - Xcode の version を 16.3 に変更
  - SDK を iOS 18.4 に変更
  - @zztkm
- [UPDATE] CocoaPods の廃止対応のため、canary.py から Sora.podspec の更新処理を削除する
  - @zztkm
- [UPDATE] フォーマッターの設定に合わせて canary.py で PackageInfo.swift に書き込む際のスペースを 4 から 2 に変更する
  - @zztkm
- [UPDATE] canary.py でファイルの読み書きを行う際の encoding を明示的に utf-8 に設定する
  - Windows 環境で canary.py を実行した際に、予期せぬ文字化けが発生してしまうため修正を行った
  - @zztkm
- [UPDATE] GitHub Actions での CI で依存関係の解決を Swift Package Manager で行うようにする
  - CocoaPods 関連のステップ（Show CocoaPods Version、Restore Pods、Install Dependences）を削除
  - xcodebuild コマンドから -workspace オプションを削除し、-scheme のみを使用するように変更
  - xcodebuild に -destination 'generic/platform=iOS' オプションを追加
    - GitHub Actions では実機デバイスが存在しないので、特定のデバイスを指定するのではなく `generic/` をつけて iOS を汎用ターゲットとして指定した
  - WebRTC Non-public API チェックを Swift Package Manager のビルド成果物のパスに変更
  - 不要な Sora.xcodeproj、Podfile、Gemfile、を削除
    - `Sora.xcodeproj` があると、Package.swift の依存関係を参照しないため削除した
    - このリポジトリで CocoaPods を利用しなくなるため、Podfile と Gemfile を削除した
  - @zztkm
- [UPDATE] jazzy の設定ファイルを更新する
  - `swift_build_tool` に `xcodebuild` を指定して、xcodebuild が使われるように設定した
  - CocoaPods 削除に合わせて `xcodebuild_arguments` の更新
    - xcodebuild でのビルドのために `-destination 'generic/platform=iOS'` を追加した
    - Sora.xcworkspace がなくなったため `-workspace` オプションを削除した
    - xcodebuild 側で iOS 向け SDK を決定してくれるため、`-sdk` オプションを削除した
    - xcodebuild 側で Swift のコンパイルが行われるため Swift のバージョン指定は不要と判断し `swift_version` オプションを削除した
  - @zztkm
- [UPDATE] actions/checkout@v4 を @v5 に上げる
  - @torikizi
- [UPDATE] build.yml の `release` job は運用上利用していないため、削除する
  - @torikizi
- [ADD] swift-format と SwiftLint 実行用の Makefile を追加する
  - lint-format.sh で実行していたコマンドを個別に実行できるようにした

## 2025.1.3

**リリース日**: 2025-07-28

- [FIX] Sora の設定が、DataChannel 経由のシグナリングの設定、かつ、WebSocket の切断を Sora への接続が切断したと判断しない設定の場合に、SDP 再交換に失敗することがある問題を修正する
  - WebSocket 経由から DataChannel 経由へのシグナリング切替時に `type: switched` と `type: re-offer` をほぼ同時に受信した際、`type: re-answer` を WebSocket 経由で送信する前に WebSocket を切断してしまい `type: re-answer` の送信に失敗することがあるため
  - DataChannel 経由へのシグナリング切替後でも、まだ WebSocket 経由で送信中のメッセージが存在する可能性を考慮し、余裕を持って切断するために 10 秒の待機時間を設けるようにした
  - WebSocket を切断する前に PeerChannel の接続状態を確認する処理を追加し、既に切断されている場合は WebSocket の切断処理を呼ばないようにした
  - @zztkm

## 2025.1.2

**リリース日**: 2025-05-07

- [FIX] マルチストリーム利用時に SDP 再ハンドシェイク中に SDK が終了処理をした際に EXC_BAD_ACCESS (不正なメモリアクセス) によりクラッシュする問題を修正する
  - SDP 再ハンドシェイク処理である `createAndSendReAnswer` と `createAndSendReAnswerOverDataChannel` で参照カウンタを加算する lock() の呼び出し位置を以下のように変更
    - 変更前: createAnswer 呼び出し前
    - 変更後: createAnswer の引数である handler (クロージャー) 内
  - これにより、SDP 再ハンドシェイク中に SDK が終了処理をした際に不正なメモリアクセスが発生することがなくなった
  - @zztkm

## 2025.1.1

**リリース日**: 2025-01-23

- [FIX] WebRTC m132.6834.5.2 に上げる
  - Apple 非公開 API を利用していたため、App Store Connect へのアップロードに失敗する問題に対応
  - @zztkm

## 2025.1.0

**リリース日**: 2025-01-21

- [UPDATE] WebRTC m132.6834.5.1 に上げる
  - @miosakuma @zztkm
- [UPDATE] システム条件の iOS を 14.0 に上げる
  - IPHONEOS_DEPLOYMENT_TARGET を 14.0 に上げる
  - SwiftPM の platforms の設定を v14 に上げる
  - CocoaPods の platform の設定を 14.0 に上げる
  - libwebrtc の対象バージョンに追従した
    - <https://webrtc.googlesource.com/src/+/9b81d2c954128831c62d8a0657c7f955b3c02d32>
  - @miosakuma
- [UPDATE] SignalingOffer に項目を追加する
  - 追加する項目
    - `version`
    - `simulcastMulticodec`
    - `spotlight`
    - `channelId`
    - `sessionId`
    - `audio`
    - `audioCodecType`
    - `audioBitRate`
    - `video`
    - `videoCodecType`
    - `videoBitRate`
  - @zztkm
- [UPDATE] SignalingNotify に項目を追加する
  - 追加する項目
    - `timestamp`
    - `spotlightNumber`
    - `failedConnectionId`
    - `currentState`
    - `previousState`
  - @zztkm
- [ADD] `ForwardingFilter` に name と priority を追加する
  - @zztkm
- [ADD] シグナリング connect 時にリスト形式の転送フィルターを設定するための項目を追加する
  - `Configuration`, `SignalingConnect` に forwardingFilters を追加する
  - @zztkm


### misc

- [CHANGE] GitHub Actions の ubuntu-latest を ubuntu-24.04 に変更する
  - @voluntas
- [UPDATE] システム条件を変更する
  - iOS 14 以降
  - Xcode 16.0
  - macOS の条件を外す
    - Xcode とほぼ同時更新なので一旦不要と判断
  - @miosakuma
- [UPDATE] GitHub Actions のビルド環境を更新する
  - runner を macos-15 に変更
  - Xcode の version を 16.2 に変更
  - SDK を iOS 18.2 に変更
  - @zztkm
- [UPDATE] jazzy の設定ファイルを更新する
  - `swift_version` を 6.0.3 に変更
  - `xcodebuild_arguments` の iphoneos を 18.2 に変更
  - @zztkm
- [ADD] canary.py を追加する
  - @zztkm

## 2024.3.0

**リリース日**: 2024-09-06

- [CHANGE] `MediaChannelConfiguration` を非推奨にする
  - SDK 内部では利用していないため
  - @zztkm
- [UPDATE] WebRTC m127.6533.1.1 に上げる
  - @miosakuma
  - @zztkm
- [UPDATE] `SignalingOffer` に `simulcast` を追加する
  - @zztkm
- [FIX] SignalingConnect の `metadata`, `signaling_notify_metadata` が nil の場合に {} として送信されてしまう問題を修正する
  - @zztkm
- [FIX] `WrapperVideoEncoderFactory.shared.simulcastEnabled` の値を type: offer の際に設定される simulcast の値で上書きする
  - 認証ウェブフック成功時に払い出された type: offer の `simulcast` の値が反映されない不具合への対応
  - @zztkm
- [FIX] `Configuration.spotlightEnabled` はサイマルキャストを有効化するための条件ではないのに、判定条件に加わっていた問題を修正する
  - `WrapperVideoEncoderFactory.shared.simulcastEnabled` の判定条件から `Configuration.spotlightEnabled` を削除する
  - <https://github.com/shiguredo/sora-ios-sdk/commit/44f3b81fd81694f3f670e3de568afc2a6bab5f9f> の修正漏れ
  - @zztkm
- [FIX] URL 構造体が TURN URI に対応していないのに、URL に変換していたのを修正する
  - 意図しないエスケープが発生しないようにした
  - @zztkm

### misc

- [UPDATE] GitHub Actions の定期実行をやめる
  - build.yml の起動イベントから schedule を削除
  - @zztkm
- [UPDATE] GitHub Actions の Xcode のバージョンを 15.4 にあげる
  - 合わせて iOS の SDK を iphoneos17.5 にあげる
  - @miosakuma
- [UPDATE] CocoaPods のソースリポジトリを GitHub から CDN に変更する
  - CocoaPods 1.8 からソースリポジトリのデフォルトが `https://cdn.cocoapods.org/` になった
  - <https://blog.cocoapods.org/CocoaPods-1.8.0-beta/>
  - @zztkm
- [UPDATE] システム条件を変更する
  - macOS 14.6.1 以降
  - Xcode 15.4
  - WebRTC SFU Sora 2024.1.0 以降
  - @miosakuma

## 2024.2.0

- [CHANGE] シグナリング `connect` メッセージの `libwebrtc` に含まれるバージョン文字列を Android と揃える
  - branch-heads を追加する
  - () 内の libwebrtc バージョンについて最初の 1 文字を削る
  - 送信される文字列は `Shiguredo-build M122 (M122.1.0 6b419a0)` から、`Shiguredo-build M122 (122.6261.1.0 6b419a0)` に変更される
- [UPDATE] WebRTC m122.6261.1.0 に上げる
  - @miosakuma
- [UPDATE] システム条件を変更する
  - macOS 14.4.1 以降
  - Xcode 15.3
  - Swift 5.10
  - @miosakuma

## 2024.1.0

- [CHANGE] SignalingNotify の metadataList を削除する
  - 2022.1.0 の Sora で metadata_list が廃止されたため
  - SignalingNotify の data で値の取得が可能
  - @miosakuma
- [CHANGE] VideoView のバックエンドを RTCEAGLVideoView から RTCMTLVideoView に変更する
  - WebRTC のアップデートに伴い RTCEAGLVideoView が deprecated になったことに伴う修正
  - @miosakuma
- [UPDATE] システム条件を変更する
  - macOS 14.3.1 以降
  - WebRTC SFU Sora 2023.2.0 以降
  - Xcode 15.2
  - Swift 5.9.2
  - CocoaPods 1.15.2 以降
  - @miosakuma
- [UPDATE] CameraVideoCapturer のログを出力する
  - @enm10k
- [UPDATE] WebRTC 121.6167.4.0 に上げる
  - @miosakuma
- [UPDATE] 解像度に qHD (960x540) を追加する
  - @enm10k
- [UPDATE] CocoaPods を v1.15.2 に更新する
  - @enm10k @miosakuma
- [UPDATE] ForwardingFilter に version と metadata　を追加する
  - @enm10k @miosakuma
- [ADD] VideoCodec に H265 を追加する
  - @enm10k
- [ADD] WebRTCConfiguration に degradationPreference を追加する
  - @enm10k
- [FIX] ForwardingFilter の action を未指定にできるようにする
  - @miosakuma
- [FIX] SignalingNotify に項目を追加する
  - sessionId
  - kind
  - destinationConnectionId
  - sourceConnectionId
  - recvConnectionId
  - sendConnectionId
  - streamId
  - @miosakuma

## 2023.3.1

- [FIX] AVCaptureDevice.Format の選択時にフレームレートを考慮するように修正する
  - フレームレートに 60 を設定しても、 AVFrameRateRange が 1-30 の AVCaptureDevice.Format が選択されてしまうケースがあった
  - 修正前は、カメラから同じ解像度の AVCaptureDevice.Format が複数取得された場合、最初に解像度が一致した AVCaptureDevice.Format を選択しており、フレームレートが考慮されていないという問題があった
  - @enm10k

## 2023.3.0

- [CHANGE] `@available(*, unavailable)` は廃止になるため削除する
  - Swift 5.9 以降 `@available(*, unavailable)` が禁止された
  - Sora iOS SDK では廃止となったプロパティに対して `@available(*, unavailable)` を付与していたが、削除した
  - @torikizi
- [CHANGE] `@available(*, deprecated, ... )` としていた非推奨項目を削除する
  - 非推奨であった項目について削除に移行する
  - 移行方法については <https://sora-ios-sdk.shiguredo.jp/> の移行ドキュメントに記載されている
  - @torikizi
- [CHANGE] 廃止された `onConnectHandler` を `onConnect` に置き換える
  - すでに廃止済みの `onConnectHandler` が残っていたので、`onConnect` に置き換えた
  - `PeerChannel.swift` と `SignalingChannel.swift` 以外はすでに `onConnect` に置き換えていた
  - @torikizi
- [UPDATE] WebRTC 116.5845.6.1 に上げる
  - @miosakuma
- [FIX] `MediaChannel` の `connectionCount`, `publisherCount`, `subscriberCount` に値が設定されない不具合を修正する
  - Sora のシグナリングメッセージから channel_upstream_connections, channel_downstream_connections が廃止された契機で値が設定されなくなっていた
  - Sora のシグナリングメッセージ、channel_sendrecv_connections, channel_sendonly_connections, channel_recvonly_connections, channel_connections を元に値を設定するよう修正
  - @miosakuma

## 2023.2.0

- [UPDATE] システム条件を変更する
  - macOS 13.4.1 以降
  - WebRTC SFU Sora 2023.1.0 以降
  - Xcode 14.3.1
  - Swift 5.8.1
  - CocoaPods 1.12.1 以降
  - @miosakuma
- [UPDATE] WebRTC 115.5790.7.0 に上げる
  - @szktty @miosakuma
- [ADD] 転送フィルター機能を追加する
  - `Configuration` に `forwardingFilter` を追加する
  - @szktty
- [ADD] 映像コーデックパラメーターの設定を追加する
  - `Configuration` に `videoVp9Params`, `videoAv1Params`, `videoH264Params` を追加する
  - @miosakuma
- [ADD] サイマルキャストを VP9 / AV1 に対応する
  - @szktty

## 2023.1.0

- [UPDATE] WebRTC 112.5615.1.0 に上げる
  - @miosakuma
- [UPDATE] システム条件を変更する
  - macOS 13.3 以降
  - Xcode 14.3
  - Swift 5.8
  - WebRTC SFU Sora 2022.2.0 以降
  - @miosakuma
- [UPDATE] `CameraSettings` の `Resolution` に `uhd2160p`, `uhd3024p` を追加する
  - @miosakuma
- [ADD] `Configuration` に `audioStreamingLanguageCode` を追加する
  - @miosakuma
- [FIX] m107.5304.4.1 の利用時、シグナリング時に EXEC_BAD_ACCESS が発生する事象を修正する
  - `RTCPeerConnection.offer()` に渡すブロック内で `RTCPeerConnection.close()` を呼んでいるのが原因だと思われるため、 async/await を使って offer() の終了を待ってから close() する
  - `RTCPeerConnection.offer()` の実行が非同期で行われるようになるが、 `NativePeerChannelFactory.createClientOfferSDP()` の用途では問題ない
  - @szktty

## 2022.6.0

- [CHANGE] bitcode を無効にする
  - WebRTC 105.5195.0.0 より bitcode が廃止になりました。bitcode を無効にしてビルドをする必要があります
  - @miosakuma
- [CHANGE] 対応アーキテクチャから x86_64 を無効にする
  - @miosakuma
- [UPDATE] WebRTC 105.5195.0.0 に上げる
  - @miosakuma
- [UPDATE] システム条件を変更する
  - macOS 12.6 以降
  - Xcode 14.0
  - Swift 5.7
  - CocoaPods 1.11.3 以降
  - @miosakuma

## 2022.5.0

- [UPDATE] WebRTC 104.5112.8.0 に上げる
  - @miosakuma
- [ADD] HTTP プロキシに対応する
  - @enm10k

## 2022.4.0

- [CHANGE] mid を必須にする
  - この修正の結果、 type: offer に mid が含まれない場合は、エラーになります
  - @enm10k
- [CHANGE] `Configuration.spotlightEnabled == .enabled` の際に、自動的にサイマルキャストを有効化しない
  - サイマルキャストを有効化する場合は明示的に `Configuration.simulcastEnabled == true` を設定してください
  - @enm10k
- [UPDATE] システム条件を変更する
  - macOS 12.3 以降
  - WebRTC SFU Sora 2022.1.0 以降
  - @miosakuma
- [UPDATE] WebRTC 103.5060.4.0 に上げる
  - @miosakuma
- [ADD] Sora の bundle_id に対応する
  - `Configuration.bundleId` を追加する
  - @enm10k

## 2022.3.0

- [UPDATE] システム条件を変更する
  - Xcode 13.4
  - Swift 5.6.1
  - @miosakuma
- [UPDATE] WebRTC 102.5005.7.6 に上げる
  - @miosakuma
- [UPDATE] mid に対応する

## 2022.2.1

- [UPDATE] App Store Connect に bitcode を有効にしてバイナリをアップロードするとエラーになる問題の暫定回避策として、 WebRTC 97.4692.4.0 に下げる
  - @miosakuma

## 2022.2.0

- [CHANGE] DataChannel 経由で受信したメッセージのうち label が signaling, push, notify のものは `MediaChannelHandlers.onReceiveSignaling` が呼ばれるように修正する
  - @enm10k
- [CHANGE] `MediaChannel.connectedUrl`を更新するタイミングを修正する
  - type: connect を送信するタイミングで `MediaChannel.connectedUrl` を更新していたが、 type: offer を受信したタイミングで値を更新するように修正
  - @enm10k
- [UPDATE] WebRTC 99.4844.1.0 に上げる
  - @miosakuma
- [ADD] メッセージング機能に対応する
  - @enm10k
- [ADD] `MediaChannel.contactUrl` を追加する
  - `MediaChannel.contactUrl` は、最初に type: connect メッセージを送信した Sora のシグナリング URL
  - @enm10k

## 2022.1.1

- [FIX] Sora との接続確立後に WebSocket のエラーが発生した場合、 エラーが正しく伝搬されず、終了処理が実行されないため修正する
  - 接続確立後に WebSocket のエラーが発生した場合、 Sora との接続を切断して終了処理を行うのが正しい処理です
  - 詳細な仕様は <https://sora-doc.shiguredo.jp/SORA_CLIENT> に記載されています
  - @enm10k

## 2022.1.0

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
- [CHANGE] サポートする iOS のバージョンを 13 以上に変更する
  - @enm10k
- [CHANGE] `MediaChannel.native` の型を `RTCPeerConnection` から `RTCPeerConnection?` に変更する
  - PeerChannel で force unwrapping している箇所を修正する際に、併せて修正した
  - @enm10k
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

- [CHANGE] PeerChannel, SignalingChannel protocol を削除する
  - `Configuration.peerChannelType` を廃止
  - `Configuration.signalingChannelType` を廃止
  - `Configuration.peerChannelHandlers` を廃止
  - `Configuration.signalingChannelHandlers` を廃止
  - `MediaChannel.native` を追加
  - `MediaChannel.webSocketChannel` を追加
  - @szktty @enm10k
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
- [FIX] Sora 接続時に audioEnabled = false を設定すると answer 生成に失敗してしまう問題についてのワークアラウンドを削除する
  - @miosakuma

## 2021.2.1

- [FIX] Swift Package Manager に対応するためバージョニングを修正
  - @miosakuma

## 2021.2

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
- [FIX] 接続、切断の検知に RTCPeerConnectionState を参照する
  - @enm10k
- [FIX] 接続終了後に MediaChannel のメモリが解放されずに残り続ける事象を修正する
  - @szktty

## 2021.1

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

- [CHANGE] `AudioMode.swift` がターゲット含まれておらずビルドできなかった事象を修正する
  - @szktty
- [UPDATE] WebRTC 86.4240.10.0 に上げる
  - @szktty

## 2020.6

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
- [UPDATE] システム条件を更新する
  - Xcode 12.0
  - Swift 5.3
  - CocoaPods 1.9.3
  - @szktty
- [UPDATE] WebRTC M86 に対応する
  - @szktty
- [FIX] API: `Sora.connect()`: タイムアウト時にハンドラが実行されない事象を修正する
  - @szktty

## 2020.5

- [CHANGE] シグナリング pong に統計情報を含める
  - @szktty
- [CHANGE] API: 次のイベントハンドラのクラスにコンストラクタを追加する
  - `MediaChannelHandlers`
  - `MediaStreamHandlers`
  - `PeerChannelHandlers`
  - `SignalingChannelHandlers`
  - `SoraHandlers`
  - `VideoCapturerHandlers`
  - `WebSocketChannelHandlers`
  - @itoyama @szktty
- [UPDATE] システム条件を更新する
  - Xcode 11.6
  - Swift 5.2.4
  - WebRTC SFU Sora 2020.1 以降
  - @szktty
- [UPDATE] WebRTC M84 に対応する
  - @szktty
- [FIX] API: `Sora.connect()`: 接続先ホストが存在しない場合にハンドラが実行されない事象を修正する
  - @szktty

## 2020.4.1

- [FIX] 受信したシグナリングの role が `sendonly`, `recvonly`, `sendrecv` の場合にデコードに失敗する事象を修正する
  - @szktty
- [FIX] API: `MediaChannel`: `senderStream`: ストリーム ID が接続時に指定した配信用ストリーム ID と一致するストリームを返すようにする (変更前はカメラのストリームを返した)
  - @szktty
- [FIX] API: `MediaChannel`: `receiverStreams`: `senderStream` 以外のストリームを返すようにする (変更前はカメラ以外のストリームを返した)
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
- [CHANGE] API: `MediaChannel`: `senderStream` プロパティを追加する
  - @szktty
- [CHANGE] API: `MediaChannel`: `receiverStreams` プロパティを追加する
  - @szktty

## 2020.3

- [FIX] マイクが初期化されない事象を修正する
  - @szktty

## 2020.2

- [CHANGE] 受信時にマイクのパーミッションを要求しないようにする
  - @szktty
- [FIX] `Sora.remove(mediaChannel:)` 実行時に `onRemoveMediaChannel` が呼ばれない事象を修正する
  - @tamiyoshi-naka @szktty

## 2020.1

本バージョンよりバージョン表記を「リリース年.リリース回数」に変更する

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
- [UPDATE] システム条件を更新する
  - Xcode 11.3
  - CocoaPods 1.8.4 以降
  - WebRTC SFU Sora 19.10.3 以降
  - @szktty
- [UPDATE] WebRTC M79 に対応する
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

- [CHANGE] 依存するライブラリを変更する (`Cartfile`)
  - sora-webrtc-ios 76.3.1 -> shiguredo-webrtc-ios 76.3.1
  - @szktty
- [CHANGE] 対応アーキテクチャから armv7 を外する
  - @szktty
- [ADD] 対応アーキテクチャに x86_64 を追加する (シミュレーターの動作は未保証)
  - @szktty
- [ADD] シグナリングに SDK と端末の情報を含めるようにする
  - @szktty

## 2.4.0

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

## 2.3.2

- [CHANGE] API: `SDPSemantics`: `case default` を削除する
  - @szktty
- [CHANGE] SDP セマンティクスのデフォルトを Unified Plan に変更する
  - @szktty
- [ADD] API: シグナリング "notify" の "connection_id" プロパティに対応する
  - @szktty
- [ADD] API: `SignalingNotifyMessage`: `connectionId` プロパティを追加する
  - @szktty
- [FIX] 接続状態によってシグナリング "notify" が無視される現象を修正する
  - @szktty

## 2.3.1

- [FIX] グループ (マルチストリーム) 時、映像を無効にする状態で接続すると落ちる現象を修正する
  - @szktty

## 2.3.0

- [CHANGE] マルチストリーム時に強制的に Plan B に設定していたのを止めた
  - @szktty
- [CHANGE] 未知のシグナリングメッセージを受信するら例外を発生するように変更する
  - @szktty
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
- [UPDATE] API: `Sora`: `connect(configuration:webRTCConfiguration:handler:)`: 実行中に接続の試行をキャンセル可能にする
  - @szktty
- [ADD] API: `ConnectionTask`: 追加する
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

- [CHANGE] API: `MediaStream`: `audioVolume` プロパティを非推奨にする
  - @szktty
- [UPDATE] システム条件を更新する
  - macOS 10.13.2 以降
  - Xcode 9.3
  - Swift 4.1
  - Carthage 0.29.0 以降、または CocoaPods 1.4.0 以降
  - WebRTC SFU Sora 18.02 以降
  - @szktty
- [ADD] API: `MediaStream`: `remoteAudioVolume` プロパティを追加する
  - @szktty
- [FIX] API: `MediaStream`: 配信中に `videoEnabled` プロパティまたは `audioEnabled` プロパティで映像か音声を無効にすると、有効に戻しても他のクライアントに配信が再開されない現象を修正する
  - @szktty
- [FIX] API: `WebRTCInfo`: `shortRevision`: 戻り値の文字列が 7 桁でない現象を修正する
  - @szktty

## 2.1.0

- [ADD] 視聴のみのマルチストリームに対応する
  - @szktty
- [ADD] 音声検出による映像の動的切替に対応する
  - @szktty
- [ADD] API: `Role`: `.groupSub` を追加する
  - @szktty
- [ADD] API: `Configuration`: `maxNumberOfSpeakers` プロパティを追加する
  - @szktty
- [ADD] API: `SignalingConnectMessage`: `maxNumberOfSpeakers` プロパティを追加する
  - @szktty

## 2.0.4

- [UPDATE] WebRTC M64 に対応する
  - @szktty

## 2.0.3

- [CHANGE] API: `SoraError`: WebSocket に関するエラーを次の二つに分割する
  - `webSocketClosed(statusCode:reason:)`
  - `webSocketError()`
  - @szktty
- [CHANGE] API: `WebSocketChannelHandlers`: `onFailureHandler` を削除する
  - @szktty
- [CHANGE] API: `SignalingChannelHandlers`: `onFailureHandler` を削除する
  - @szktty
- [CHANGE] API: `PeerChannelHandlers`: `onFailureHandler` を削除する
  - @szktty
- [CHANGE] API: `MediaChannelHandlers`: `onFailureHandler` を削除する
  - @szktty
- [UPDATE] WebRTC M63 に対応する
  - @szktty
- [UPDATE] SDWebImage 4.2.2 に対応する
  - @szktty
- [ADD] API: `WebSocketChannelHandlers`: `onDisconnectHandler` を追加する
  - @szktty
- [ADD] API: `SignalingChannelHandlers`: `onDisconnectHandler` を追加する
  - @szktty
- [ADD] API: `PeerChannelHandlers`: `onDisconnectHandler` を追加する
  - @szktty
- [FIX] API: `MediaChannel`: `PeerChannel` の接続解除時に `MediaChannel` の状態が接続解除にならない現象を修正する
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

- [CHANGE] 依存するフレームワークから Unbox.framework を削除する
  - @szktty
- [CHANGE] WebRTC のネイティブ API (主にクラスやプロトコル名の接頭辞が `RTC` の API) を非公開にする
  - @szktty
- [CHANGE] 通信を行うオブジェクト (WebSocket 接続、シグナリング接続、ピア接続、メディアストリーム) をプロトコルに変更する (デフォルトの実装は `private`)
  - @szktty
- [CHANGE] 内部で使用する WebSocket の API (SRWebSocket.framework の API) を非公開にする
  - @szktty
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
- [UPDATE] クライアントの設定を `Configuration` にまとめる
  - @szktty
- [ADD] ロールについて、 "パブリッシャー (Publisher)" と "サブスクライバー (Subscriber)" に加えて、マルチストリームで通信を行う "グループ (Group)" を追加する
  - @szktty
- [ADD] 任意の映像キャプチャーの使用を可能にする
  - @szktty
- [ADD] `CMSampleBuffer` を映像フレームとして使用可能にする
  - @szktty
- [ADD] 映像フレームの編集を可能にする
  - @szktty

### API

- [CHANGE] 次のクラス、構造体、列挙体、プロトコルを削除する
  - `Attendee`: 同等の機能を `MediaChannel` に実装する
  - `BuildInfo`: 同等の機能を `WebRTCInfo` に実装する
  - `Connection`: パブリッシャーとサブスクライバーをそれぞれ独立させたため削除する
  - `ConnectionController`: 同等の機能を削除する
  - `ConnectionController.Request`
  - `ConnectionController.Role`
  - `ConnectionController.StreamType`
  - `ConnectionError`: 同等の機能を `SoraError` に実装する
  - `Event`: 各イベントをイベントハンドラのみで扱うようにする
  - `Event.EventType`
  - `EventLog`: ロギング機能を削除する
  - `MediaConnection`: 同等の機能を `MediaChannel` に実装する
  - `MediaPublisher`: パブリッシャーを `MediaChannel` で扱うようにするため削除する
  - `MediaSubscriber`: サブスクライバーを `MediaChannel` で扱うようにするため削除する
  - `MediaOption`: 同等の機能を `Configuration` に実装する
  - `Message`: 同等の機能を `SignalingMessage` に実装する
  - `Message.MessageType`
  - `Messagable`
  - `PeerConnection`: 同等の機能を `PeerChannel` に定義する
  - `PeerConnectionEventHandlers`: 同等の機能を `PeerChannelHandlers` に実装する
  - `SignalingEventHandlers`: 同等の機能を `SignalingChannelHandlers` に実装する
  - `SignalingNotify`: 同等の機能を `SignalingNotifyMessage` に実装する
  - `SignalingSnapshot`: 同等の機能を `SignalingSnapshotMessage` に実装する
  - `VideoFrameHandle`: 同等の機能を `VideoFrame` に実装する
  - `WebSocketEventHandlers`: 同等の機能を `WebSocketChannelHandlers` に実装する
  - @szktty
- [CHANGE] `Notification` の使用を中止し、次の関連する構造体と列挙体を削除する
  - `Connection.NotificationKey`
  - `Connection.NotificationKey.UserInfo`
  - `MediaConnection.NotificationKey`
  - `MediaConnection.NotificationKey.UserInfo`
  - `MediaStream.NotificationKey`
  - `MediaStream.NotificationKey.UserInfo`
  - @szktty
- [CHANGE] `AudioCodec`
  - `.Opus` を `.opus` に変更する
  - `.PCMU` を `.pcmu` に変更する
  - @szktty
- [CHANGE] `MediaStream`
  - クラスからプロトコルに変更し、 API を一新する
- [CHANGE] `VideoCodec`
  - `.VP8` を `.vp8` に変更する
  - `.VP9` を `.vp9` に変更する
  - `.H264` を `.h264` に変更する
  - @szktty
- [CHANGE] `VideoFrame`
  - プロトコルから列挙体に変更し、 API を一新する
  - @szktty
- [CHANGE]] `VideoRenderer`
  - `onChangedSize(_:)` を `onChange(size:)` に変更する
  - `renderVideoFrame(_:)` を `render(videoFrame:)` に変更する
  - @szktty
- [ADD] 次のクラスを追加する
  - `CameraVideoCapturer`
  - `CameraVideoCapturer.Settings`
  - `ICECandidate`
  - `ICEServerInfo`
  - `MediaChannel`
  - `MediaChannelHandlers`
  - `PeerChannelHandlers`
  - `SignalingChannelHandlers`
  - `Sora`
  - `SoraHandlers`
  - `VideoCapturerHandlers`
  - `WebSocketChannelHandlers`
  - @szktty
- [ADD] 次の構造体を追加する
  - `Configuration`
  - `MediaConstraints`
  - `SignalingConnectMessage`
  - `SignalingNotifyMessage`
  - `SignalingOfferMessage`
  - `SignalingOfferMessage.Configuration`
  - `SignalingPongMessage`
  - `SignalingSnapshotMessage`
  - `SignalingUpdateOfferMessage`
  - `Snapshot`
  - `WebRTCConfiguration`
  - `WebRTCInfo`
  - @szktty
- [ADD] 次の列挙体を追加する
  - `ConnectionState`
  - `ICETransportPolicy`
  - `LogLevel`
  - `NotificationEvent`
  - `SignalingNotificationEventType`
  - `SignalingMessage`
  - `SignalingRole`
  - `SoraError`
  - `TLSSecurityPolicy`
  - `VideoCapturerDecive`
  - `VideoFrame`
  - `WebSocketMessage`
  - `WebSocketMessageStatusCode`
  - @szktty
- [ADD] 次のプロトコルを追加する
  - `MediaStream`
  - `PeerChannel`
  - `SignalingChannel`
  - `VideoCapturer`
  - `ViderFilter`
  - `WebSocketChannel`
  - @szktty
- [ADD] `Role`
  - `.group` を追加する
  - @szktty

## 1.2.5

- [FIX] CircleCI でのビルドエラーを修正する
  - @szktty

## 1.2.4

- [CHANGE] API: MediaOption を struct に変更する
  - @szktty
- [CHANGE] API: ConnectionController: ロールとストリーム種別の選択制限を削除する
  - @szktty
- [UPDATE] armv7 に対応する
  - @szktty
- [FIX] API: マルチストリーム時、配信者のストリームが二重に生成されてしまう現象を修正する
  - @szktty

## 1.2.3

- [UPDATE] API: VideoView: `contentMode` に応じて映像のサイズを変更するようにする
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

- [CHANGE] API: VideoFrame
  - `var width`: `Int32` -> `Int`
  - `var height`: `Int32` -> `Int`
  - `var timestamp`: `CMTime` -> `CMTime?`
  - @szktty
- [CHANGE] API: VideoFrameHandle: 次のプロパティ名を変更する
  - `case webRTC` -> `case WebRTC`
  - @szktty
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
  - `case Snapshot`
  - @szktty
- [ADD] API: MediaOption: 次のプロパティを追加する
  - `var snapshotEnabled`
  - @szktty
- [ADD] API: SignalingEventHandlers: 次のメソッドを追加する
  - `func onSnapshot(handler: (SignalingSnapshot) -> Void)`
  - @szktty
- [ADD] API: SignalingSnapshot: 追加する
  - @szktty
- [ADD] API: Snapshot: 追加する
  - @szktty
- [ADD] API: VideoFrameHandle: 次のプロパティを追加する
  - `case snapshot`
  - @szktty
- [ADD] API: ConnectionController: スナップショットの項目を追加する
  - @szktty

## 1.1.0

- [CHANGE] examples を削除
  - @szktty
- [CHANGE] ディレクトリ構造を変更し、プロジェクトのファイルをトップレベルに移動する
  - @szktty
- [CHANGE] API: PeerConnection: 接続状態に関わらず WebSocket のイベントハンドラを実行するようにする
  - @szktty
- [CHANGE] 次の不要なファイルを削除する
  - `JSON.swift`
  - @szktty
- [CHANGE] API: BuildInfo: 次のプロパティを削除する
  - `var VP9Enabled`
  - @szktty
- [CHANGE] API: Connection: 次のプロパティとメソッドを削除する
  - `var numberOfConnections`
  - `func onChangeNumberOfConnections(handler:)`
  - @szktty
- [CHANGE] API: ConnectionController: Cancel ボタンを Back ボタンに変更する
  - @szktty
- [CHANGE] API: MediaStreamRole: 削除する
  - @szktty
- [CHANGE] API: VideoFrame の型を変更する
  - `var width`: `Int` -> `Int32`
  - `var height`: `Int` -> `Int32`
  - @szktty
- [CHANGE] API: ConnectionController: VP9 の有効・無効を示すセルを削除する
  - @szktty
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
- [ADD] API: ConnectionError: `var description` を追加する
  - @szktty
- [ADD] API: ConnectionController: ビットレートの設定項目を追加する
  - @szktty
- [ADD] API: ConnectionController: イベントログの画面を追加する
  - @szktty
- [ADD] API: Event.EventType: `ConnectionMonitor` を追加する
  - @szktty
- [ADD] API: MediaConnection: 次のプロパティとメソッドを追加する
  - `var numberOfConnections`
  - `func onAttendeeAdded(handler:)`
  - `func onAttendeeRemoved(handler:)`
  - `func onChangeNumberOfConnections(handler:)`
  - @szktty
- [ADD] API: Role: 追加する
  - @szktty
- [ADD] API: SignalingEventHandlers: `func onNotify(handler:)` を追加する
  - @szktty
- [ADD] API: SignalingEventType: 追加する
  - @szktty
- [ADD] API: SignalingNotify: 追加する
  - @szktty
- [ADD] API: SignalingRole: 追加する
  - @szktty
- [FIX] Sora の URL のプロトコルが ws または wss 以外であればエラーにする
  - @szktty
- [FIX] 接続解除可能な状況でも `connectionBusy` のエラーが発生する現象を修正する
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
  - `webSocketEventHandlers`: `WebSocketEventHandlers?` --> `WebSocketEventHandlers`
  - `signalingEventHandlers`: `SignalingEventHandlers?` --> `SignalingEventHandlers`
  - `peerConnectionEventHandlers`: `PeerConnectionEventHandlers?` --> `PeerConnectionEventHandlers`
  - @szktty
- [CHANGE] API: MediaConnection: `connect(accessToken:timeout:handler:)` メソッドの型を `connect(metadata:timeout:handler:)` に変更する
  - @szktty
- [CHANGE] API: MediaConnection, MediaStream: 次の API を MediaStream に移行する
  - `var videoRenderer`
  - `func startConnectionTimer(timeInterval:handler:)`
  - @szktty
- [CHANGE] API: MediaConnection.State: 削除する
  - @szktty
- [CHANGE] API: MediaOption.AudioCodec: `unspecified` を `default` に変更する
  - @szktty
- [CHANGE] API: MediaOption.VideoCodec: `unspecified` を `default` に変更する
  - @szktty
- [CHANGE] API: MediaStream: RTCPeerConnection のラッパーではなく、 RTCMediaStream のラッパーに変更する
  - @szktty
- [CHANGE] API: MediaStream: `startConnectionTimer(timeInterval:handler:)`: タイマーを起動する瞬間もハンドラーを実行するようにする
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
- [ADD] API: MediaConnection: `multistreamEnabled` プロパティを追加する
  - @szktty
- [ADD] API: MediaPublisher: `autofocusEnabled` プロパティを追加する
  - @szktty
- [ADD] API: PeerConnection: RTCPeerConnection のラッパーとして追加する
  - @szktty
- [ADD] API: BuildInfo: 追加する
  - @szktty
- [ADD] API: ConnectionController: 追加する
  - @szktty
- [ADD] API: Connection: 次の API を追加する
  - `var numberOfConnections`
  - `func onChangeNumberOfConnections(handler:)`
  - @szktty
- [ADD] API: Connection, MediaConnection, MediaStream, PeerConnection: 次のイベントで (NotificationCenter による) 通知を行うようにする
  - onConnect
  - onDisconnect
  - onFailure
  - @szktty
- [ADD] API: WebSocketEventHandlers, SignalingEventHandlers, PeerConnectionEventHandlers: イニシャライザーを追加する
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
