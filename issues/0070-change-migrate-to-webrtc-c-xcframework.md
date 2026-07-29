# WebRTC.xcframework から libwebrtc_c.xcframework (webrtc_c) への完全移行

- Priority: High
- Created: 2026-06-15
- Completed:
- Model: Opus 4.7
- Branch: feature/change-migrate-to-webrtc-c-xcframework
- Polished: 2026-06-15

## 本 issue の性質と進行方針

本移行は工事規模が極端に大きく（影響範囲 25 ファイル、`Sora/` 配下計 10,532 行）、1 issue = 1 branch = 1 PR の規約では収まらない。そのため本 issue は **移行全体の方針を保持する親 issue** として扱う。本 issue の `Branch:` で実施するのは **Phase 0（PoC）のみ**。Phase 1〜5 は Phase 0 完了後に個別 issue として新規起票し、それぞれを独立した 1 issue = 1 branch = 1 PR の単位で `shiguredo-issues` / `shiguredo-git` 規約に従って進める。

本 issue の close 条件は Phase 0 完了基準を満たし、PoC 結果から Phase 1〜5 の起票が可能と判断できる状態（または「移行は得策ではない」という結論）に到達すること。Phase 1〜5 の進捗は本 issue ではなく個別 issue で管理する。

「親 issue」は時雨堂 issue 規約には明示されていない概念だが、本 issue の規模に応じた特例として本セクションで明文化する。次節「進行ステータス」も合わせて参照。

### 進行ステータス

本 issue は `issues/` 直下（Active）で扱うが、設計判断と外部リポジトリ合意が多数残るため `/auto-resolve` の対象外とする。Phase 0 着手はユーザー指示で `Branch:` のブランチを手動で切って進める。Phase 0 完了時に本 issue を `issues/closed/` に移し、Phase 1〜5 は新規起票された個別 issue で別途追跡する。

着手前に以下を確認する。確認できない場合は `issues/pending/` に移動し、合意成立後に再 active 化する。

- `shiguredo/webrtc-rs` メンテナと「webrtc_c に追加が必要な API」リストの初期合意
- iOS deployment target（`.v14` 維持 / `.v16` 引き上げ）の方針案
- `@_implementationOnly` の Swift 6 動作仮検証

`Branch:` の運用: Phase 0 完了時の Go 判定なら `Package.swift` 差し替えと 1 ファイル書き換えを `develop` にマージする（`feature/change-` 整合）。No-Go 判定なら本ブランチを破棄して `Sora/` への変更は入れない（`feature/debug-` 相当の運用）。

## 目的

sora-ios-sdk が依存している libwebrtc iOS SDK（`WebRTC.xcframework` / `import WebRTC` / `RTC*` プレフィックス）は Google 側で実質メンテナンスされておらず、Google 自身も内部プロダクトで使っていない。結果として以下の問題が継続的に発生する。

- libwebrtc 本体に追加された API が ObjC SDK のラッパーに露出されない（例: `0069-add-priority-to-rtp-encoding` の `RTCRtpEncodingParameters.priority` 系の対応で発生する追従コスト）
- iOS SDK 内部のバグ（VideoToolbox / AudioSession / Metal renderer まわり）が Google 側で修正されない
- 新しい iOS バージョン対応も時雨堂が肩代わりせざるを得ない

時雨堂のスタックでは libwebrtc を `webrtc-build` で自前ビルドし、薄い C ラッパー `webrtc_c` を `shiguredo/webrtc-rs` で開発して `libwebrtc_c.xcframework` として配布している。sora-cpp-sdk と sora-flutter-sdk は既にこの C ラッパー経由で libwebrtc を利用しており、Flutter SDK は iOS で本番投入実績がある。

sora-ios-sdk だけが Google ObjC SDK にぶら下がっている現状は、時雨堂スタックの中で最もメンテ停滞しているコンポーネントへの構造的依存になっている。本 issue ではこの依存を完全に解消し、`libwebrtc_c.xcframework` 経由で libwebrtc を直接利用する形に移行する。これにより sora-cpp-sdk / sora-flutter-sdk / sora-ios-sdk が同じ C API 基盤を共有する状態になる。

## 優先度根拠

- 戦略的重要性: 時雨堂 SDK スタック全体で webrtc_c を共通基盤にする方針の最後のピース。iOS だけ取り残されると、新機能・新 API 追従の二重作業が継続する。
- リスク回避: ObjC SDK のメンテ停滞は現在進行形の問題であり、放置するほど libwebrtc 本体との API 差が広がり追従コストが増大する。
- 時間的コスト構造: 移行は静的な工事費用だが、放置コストは時間とともに膨らむ。早く着手するほど総コストが小さい。
- 実証: sora-flutter-sdk が同一スタックで iOS 本番投入されており、技術的な実現可能性は確認済み。

## 現状

### 依存定義

`Package.swift` で `m148.7778.7.0` 版の `WebRTC.xcframework` を `binaryTarget` として取り込んでいる。

```swift
// Package.swift:6, 21-25
let libwebrtcVersion = "m148.7778.7.0"
.binaryTarget(
    name: "WebRTC",
    url: "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/\(libwebrtcVersion)/WebRTC.xcframework.zip",
    checksum: "df0f99daa66231adce88b4ae0e8b4672ab053842cc43ebe8120968e1337084f6"
)
```

### `import WebRTC` の分布

