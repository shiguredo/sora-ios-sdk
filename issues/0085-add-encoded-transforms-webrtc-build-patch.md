# WebRTC Encoded Transforms 対応の libwebrtc パッチとリリース

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms-webrtc-build-patch

## 目的

WebRTC Encoded Transforms を iOS SDK から利用できるようにするため、shiguredo-webrtc-build に Encoded Transform の ObjC API を追加するパッチを実装し、WebRTC.xcframework をリリースする。

## 現状

- libwebrtc ネイティブ C++ には `FrameTransformerInterface` が存在するが、iOS ObjC API（ `sdk/objc/` ）には存在しない
- sora-ios-sdk は WebRTC.xcframework を GitHub Releases から取得している（ `Package.swift` の `binaryTarget` ）
- `h265_ios.patch` が ObjC API を追加するパッチの参考実装となる（ `sdk/objc/` に新規ファイル + `sdk/BUILD.gn` に sources / common_objc_headers 追加）

## 設計方針

- sora-python-sdk の C++ 実装（ `src/sora_frame_transformer.h` ）を ObjC に移植する
- `h265_ios.patch` と同方式でパッチ（ `patches/encoded_transform_ios.patch` ）を追加し、 `run.py` の `PATCHES` に登録する

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
- `RTCEncodedVideoFrame`: `TransformableVideoFrameInterface` のラップ（data / payloadType / ssrc / timestamp / mimeType / isKeyFrame / rid / width / height）
- `RTCEncodedAudioFrame`: `TransformableAudioFrameInterface` のラップ（data / payloadType / ssrc / timestamp / mimeType / contributingSources / sequenceNumber / audioLevel）
- `RTCRtpSender.frameTransformer` プロパティ + `generateKeyFrameForRids:`
- `RTCRtpReceiver.frameTransformer` プロパティ

### 初版で公開しないもの

- `direction` / ビデオの `frameId` / `spatialIndex` / `temporalIndex` などのメタデータ、オーディオの `receiveTime` は公開しない（必要な要望が出たら別途追加する）

## 完了条件

- 上記 ObjC API を追加したパッチ（ `patches/encoded_transform_ios.patch` ）が作成され、 `run.py` の `PATCHES` に登録されていること
- iOS 向けにビルドし、WebRTC.xcframework.zip が生成されること
- WebRTC.xcframework.zip が shiguredo-webrtc-build の GitHub Releases にアップロードされていること
- ビデオ・オーディオ両方のフレーム変換が動作すること（sora-ios-sdk 側の実装で確認）

## 解決方法

（未定）
