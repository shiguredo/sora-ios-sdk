# WebRTC Encoded Transforms 対応の libwebrtc パッチとリリース

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms-webrtc-build-patch
- Polished: 2026-09-24

## 目的

WebRTC Encoded Transforms を iOS SDK から利用できるようにするため、shiguredo-webrtc-build に Encoded Transform の ObjC API を追加するパッチを実装し、WebRTC.xcframework をリリースする。

## 現状

以下は sora-ios-sdk が現行依存する libwebrtc m154.8037.1.2（ `Package.swift` の `libwebrtcVersion`、branch-heads/8037）と、shiguredo-webrtc-build の `VERSION` が参照する libwebrtc m155.8059.1（ branch-heads/8059 ）で確認した内容である。0084 の調査対象は m150.7871 だったが、ここに挙げる API の有無は m154 / m155 でも同じである。

- libwebrtc ネイティブ C++ には `FrameTransformerInterface` / `TransformableFrameInterface` / `TransformableVideoFrameInterface` / `TransformableAudioFrameInterface` / `TransformedFrameCallback` が存在する（ `api/frame_transformer_interface.h` ）
- `api/rtp_sender_interface.h` の `RtpSenderInterface` に `SetFrameTransformer()` と `GenerateKeyFrame(rids)`、`api/rtp_receiver_interface.h` の `RtpReceiverInterface` に `SetFrameTransformer()` が存在する
- 一方、iOS ObjC API（ `sdk/objc/` ）には Encoded Transforms のブリッジが存在しない（ `RTCRtpSender.h` / `RTCRtpReceiver.h` に `frameTransformer` はなく、`RTCEncodedVideoFrame` / `RTCEncodedAudioFrame` / `RTCFrameTransformer` は存在しない）。upstream の最新版（ main ）でも追加されていないため、パッチでの追加が必要である
- sora-ios-sdk は WebRTC.xcframework を GitHub Releases から取得している（ `Package.swift` の `binaryTarget` ）
- `h265_ios.patch` が ObjC API を追加するパッチの参考実装となる（ `sdk/objc/` に新規ファイル + `sdk/BUILD.gn` に sources / common_objc_headers 追加）
- 関連する方針として `0070`（ WebRTC.xcframework から libwebrtc_c.xcframework への移行、open / High）がある。移行完了後は ObjC パッチが不要になり、webrtc-rs の C API 経由になる（ sora-rust-sdk の対応で webrtc-rs 0.152 に FrameTransformer の C ラッパーと Rust API が既に追加済み）。移行は未着手（ Phase 0 前）のため、本 issue は現行 WebRTC.xcframework 向けの暫定対応として実施し、0070 の進行次第で本 issue を再評価する

## 設計方針

- sora-python-sdk の C++ 実装（ `src/sora_frame_transformer.h` ）を ObjC に移植する
- `h265_ios.patch` と同方式でパッチ（ `patches/encoded_transform_ios.patch` ）を追加し、 `run.py` の `PATCHES` に登録する
- sora-rust-sdk の設計方針（ `sora-rust-sdk/issues/0106` ）を参照する:
  - コールバックは webrtc-rs の「関数ポインタ構造体 + `Box<dyn Trait>` の user_data」パターン（ `VideoEncoderEncodedImageCallback` と同型）に相当する方式とし、ObjC ではデリゲートパターンで実現する
  - バックプレッシャーは持たない。libwebrtc 側の委譲実装に任せ、フレームの順序保証・ドロップの判断も libwebrtc の仕様に従う
  - 変換後のフレームは元の順序を保ち、重複なく返す（ MDN の「Using WebRTC Encoded Transforms」にも明記されている: https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_Encoded_Transforms ）

### 追加する ObjC API（ビデオ・オーディオ両対応）