`Sora/` 配下（`Sora/*.swift` および `Sora/Extensions/*.swift` を含む）で `import WebRTC` しているファイルは 25 個。`Sora/` 全体は計 10,532 行（`Sora/*.swift` 計 10,452 行 + `Sora/Extensions/*.swift` 計 80 行）。`import WebRTC` を含むファイルを行数順に列挙する:

| ファイル | 行数 | 主に使う `RTC*` 型 |
|---|---|---|
| `PeerChannel.swift` | 1,558 | `RTCPeerConnection`, `RTCPeerConnectionDelegate`, `RTCConfiguration`, `RTCDataChannel`, `RTCIceCandidate`, `RTCIceConnectionState`, `RTCIceGatheringState`, `RTCMediaConstraints`, `RTCMediaStream`, `RTCPeerConnectionState`, `RTCSignalingState`, `RTCDegradationPreference`, `RTCVersion` |
| `Signaling.swift` | 1,443 | `RTCRtpEncodingParameters`, `RTCResolutionRestriction`, libwebrtc バージョン文字列処理（SDP 入出力） |
| `MediaChannel.swift` | 941 | `RTCStatisticsReport` |
| `CameraVideoCapturer.swift` | 514 | `RTCCameraVideoCapturer`, `RTCVideoCapturerDelegate` |
| `Sora.swift` | 490 | `RTCAudioSession`, `RTCAudioSessionDelegate`, `RTCCallbackLogger`, `RTCConfiguration`, `RTCLoggingSeverity` |
| `VideoView.swift` | 443 | `RTCMTLVideoView`, `RTCVideoRenderer` |
| `Configuration.swift` | 411 | `import` のみ（コーデック設定は `VideoCodec` / `AudioCodec` 経由） |
| `MediaStream.swift` | 284 | `RTCMediaStream`, `RTCVideoTrack`, `RTCAudioTrack`, `AudioSource.volume` |
| `DataChannel.swift` | 277 | `RTCDataChannel`, `RTCDataChannelDelegate` |
| `NativePeerChannelFactory.swift` | 214 | `RTCPeerConnectionFactory`, `RTCDefaultVideoEncoderFactory`, `RTCDefaultVideoDecoderFactory`, `RTCVideoEncoderFactorySimulcast`, `RTCAudioDeviceModule` |
| `WebRTCConfiguration.swift` | 197 | `RTCConfiguration`, `RTCMediaConstraints`, `RTCIceServer`, `RTCIceTransportPolicy`, `RTCSdpSemantics` |
| 他（小規模）| 計 817 | `Utilities.swift`（111 行、`import` のみで RTC 利用無し）, `VideoRenderer.swift`（97 行、`RTCVideoRenderer`）, `ICEServerInfo.swift`（96 行）, `ConnectionState.swift`（74 行）, `VideoFrame.swift`（64 行、`RTCVideoFrame`）, `IOSCertificateVerifier.swift`（61 行、`RTCSSLCertificateVerifier`）, `Extensions/RTC+Description.swift`（60 行、`RTC*` 状態の `CustomStringConvertible`）, `ICETransportPolicy.swift`（59 行）, `Statistics.swift`（55 行、`RTCStatisticsReport`）, `AudioDeviceModuleWrapper.swift`（46 行、`RTCAudioDeviceModule` の `pauseRecording` / `resumeRecording`）, `ICECandidate.swift`（42 行）, `SoraDispatcher.swift`（22 行、`RTCDispatcher`）, `TLSSecurityPolicy.swift`（18 行）, `VideoCapturer.swift`（12 行、`import` のみで RTC 利用無し） |

`Utilities.swift` と `VideoCapturer.swift` は `import WebRTC` だけが残っており実利用がないため、Phase 2 では `import` 文の削除だけで済む。

`ScreenCapture.swift`（389 行）は `import WebRTC` していないが、`MediaStream.send(videoFrame:)` を経由して `RTCVideoSource.capturer(_:didCapture:)` に間接依存しており、Phase 4 で `AdaptedVideoTrackSource` へ書き換える対象に含まれる。

`MediaChannelConfiguration.swift`（19 行）は `import WebRTC` を含まず、`@available(*, unavailable)` でクラスごと廃止予定。内部に `// TODO: RTCConfiguration` コメントだけ残るため、本移行の機会に削除する（Phase 2 で除去）。

`SoraTests/SoraTests.swift` でも `import WebRTC` しているが、中身は空テンプレートのため Phase 4 完了時の `WebRTC.xcframework` 削除と同時に `import WebRTC` を取り外す。

`Sora/Sora.h`（11 行）は ObjC umbrella header。`#import <UIKit/UIKit.h>` のみだが、Swift Package Manager の binaryTarget + `CWebrtc` モジュール（C モジュール）併用時に `module.modulemap` の構成変更が必要になる可能性があるため Phase 0 で確認する。

### webrtc_c 側の準備状況

`shiguredo/webrtc-rs` リポジトリの `webrtc/src/webrtc_c.h` が公開する主要 API:

- PeerConnection 系: `api/peer_connection_interface.h`, `api/jsep.h`, `api/set_local_description_observer_interface.h`, `api/set_remote_description_observer_interface.h`
- RTP 系: `api/rtp_parameters.h`, `api/rtp_sender_interface.h`, `api/rtp_receiver_interface.h`, `api/rtp_transceiver_interface.h`, `api/rtp_transceiver_direction.h`, `api/priority.h`
- メディア: `api/media_stream_interface.h`, `api/media_types.h`, `api/video/*`, `api/audio/*`, `api/audio_codecs/*`, `api/video_codecs/*`
- Stats: `api/stats/rtc_stats_collector_callback.h`, `api/stats/rtc_stats_report.h`
- ベース: `api/environment.h`, `api/ref_count.h`, `api/rtc_error.h`, `rtc_base/{thread, logging, ssl_*, crypto_random, time_utils}.h`, `pc/connection_context.h`
- iOS 連携: `sdk/objc/components/audio/audio_session.h`, `sdk/objc/components/video_codec/RTCDefaultVideo{Encoder,Decoder}Factory.h`, `sdk/objc/native/api/video_{encoder,decoder}_factory.h`

