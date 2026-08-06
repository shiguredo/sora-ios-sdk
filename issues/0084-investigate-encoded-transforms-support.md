# WebRTC Encoded Transforms 対応の実現可能性を調査し方針を確定する

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms

## 目的

MDN の "Using WebRTC Encoded Transforms"（ `RTCRtpScriptTransform` / `RTCEncodedVideoFrame` / `RTCEncodedAudioFrame` / `generateKeyFrame` / `sendKeyFrameRequest` ）に相当する機能を Sora iOS SDK に追加する。エンドツーエンド暗号化、フレーム改変（SEI 付加等）、キーフレーム制御をアプリケーション側から実現できるようにする。

## 優先度根拠

- フレーム暗号化・改変の要求はエンタープライズ利用で増加しており、libwebrtc の更新と連動して対応する必要があるため Medium とする
- 既存機能の不具合ではないため High にはしない
- 案 B は自社ビルドの libwebrtc へのパッチ追加が必要であり、libwebrtc の更新タイミングに依存するため Low にもしない

## 現状

### 調査結果（2026-08-06 時点、libwebrtc 150.7871 = branch-heads/7871）

- libwebrtc ネイティブ側には Encoded Transform の API が存在する
  - `api/frame_transformer_interface.h` に `FrameTransformerInterface` / `TransformableFrameInterface` / `TransformableVideoFrameInterface` / `TransformableAudioFrameInterface` / `TransformedFrameCallback` / `FrameTransformerHost` が存在する
  - `api/rtp_sender_interface.h` に `RtpSenderInterface::SetFrameTransformer()` と `GenerateKeyFrame(rids)` が存在する
  - `api/rtp_receiver_interface.h` に `RtpReceiverInterface::SetFrameTransformer()` が存在する
- 一方、iOS ObjC API（ `sdk/objc/` ）には Encoded Transform のブリッジが存在しない
  - `RTCEncodedVideoFrame` / `RTCEncodedAudioFrame` / `RTCFrameTransformer` は存在しない
  - FrameEncryptor / FrameDecryptor の公開 ObjC API も存在しない（ `RTCRtpSender+Native.h` / `RTCRtpReceiver+Native.h` の内部 C++ ブリッジのみ）
- 受信側の `sendKeyFrameRequest` に相当するネイティブ API は存在しない。Sora は SFU でありキーフレーム要求はサーバー側の自動 PLI/FIR で管理されるため、初版では提供しない方針とする
- 参考実装として sora-python-sdk が同機能を提供している（C++ 実装で libwebrtc の C++ API を直接利用）。 `src/sora_frame_transformer.h` の `SoraFrameTransformerInterface` / `SoraTransformableFrame` が参照実装となる

## 設計方針

### 案 A: FrameEncryptor / FrameDecryptor ベース（SDK のみで完結）

- iOS の公開 ObjC API に FrameEncryptor / FrameDecryptor が存在しないため、パッチなしでは実現できない（Android の案 A と異なり SDK のみでは完結しない）
- フレーム全体の置き換え（暗号化）のみ実現できる。メタデータ改変とキーフレーム制御はできない
- 推奨しない

### 案 B: FrameTransformer の ObjC API をパッチで追加（webrtc-build 変更）— 推奨

- shiguredo-webrtc-build に ObjC パッチを追加し、MDN の機能をほぼ完全に再現する（ `h265_ios.patch` と同方式）
- 追加する ObjC API（案）:
  - `RTCEncodedVideoFrame` / `RTCEncodedAudioFrame`（ `TransformableFrameInterface` のラップ）
  - `RTCFrameTransformer`（protocol、transformFrame + enqueueFrame）
  - `RTCRtpSender.frameTransformer` / `RTCRtpReceiver.frameTransformer`
  - `RTCRtpSender.generateKeyFrame(rids)`
- ネイティブ側には `FrameTransformerInterface` の ObjC 実装（ `RTCFrameTransformerInterface` ）を追加する
- SDK 側は `Configuration` に frame transformer を渡す公開 API を追加し、 `PeerChannel` の sender / receiver に適用する
- ビデオ・オーディオ両対応とする
- libwebrtc の更新と同時にリリースされる

### 実装上の注意点（案 B を選定した場合）

- ネイティブの `Transform()` は worker スレッドから呼ばれるため、コールバックは適切なキューにディスパッチすること（デッドロック・ブロックを避ける）
- 変換後のフレームは元の順序を保ち、重複なく返すこと（MDN の記事にも明記されている）
- `TransformableFrameInterface` のバッファはネイティブ所有メモリの参照であるため、ObjC 側にはコピーして渡すこと（UAF 回避）
- 送信側の transform はシミュラカストの rid ごとに呼ばれるため、 `RTCEncodedVideoFrame` に rid を含めること
- Audio は `RegisterTransformedFrameCallback`（default）、Video は `RegisterTransformedFrameSinkCallback`（SSRC ごと）と登録方法が異なるため、両方に対応すること
- re-offer / update で transceiver が再構成される場合に transform が外れないよう、 `PeerChannel` のライフサイクルに組み込むこと（sora-python-sdk は `OnSetOffer` のたびに再適用している）
- 破棄時は `StartShortCircuiting` で安全化すること
- Sora は SFU であるため、transform はクライアント側のみで完結し、サーバー側の変更は不要である

## 完了条件

- 案 A / 案 B のどちらで実装するかが決定していること
- 決定した案の実装 issue（webrtc-build パッチ、SDK 実装、テスト、ドキュメント）が分割起票されていること

## 解決方法

（未定。完了条件を満たす設計判断を行う。）