- `RTCFrameTransformer`: 具象クラス + デリゲートプロトコル（ `RTCFrameTransformerDelegate` ）
  - `initWithKind:delegate:` で処理対象のフレーム種別（ `RTCFrameTransformerKindVideo` / `RTCFrameTransformerKindAudio` ）とデリゲートを指定
  - デリゲートが `didReceiveVideoFrame:` / `didReceiveAudioFrame:` でフレームを受け取り、 `enqueueVideoFrame:` / `enqueueAudioFrame:` でストリームに戻す
  - 内部に C++ `FrameTransformerInterface` の実装（ `ObjCFrameTransformer` ）を保持
  - Audio は `RegisterTransformedFrameCallback`（default）、Video は `RegisterTransformedFrameSinkCallback`（SSRC ごと）の両方を実装
  - 破棄時は `StartShortCircuiting` でバイパス化し、以後のフレームを変換なしで直接パイプラインに戻す
  - `Transform()` は libwebrtc のワーカースレッドから呼ばれる。コールバックはそのスレッド上で直接呼び出すため、アプリ側で必要なディスパッチを行う（doc コメントに明記）
  - `GetData` はネイティブ所有バッファのため、ObjC 側にはコピーして渡す（UAF 回避）
  - デリゲートが解放済みの場合はフレームをそのままパイプラインに戻す（映像・音声が止まらないようにする）
  - 送信側はシミュラカストの rid ごとにフレームが届くため、 `RTCEncodedVideoFrame` に rid を含める
- `RTCEncodedVideoFrame`: `TransformableVideoFrameInterface` のラップ（data / payloadType / ssrc / timestamp / mimeType / isKeyFrame / rid / width / height）。timestamp は非推奨の `GetTimestamp` ではなく `GetRtpTimestampInfo`（ `RtpTimestampWithOffset` / `RtpTimestampWithoutOffset` の値）から取得する（sora-rust-sdk の設計方針（ 0106 ）も「非推奨の API は wrap しない」としている）。width / height は `Metadata()` の `GetWidth()` / `GetHeight()` から取得する
- `RTCEncodedAudioFrame`: `TransformableAudioFrameInterface` のラップ（data / payloadType / ssrc / timestamp / mimeType / contributingSources / sequenceNumber / audioLevel）。timestamp の取得元は `RTCEncodedVideoFrame` と同じとする
- `RTCRtpSender.frameTransformer` プロパティ + `generateKeyFrameForRids:`
- `RTCRtpReceiver.frameTransformer` プロパティ

### 初版で公開しないもの

- `direction` / ビデオの `frameId` / `spatialIndex` / `temporalIndex` などのメタデータ、オーディオの `receiveTime` は公開しない（必要な要望が出たら別途追加する）
- 受信側キーフレーム要求（ `sendKeyFrameRequest` ）は提供しない。ネイティブ API が存在せず、Sora は SFU でありキーフレーム要求はサーバー側の自動 PLI / FIR で管理される（0084 で確定済み）

## 完了条件

- 上記 ObjC API を追加したパッチ（ `patches/encoded_transform_ios.patch` ）が shiguredo-webrtc-build リポジトリに作成され、 `run.py` の `PATCHES` に登録されていること。登録先は WebRTC.xcframework.zip を生成する `ios_sdk` を含むこと（`ios` / `macos_arm64` など他の対象への登録は、`h265_ios.patch` が登録されている対象を参考に判断する）
- パッチは shiguredo-webrtc-build の `VERSION` が参照する libwebrtc（ 現在 155.8059.1 ）に適用でき、`ios_sdk` 向けにビルドして WebRTC.xcframework.zip が生成されること
- WebRTC.xcframework.zip が shiguredo-webrtc-build の GitHub Releases にアップロードされていること
- shiguredo-webrtc-build の規約に従い、`patches/README.md` と CHANGES.md（ webrtc-build 側）に変更内容が追記されていること
- ビデオ・オーディオ両方のフレーム変換が本パッチの ObjC API で動作すること（sora-ios-sdk への組み込みは 0086、実際の送受信による検証は 0087 の完了条件とする。本 issue の完了はパッチとリリースまでとし、SDK 側の実装を待たない）

## 解決方法

（未定）