`whip.c`（1,603 行）/ `whep.c`（1,359 行）が C のみでの PeerConnection 組み立て例として動作確認済み。これらは sora-ios-sdk の `PeerChannel.swift`（1,558 行）と概ね同規模の C 実装が必要になる規模感の参照になる。`PeerConnectionFactoryDependencies` の組み立て、3 スレッド (network / worker / signaling) 起動、ADM / AudioCodec Factory / VideoCodec Factory 注入、`PeerConnectionObserver` の C コールバック実装、SDP オファー/アンサー生成、ICE 候補処理が C のみで実装されている。

### `libwebrtc_c.xcframework` の配布

`https://github.com/shiguredo/webrtc-rs/releases/download/<version>/libwebrtc_c.xcframework.zip` でリリースされている（例: 0.149.0）。sora-flutter-sdk の `ios/sora_sdk/Package.swift` で `binaryTarget` として実取り込み中。

### 参考となる Flutter SDK の iOS 実装

`shiguredo/sora-flutter-sdk` リポジトリの `ios/sora_sdk/` 配下の構成が本移行の雛形になる:

| ファイル | 行数 | 役割 |
|---|---|---|
| `Sources/CWebrtc/apple_bridge.c` | 1,246 | C ブリッジ。AudioSession 設定 / VideoFrame ヘルパ / `AppleRenderingSink` (`VideoSinkInterface` 実装) / `SoraObserverBridge` (PeerConnectionObserver トランポリン) / `DcBridgeContext` (DataChannelObserver トランポリン) |
| `Sources/CWebrtc/CWebrtc/CWebrtc.h` | ~50 | C モジュールヘッダ |
| `Sources/CWebrtc/CWebrtc/module.modulemap` | 4 | Swift 連携 |
| `Sources/sora_sdk/SoraCameraCapturer.swift` | 727 | `AVCaptureSession` から I420 を作って `AdaptedVideoTrackSource` に push |
| `Sources/sora_sdk/SoraVideoRendererSink.swift` | 141 | `apple_rendering_sink` から `CVPixelBuffer` を受けて `FlutterTexture` 描画（sora-ios-sdk では `MTKView` 描画に置換） |
| `Sources/sora_sdk/SoraMediaAccess.swift` | 285 | カメラ / マイク権限 |

以下は Flutter SDK に雛形が無いため、本移行では新規に書く:

- `RTCMTLVideoView` 相当の Metal レンダリング（`MTKView` への接続、YUV → RGB シェーダ、`contentMode` の `scaleAspectFit/Fill` 再現）
- ReplayKit 連携の `CMSampleBuffer` → I420 変換と `AdaptedVideoTrackSource` 投入
- `AVAudioSession` の `interruptionNotification` / `routeChangeNotification` / `mediaServicesWereResetNotification` の通知購読
- `RTCVideoEncoderFactorySimulcast` 相当のサイマルキャスト Factory
- `RTCSSLCertificateVerifier` 相当の TURN-TLS 証明書検証

### webrtc_c でカバーできない・追加が必要な API（カテゴリと優先度）

Phase 0 PoC で必要性を実測し、`shiguredo/webrtc-rs` リポジトリで各カテゴリの追加検討 issue を起票して合意してから sora-ios-sdk 側の Phase 1 に着手する。webrtc-rs 側が「追加しない」と判断した API は sora-ios-sdk 側の代替戦略を確定する。

優先度タグ: **[Blocker]** = Phase 1 着手のブロッカー、**[Workaroundable]** = sora-ios-sdk 側で代替実装可能、**[Optional]** = 削除可。

- **Stats**（`api/stats/rtc_stats_report.h`）
  - [Blocker] エントリー単位の `id` / `type` / `timestamp_us` / `values` 列挙 API（または代替案として `webrtc_RTCStatsReport_ToJson` の JSON 文字列ベースに `Statistics.entries` を作り直し、`StatisticsEntry` クラスを廃止する）
- **PeerConnection**（`api/peer_connection_interface.h`）
  - [Blocker] `GetTransceivers` / `GetSenders` / `GetReceivers` 相当の C API（再 offer / mid マッピング）
  - [Blocker] `PeerConnectionObserver.OnSignalingChange` の有効化（現状コメントアウトで未公開）
  - [Workaroundable] `OnIceCandidatesRemoved`（現状 `PeerChannel.swift` で利用、削除可否を Phase 0 で判定）
  - [Workaroundable] レガシー Plan B の `OnAddStream` / `OnRemoveStream` は Unified Plan の `OnTrack` ベース実装へ置き換え
  - [Optional] `OnRenegotiationNeeded`（デバッグログ用途）
- **RtpTransceiver / RtpSender**（`api/rtp_transceiver_interface.h` / `api/rtp_sender_interface.h`）
  - [Blocker] RtpTransceiver: `mid()` / `sender()` / `direction()` / `current_direction()` / `SetDirection(WithError)` / `Stop()`
  - [Blocker] RtpSender: `track()` / `SetStreamIds(_:)`（`GetParameters` / `SetParameters` / `SetTrack` は公開済み）
- **AudioSession**（`sdk/objc/components/audio/audio_session.h`）
  - [Workaroundable] `useManualAudio` / `isAudioEnabled` / `setCategory(_:with:)` / `setMode(_:)` / `overrideOutputAudioPort(_:)`。代替案として `AVAudioSession.sharedInstance()` を Swift 側から直接叩く（libwebrtc 内部 ADM との排他確保策が別途必要）
  - [Workaroundable] `RTCAudioSessionConfiguration.webRTC()` 相当の libwebrtc 内部 AudioSession 設定アクセス
  - 通知（`interruptionNotification` 等）の購読は webrtc_c では公開しない方針。Swift 側で `NotificationCenter` 直接購読を実装する。
- **AudioDeviceModule**（`api/audio/audio_device.h` 配下）
  - [Blocker] `bypassVoiceProcessing` 指定で iOS の ADM を生成する C API（時雨堂 `webrtc-build` パッチ由来、Configuration の公開 API）
  - [Blocker] `pauseRecording()` / `resumeRecording()` 相当（`AudioDeviceModuleWrapper.swift` で利用）
- **DataChannel**（`api/data_channel_interface.h` 周辺）
  - [Workaroundable] `OnBufferedAmountChange` コールバック（現状ログ目的のみ、削除可否を Phase 0 で判定）
- **Logger**（`rtc_base/logging.h`）
  - [Workaroundable] `LogMessage` のコールバック登録 API（`RTCCallbackLogger` 相当）。代替案として `Sora.setWebRTCLogLevel` のログコールバックを廃止する破壊的変更を許容
- **VideoEncoderFactory**（`media/engine/simulcast_encoder_adapter.h` 周辺）
  - [Blocker] `RTCVideoEncoderFactorySimulcast(primary:fallback:)` 相当の `VideoEncoderFactory` を作る C API。現状 webrtc_c には `SimulcastEncoderAdapter` 単体しかなく PeerConnectionFactory に渡せる Factory が無い
- **SSLCertificateVerifier**（`rtc_base/ssl_certificate.h` 周辺）
  - [Blocker] `RTCSSLCertificateVerifier.verifyChain` 相当の C コールバック登録 API（TURN-TLS で iOS の CA を利用するために必須）
- **AudioSource.volume**（`api/media_stream_interface.h`）
  - [Workaroundable] `AudioSourceInterface.SetVolume(_:Double)` / `GetVolume() -> Double` 相当（`MediaStream.remoteAudioVolume` の維持に必要）
- **Dispatcher**（webrtc_c 全般）
  - [Workaroundable] `RTCDispatcher.dispatchAsync` / `RTCDispatcherQueueType` 相当（`SoraDispatcher.swift`）。代替案として GCD 直接利用に切り替え

webrtc_c 側に依頼する C API 関数名は `webrtc-rs` の `RULES.md` 命名規則（`webrtc_<TypeName>_<snake_case_method>`、例: `webrtc_PeerConnectionInterface_get_transceivers`）に従う。具体的な関数シグネチャは webrtc-rs 側の起票 issue で確定する。

### 関連 issue

本 issue は以下の issue と相互作用する。着手前後の調整方針も合わせて明記する。

- `issues/0008-add-network-priority-to-rtp-encoding.md` (Active): `RTCRtpEncodingParameters.networkPriority` を `RTCPriority` 経由で設定する設計。本 issue の Phase 3 で `RTCRtpEncodingParameters` 自体が消えるため、0008 と本 issue のどちらを先に進めるかを着手前に確定する。0008 を先行する場合、本 issue 完了時に再度書き換えが必要。
- `issues/0032-investigate-libwebrtc-package-update-automation.md` (Active): 現行 `WebRTC.xcframework` のバージョン更新自動化。本 issue 着手時点で `issues/pending/` に移動し、Phase 0 完了後（移行確定後）に `libwebrtc_c.xcframework` 向けに書き直して再 active 化する。
- `issues/0034-add-onicecandidateerror-log.md` (Active): `RTCPeerConnectionDelegate.peerConnection(_:didFailToGatherIceCandidate:)` を追加する。本 issue の Phase 3 で `OnIceCandidateError` の C コールバックベースに置き換える際、シグネチャ整合を確認する。
- `issues/0035-add-audio-session-event-handlers.md` (Active): `SoraHandlers.onChangeAudioRoute` の追加。本 issue の AudioSession 通知独自実装と直接競合する。第 1 引数型 `RTCAudioSession` の変更は破壊的変更として確定する（互換性方針参照）。
- `issues/0066-investigate-notice-file.md` (Active): 依存先が `shiguredo-webrtc-build` から `shiguredo/webrtc-rs` に変わるため、NOTICE / LICENSE の更新方針も合わせて見直す。
- `issues/0067-add-dummy-video-source.md` / `issues/0068-add-dummy-audio-source.md` (Active): `RTCVideoFrame` / `RTCVideoSource.capturer(_:didCapture:)` 直接依存。本 issue 着手時点で 0067 / 0068 のマージ状態に応じ、Phase 4 でまとめて移行するか、別途追従するかを判断する。
- `issues/pending/0009-add-stereo-audio-input.md` / `issues/pending/0010-add-stereo-audio-output.md`: `RTCAudioDeviceModule` の API カバレッジ次第。webrtc_c の ADM カバレッジ確認結果（Phase 0）に応じて pending 解除条件が変わる。
- `issues/pending/0049-add-disable-builtin-ssl-certificates.md`: `IOSCertificateVerifier` + `webrtc-build` パッチを前提とした issue。`libwebrtc_c.xcframework` に同パッチが取り込まれるかを Phase 0 で確認する。
- `issues/pending/0059-add-vp9-hwa-decode.md`: `RTCDefaultVideoDecoderFactory.initWithH265:vp9Profile0:vp9Profile2:vp9VTB:av1:` 前提。webrtc_c で同等の Factory 初期化経路があるかを Phase 0 で確認する。
- `issues/pending/0064-add-turn-tls-client-certificate.md`: 「ObjC SDK が API を公開していない」が Pending 理由。本 issue で webrtc_c に移行すれば libwebrtc C++ レイヤーに直接アクセスできるため、Pending 解除候補。
- `issues/pending/0069-add-priority-to-rtp-encoding.md`: ObjC SDK が露出していない libwebrtc API への対応事例。本 issue 完了後はこの種の追従コストが下がる。

## 設計方針

### 全体方針

1. `Package.swift` の `binaryTarget` を `WebRTC.xcframework` から `libwebrtc_c.xcframework` に差し替える。Phase 0〜4 の間は両 xcframework を Package.swift に併存させ、Phase 4 完了時点で `WebRTC.xcframework` を削除する。
2. C ヘッダ群を `CWebrtc` モジュールとして公開し、Swift から `@_implementationOnly import CWebrtc` で利用する。`@_implementationOnly` は Swift コンパイラの非公式属性であり、Swift 6 言語モード（develop で対応進行中）での安定動作確認は Phase 0 の必須項目とする。代替案として `package` access level / `internal import` の採用可否も Phase 0 で評価する。
3. Swift 側で `OpaquePointer` を保持する所有クラスを作り、`deinit` で C 側の `Release` / `delete` を呼ぶ。
4. PeerConnection / DataChannel の Observer は C 側にトランポリンを書き、Swift クロージャに `Unmanaged.passRetained(self).toOpaque()` 経由で `user_data` を渡す（`shiguredo/sora-flutter-sdk` の `apple_bridge.c` 内 `SoraObserverBridge` / `DcBridgeContext` を雛形として移植）。
5. iOS 固有の追加実装（カメラ / レンダラ / 権限 / AudioSession 通知 / ReplayKit 連携 / Simulcast Factory / TURN-TLS 検証）は Flutter SDK の Swift / C ブリッジを雛形として移植する。雛形が無い領域は新規に書く（前節「参考となる Flutter SDK の iOS 実装」末尾参照）。
6. SDK のバージョンを major bump し、`RTC*` 型を公開していた public API は破壊的変更を許容する（次節「既存ユーザーへの互換性方針」参照）。

### 既存ユーザーへの互換性方針

本移行は内部実装の刷新だけでなく、`Sora/*.swift` の public API シグネチャに `RTC*` 型が直接露出している箇所が多数あるため、後方互換性を完全に維持することは不可能である。本 SDK の major バージョンを 1 つ上げ、以下の public API について破壊的変更を許容する方針とする。各 API について「ラップ用 Swift 型を新設する」「廃止する」「`internal` に降格する」のどれを採用するかは、Phase 0 完了時に最終確定する。

破壊的変更が確定または濃厚な public API（シグネチャに `RTC*` 型が露出しているもの）:

- `VideoFrame.native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)`（`VideoFrame.swift`）
- `MediaChannel.native: RTCPeerConnection?`
- `MediaStream.addAudioTrackSink(_: RTCAudioTrackSink)` / `removeAudioTrackSink(_:)`（`RTCAudioTrackSink` 露出）
- `MediaStream.remoteAudioVolume`（`AudioSource.volume` 利用、webrtc_c 側の API 追加結果に依存）
- `SoraHandlers.onChangeAudioRoute: ((RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription) -> Void)?`（第 1 引数 `RTCAudioSession` を `AVAudioSession` に変更）
- `Sora.setWebRTCLogLevel(_: RTCLoggingSeverity)`（`RTCCallbackLogger` 利用、webrtc_c でログコールバック登録 API が追加されなければシグネチャ変更不可避）
- `SignalingOffer.Encoding.rtpEncodingParameters: RTCRtpEncodingParameters`（`Signaling.swift`）
- `SignalingOffer.Encoding.scaleResolutionDownTo: RTCResolutionRestriction?`（`Signaling.swift`）
- `WebRTCInfo`（`PackageInfo.swift`、現状は `enum` の namespace で `version` / `branch` / `commitPosition` / `maintenanceVersion` / `revision` を `static let` で公開。取得経路はハードコードを継続するか `webrtc_c` の C 関数経由に切り替えるかを Phase 0 で確定）
- `Statistics` / `StatisticsEntry`（`RTCStatisticsReport` 経由）: webrtc_c の Stats API が追加されなければ `Statistics.entries` プロパティを廃止し `Statistics.jsonString: String` ベースに変更、`StatisticsEntry` クラス自体を削除する候補

挙動が変わる可能性がある public API（シグネチャに `RTC*` を含まないが内部実装が変わる）:

- `Sora.usesManualAudio` / `audioEnabled` / `configureAudioSession(block:)` / `setAudioMode(_:options:)`: `RTCAudioSession` 直接呼び出しに依存する内部実装が `AVAudioSession` 直接利用または webrtc_c 経由に変わる。シグネチャは維持されるが libwebrtc 内部 ADM との排他確保策の変更に伴って挙動差が出得る。
- `CameraVideoCapturer.captureSession: AVCaptureSession` / `devices: [AVCaptureDevice]`: `RTCCameraVideoCapturer` 由来の値が `AVFoundation` 直接利用に変わる。シグネチャは維持。

### スタック構成

移行前:

```
[Sora (Swift)]
  └─ import WebRTC（ObjC SDK ヘッダ）
       ↓
     WebRTC.xcframework（libwebrtc + ObjC ラッパー）
```

移行後:

```
[Sora (Swift)]
  ├─ 既存の Swift コード（PeerChannel / MediaChannel / Sora / ...）を C API 呼び出しに書き換え
  ├─ Swift ⇔ C 基盤（OpaquePointer 所有クラス / @convention(c) トランポリン / エラー変換）
  ├─ iOS 固有実装（カメラ / レンダラ / 権限 / AudioSession 通知）
  └─ CWebrtc (C モジュール) ─── apple_bridge.c (Observer トランポリン / RenderingSink / ヘルパ)
                                  ↓
                                libwebrtc_c.xcframework (libwebrtc + C ラッパー + ObjC SDK の一部)
```

### Swift ⇔ C 境界の基本パターン

- `webrtc_PeerConnectionInterface_refcounted*` などの参照カウント型は Swift クラスが所有し、`deinit` で `Release` を呼ぶ。
- C 関数ポインタには `@convention(c)` トランポリンを使い、`Unmanaged.passRetained(self).toOpaque()` で `user_data` を渡す。
- C 構造体は Swift 側でミラー定義し、コンバータで相互変換する。
- エラーは `webrtc_RTCError` を Swift `Error` 型に変換する。
- すべての変換層は共通モジュール（仮称 `CWebrtcSupport.swift` 等）に集約する。
- スレッドモデル: C API で 3 スレッド (network / worker / signaling) を自前起動するため、callback がどのスレッドで呼ばれるか、既存 `SoraDispatcher.swift` の dispatch queue 設計、`@MainActor` 隔離、`VideoRenderer` の MainActor 化との整合を Phase 0 で確認する。

## 完了条件

本 issue の完了条件は **Phase 0 完了基準を満たすこと**。Phase 1 以降の完了条件は各 Phase の個別 issue で定義する。本セクション末尾には Phase 1〜5 完了時の総合条件（最終ゴール）も参考として記載する。

### Phase 0 完了基準

PoC で必ず実施する **必須項目**:

- `Package.swift` を `libwebrtc_c.xcframework` の `binaryTarget` に差し替えてビルドが通る（両 xcframework の併存を許容）。移行後の `Package.swift` 最小スニペットを Flutter SDK 版から不要部分を削除した形で作成し、本 issue の「## 解決方法」セクションに記載する。
- 採用する `libwebrtc_c.xcframework` のバージョンを確定し、同梱される libwebrtc のバージョンが現行 `m148.7778.7.0` と一致するか確認する。checksum 取得手順（`swift package compute-checksum libwebrtc_c.xcframework.zip` 等）を実例として残す。
- `Sora/WebRTCConfiguration.swift` または `Sora/ICECandidate.swift` を 1 本だけ webrtc_c の C API 経由に書き換えてビルドと単体起動を確認する。
- PoC 範囲として「PeerConnection 生成 → AddTransceiver → 簡単な offer/answer 交換 → AddIceCandidate → GetStats → Logger コールバック → ConnectionClose」までの最小 E2E ループを `Sora/` 外の使い捨てサンプル（候補: リポジトリルート直下の `tools/` または `examples/` 配下、もしくはローカル限定ブランチで管理する形。配置場所は Phase 0 着手時に決定）として 1 本書き、libwebrtc_c.xcframework だけで実機（iPhone 実機 1 台 / iOS Simulator 1 台）で動作することを確認する。スレッドモデル・Observer 配線・Stats 取得・Logger コールバックの摩擦点を実測する。
- `@_implementationOnly import CWebrtc` を Swift 6 言語モードで安定動作させられるかを確認する。不可なら `package` access level / `internal import` 等の代替方針を確定する。
- iOS deployment target の必要バージョンを確認する（現行 `.iOS(.v14)`、Flutter SDK は `.iOS("16.0")`）。`libwebrtc_c.xcframework` の最低 iOS バージョンを実測し、`.iOS(.v14)` 維持可否を判断する。維持不可と判明した場合、最低バージョン引き上げを本移行の major bump に含めるか別の major bump を切るかを判断する。
- `WebRTCInfo` の version / commitPosition 等のメタデータの入手経路を確認する（ハードコード継続か `webrtc_c` の C 関数経由かを確定）。
- 「webrtc_c でカバーできない・追加が必要な API」のカテゴリごとに `shiguredo/webrtc-rs` リポジトリで追加検討 issue を起票し、合意結果と起票 issue リンクを本 issue の解決方法に転記する。webrtc-rs 側が「追加しない」とした項目には sora-ios-sdk 側の代替戦略を併記する。
- 「既存ユーザーへの互換性方針」セクションの破壊リストの最終版を確定する（Phase 0 結果を踏まえて項目を追加・削除）。
- `sora-ios-sdk-samples` 側で `import WebRTC` を直接使っている箇所の有無を調査し、対応 PR の予定を本 issue に追記する。
- `shiguredo/webrtc-rs` の `RULES.md` を精読し、C API stability / semver 方針が記載されているか確認する。記載がなければ webrtc-rs メンテナと合意する。
- `Sora/Sora.h` の ObjC umbrella header と `CWebrtc` モジュールの共存可否を確認し、`module.modulemap` 新設の要否を判定する。
- Phase 1〜5 の個別 issue の分割粒度・順序・依存関係を確定する。

Phase 0 で **情報収集する項目**（Go/No-Go 判定の参考値）:

- `.ipa` サイズ delta と起動時間 delta の計測（両 xcframework 併存中の値であり最終形を代表しないため、Phase 4 で再計測する前提）
- `apple_bridge.c` 由来のスタックトレースの Crashlytics 等でのシンボリック解決確認

Go/No-Go 基準: Phase 0 着手時に `shiguredo/sora-cpp-sdk` / `shiguredo/sora-flutter-sdk` の webrtc_c 移行実績を調査して数値ターゲットを再校正する。校正前の暫定ターゲットは:

- PoC で書き換えた範囲の Swift コード行数が **元コードの 2 倍以内** であること（2 倍超過なら本格着手を中止し別案を検討）。
- 「webrtc_c に追加が必要な API」の [Blocker] のうち、webrtc-rs 側で追加 NG となった項目が **0 件** であること。[Workaroundable] が `3 件以内` で sora-ios-sdk 側の代替戦略が立つこと。
- 数値ターゲットの根拠は Phase 0 着手時の調査結果に基づき本 issue に追記して確定する。

PoC の期限: 着手から **4 週間以内** に Go/No-Go を判断する。期限内に終わらない項目は「情報収集」へ降格させて記録する。

Phase 0 完了時の処理:

- PoC 結果を本 issue の「## 解決方法」セクションに追記する。追記内容は本セクションの「必須項目」「情報収集項目」「Go/No-Go 基準」の各項目に対する実測値・判定・根拠で構成する。
- Go 判定時: `Package.swift` 差し替えと 1 ファイル書き換えを `develop` にマージし、本 issue を `issues/closed/` に移動する。同時に Phase 1〜5 を担当する個別 issue を新規起票する。
- No-Go 判定時: 本 issue の Branch を破棄し、本 issue を `issues/closed/` に移動する。Phase 1〜5 の起票はしない。本 issue の解決方法に No-Go の根拠を残す。
- `CHANGES.md` の `## develop` への追記は Go 判定時のみ、`Package.swift` 併存追加の `[UPDATE]` エントリーを追加する（`shiguredo-changelog` 参照）。No-Go 時は CHANGES.md への追記なし。

PoC を完了せずに Phase 1 以降に進むことは禁止する。Phase 0 で書いた使い捨てサンプル・Phase 0 のためだけの C ブリッジは `Sora/` には残さず、本 issue close 時点で削除する。

### Phase 1〜5 完了時の総合条件（参考）

最終的に sora-ios-sdk として完成形に到達した時点で満たすべき条件。各 Phase の個別 issue の完了条件はこれを部分的に分担する形で定義する。

- `Package.swift` から `WebRTC.xcframework` への依存が消え、`libwebrtc_c.xcframework` のみに依存している。
- `Sora/` 配下（`Sora/*.swift` および `Sora/Extensions/*.swift` を含む）および `SoraTests/` 配下に `import WebRTC` を含む Swift ファイルが 0 個。
- 既存サンプルアプリ（`sora-ios-sdk-samples`）が新 SDK で接続 / 送受信 / 切断まで通る。
- 主要シナリオの実機検証チェックリストがクリアされている（Phase 5 で実施）:
  - Sendrecv / Sendonly / Recvonly の各モード
  - カメラ前後切替
  - AirPods 接続 / 切断
  - Background audio 継続
  - 画面回転
  - 低速回線
  - ネットワーク断 → 再接続
  - DataChannel 送受信（`isOrdered` / `maxRetransmits` の preserve_order 含む）
  - 統計情報取得
  - Simulcast 接続（rid 指定送受信）
  - Spotlight 接続（focus / unfocus）
  - Multistream 受信（3 名以上）
  - Stereo Audio（Opus stereo、`0009` / `0010` 関連）
  - 映像コーデック切替（VP8 / VP9 / H264 / H265 / AV1）
  - TURN-UDP / TURN-TCP / TURN-TLS 各経路（特に TURN-TLS で iOS CA 検証）
  - ReplayKit 画面共有
- `CHANGES.md` に最終マージ時の変更履歴を追記している（メジャーバージョン bump、互換性破壊 API のリスト、移行ガイドへのリンク）。

## 解決方法

### Phase 0: PoC（本 issue の作業範囲）

目的: Phase 1 以降の本格着手の判断材料を得る。

主要作業:

- `Package.swift` を `libwebrtc_c.xcframework` の `binaryTarget` に差し替える。Flutter SDK の `Package.swift` を雛形に最小スニペットを作成する。
- `WebRTCConfiguration.swift`（197 行、機械置換系）または `ICECandidate.swift`（42 行）のうち 1 本を webrtc_c の C API 経由に書き換える。
- 上記「Phase 0 完了基準」に列挙した全項目を実測し、本セクションに結果を追記する。

PoC 結果は本セクション末尾に「Phase 0 PoC 結果」として追記する。「Phase 0 完了基準」の各項目に対応する実測値・判定・根拠を網羅する形式とする（Phase 0 完了基準と PoC 結果フォーマットは二重定義しない）。

### Phase 1〜5（Phase 0 完了後に個別 issue として起票）

Phase 0 完了時点で確定する内容（PoC で得た行数膨張率、webrtc_c の追加 API 合意、互換性方針の最終版）を踏まえ、以下の順序で個別 issue を新規起票する。各 issue の分割粒度・カテゴリ・Branch prefix は起票時に決定する。1 issue = 1 branch = 1 PR を厳守する。

- Phase 1: Swift ⇔ C 共通インフラ（ハンドル基盤・トランポリン・エラー変換・Logger 連携）
- Phase 2: 機械置換系（`WebRTCConfiguration` / `ICE*` / `Statistics` / `ConnectionState` / `TLSSecurityPolicy` / `Utilities` と `VideoCapturer` の `import` 文除去 / `MediaChannelConfiguration` の削除）
- Phase 3: コア層（`NativePeerChannelFactory` / `PeerChannel` / `DataChannel` / `MediaChannel` / `MediaStream` / `Signaling`、`Extensions/RTC+Description.swift` の削除を含む）
- Phase 4: メディア・iOS 固有層（`CameraVideoCapturer` / `VideoView.xib` の `customClass` 書き換えを含む `VideoView`+`VideoRenderer`+`VideoFrame` / `ScreenCapture` / `Sora.swift` の AudioSession / `AudioDeviceModuleWrapper` / `IOSCertificateVerifier`）。Phase 4 の最終 issue で `Package.swift` から `WebRTC.xcframework` を削除し、同時に `SoraTests/SoraTests.swift` の `import WebRTC` を除去する。
- Phase 5: 検証（`SoraTests/` の再構築・`sora-ios-sdk-samples` 対応 PR・「Phase 1〜5 完了時の総合条件」の実機検証チェックリスト全項目の合格判定）

Phase 1〜4 進行中は両 xcframework を `Package.swift` に併存させる（シンボル衝突の有無を Phase 1 着手時に検証）。

## リスクと留意点

- メモリ安全性の低下: Swift ⇔ C 境界で `OpaquePointer` / `Unmanaged.passRetained` / `@convention(c)` トランポリンを多用する。use-after-free / 参照カウント漏れ / observer 循環参照によるクラッシュを Phase 0 で実測する。
- クラッシュレポートの可読性低下: スタックトレースが C 関数名と libwebrtc 内部 C++ シンボル中心になる。Crashlytics 等でのシンボリック解決手順を Phase 0 で確認する。
- webrtc_c の若さ: 未対応 API や未発見バグの可能性あり。Flutter SDK で踏まれていない iOS 固有経路で問題が出る可能性がある。「webrtc_c に追加が必要な API」リストの [Blocker] が解消されなければ Phase 1 着手不可。
- webrtc_c の API スタビリティ: 本 issue 進行中に webrtc_c の C API が破壊的に変更されないかは未保証。Phase 0 で `shiguredo/webrtc-rs/RULES.md` の API stability / semver 方針を確認・合意する。
- 大規模 PR / 長寿命ブランチ: Phase 1〜5 を進める間、`develop` で進行する他の issue 修正との conflict 解消コストが膨らむ。Phase ごとに小さい PR で `develop` へ小まめにマージする。
- 外部リポジトリへの波及: `shiguredo/webrtc-rs` への API 追加 PR（複数）、`sora-ios-sdk-samples` への対応 PR、ドキュメント（jazzy / DocC）更新等、本リポジトリ外の作業が複数発生する。
- xcframework サイズ・起動時間: `-all_load` で全静的ライブラリを強制ロードするため、現行と比較して悪化する可能性がある。Phase 0 で実測（情報収集）、Phase 4 で本格計測する。
- NOTICE / LICENSE: 依存先が `webrtc-build` から `webrtc-rs` の C ラッパー部に変わる。`issues/0066-investigate-notice-file.md` と整合した NOTICE 更新計画を Phase 0 で確定する。

## 参考リソース

- `shiguredo/sora-flutter-sdk` リポジトリの `ios/sora_sdk/`
  - `Package.swift`（binaryTarget の雛形）
  - `Sources/CWebrtc/apple_bridge.c`（Observer トランポリン / `AppleRenderingSink` / AudioSession ヘルパ）
  - `Sources/CWebrtc/CWebrtc/CWebrtc.h`（C モジュールヘッダ）
  - `Sources/CWebrtc/CWebrtc/module.modulemap`
  - `Sources/sora_sdk/SoraCameraCapturer.swift`
  - `Sources/sora_sdk/SoraVideoRendererSink.swift`
  - `Sources/sora_sdk/SoraMediaAccess.swift`
  - `exported_symbols.exp`
- `shiguredo/webrtc-rs` リポジトリの `webrtc/`
  - `RULES.md`（C ラッパー作成ルール、命名規則、API stability 方針）
  - `src/webrtc_c.h`（メインヘッダ）
  - `src/webrtc_c/api/` 配下の C ヘッダ群
  - `src/webrtc_c/sdk/objc/`（Factory + AudioSession の C ラッパー）
  - `src/whip.c` / `src/whep.c`（C のみでの PeerConnection 組み立て例）
- libwebrtc 本体（`webrtc-checkout` の `src/sdk/objc/` 等、xcframework 内部で利用される ObjC 実装の参照用）
- `shiguredo/sora-cpp-sdk` リポジトリ（webrtc_c 利用の C++ 側実例、webrtc_c 移行の数値ターゲット校正にも参照）
- 既存 sora-ios-sdk: `Sora/` 配下全ファイル
