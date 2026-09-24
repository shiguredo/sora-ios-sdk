# WebRTC Encoded Transforms 対応の Sora iOS SDK API 追加

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms
- Polished: 2026-09-24

## 目的

WebRTC Encoded Transforms を Sora iOS SDK の公開 API として提供し、エンドツーエンド暗号化・フレーム改変（SEI 付加等）をアプリケーション側から実現できるようにする。

## 現状

- `Configuration`（ `Sora/Configuration.swift` ）にフレーム変換のフックは存在しない
- `PeerChannel` は transceiver 経由で sender を操作している。送信初期化は `Sora/PeerChannel.swift` の `initializeSenderStream(mid:)` で行い、`nativeChannel.transceivers` を mid で検索して `audioTransceiver.sender` / `videoTransceiver.sender` に track を設定している
- 受信ストリームは `RTCPeerConnectionDelegate` の `peerConnection(_:didAdd:)` で `BasicMediaStream` として追加され、`MediaChannelHandlers.onAddStream`（ `Sora/MediaChannel.swift` ）でアプリケーションへ通知される。`nativeChannel.receivers` は `finishConnecting()`（ `Sora/PeerChannel.swift` ）のデバッグログでのみ参照されている
- 前提として 0085（webrtc-build パッチ + リリース）の完了が必要。0085 の ObjC API（ `RTCFrameTransformer` / `RTCFrameTransformerDelegate` / `RTCEncodedVideoFrame` / `RTCEncodedAudioFrame` / `RTCRtpSender.frameTransformer` / `RTCRtpReceiver.frameTransformer` ）を前提とし、フレームデータの差し替え（SetData 相当）が 0085 の ObjC API に含まれることを前提とする
- 0085 と同様、本 issue は現行 WebRTC.xcframework 向けの暫定対応である。0070（WebRTC.xcframework から libwebrtc_c.xcframework への完全移行、open）の進行次第で再評価する。新規の公開 API に raw WebRTC 型（ `RTCRtpSender` / `RTCRtpReceiver` / 0085 の ObjC 型など）を露出しない（0057 と同じ方針）

## 設計方針

sora-python-sdk の API 設計を移植する（ビデオ・オーディオ両対応）。

- 送信側: `Configuration` に `videoFrameTransformer` / `audioFrameTransformer` を追加して接続時に設定する
- 受信側: トラックではなく、アプリケーションが `MediaChannelHandlers.onAddStream` で受け取る `MediaStream` に対して設定する（sora-python-sdk の `SoraMediaTrack.set_frame_transformer` が `RtpReceiverInterface::SetFrameTransformer` を呼ぶのと同じ対応。`src/sora_track_interface.h` の `SoraMediaTrack::SetFrameTransformer` を参照）
- frame transformer は `ConnectionConfigurationSnapshot`（Sendable、 `Sora/ConnectionConfigurationSnapshot.swift` ）には含めない。`MediaChannel` の designated init（ `init(snapshot:configuration:audioDevice:)` ）で `audioDevice` と同様に snapshot とは別に受け取り、`PeerChannel` へ引き渡す（0057 の `Configuration.videoProcessor` と同じ扱い）
- コールバックの実行契約は sora-python-sdk と同じ:
  - コールバックは libwebrtc のワーカースレッドから呼ばれる（0085 の doc コメントと同じ契約）
  - フレームデータはコピーで渡るため、加工したデータをフレームへ入れ替える
  - `enqueue()` 後はフレームの所有権がライブラリに移るため、再利用しない

### 公開 API（案）

- `Configuration` に `videoFrameTransformer` / `audioFrameTransformer` を追加する
  - 型は SDK 定義のクロージャーとし、0085 の `RTCFrameTransformer` / `RTCFrameTransformerDelegate` を内部アダプタで包む（ `SoraRTCAudioSessionDelegateAdapter`（ `Sora/Sora.swift` ）と同じパターン。raw WebRTC 型は露出しない）
  - コールバック内の基本形: フレームデータの取得（0085 の API ではコピーが渡る）→ 加工 → データ入れ替え → `enqueue(frame)` でストリームへ戻す（sora-python-sdk の `on_transform` / `SoraTransformableFrame` / `enqueue` と同じ流れ）
  - コールバックへは enqueue 手段（0085 の `RTCFrameTransformer` を包んだ SDK 型）も渡す
  - コールバックはワーカースレッドから呼ばれるため、必要なキューへのディスパッチはアプリケーション側で行う（SDK はディスパッチしない）
- `MediaStream` に受信側の設定 API（ `setVideoFrameTransformer` / `setAudioFrameTransformer`、または `setFrameTransformer` の 1 メソッド）を追加する
  - 呼び出し時点で対応する `RTCRtpReceiver` に設定する（ `nativeChannel.receivers` から対象 track の receiver を特定する）

### PeerChannel への適用

- 送信: `initializeSenderStream(mid:)` 内で `audioTransceiver.sender` / `videoTransceiver.sender` に `frameTransformer` を設定する
  - 新規 offer では `createAndSendAnswer` が `nativeChannel` を再生成し、`createAnswer(initialOffer: true)` 経由で `initializeSenderStream(mid:)` が再実行されるため、transform は再適用される
  - re-offer / update（ `createAndSendReAnswer` / `createAndSendUpdateAnswer` ）では同じ `RTCPeerConnection` の transceiver / sender を使い続けるため、一度設定すれば維持される
  - sora-python-sdk の `OnSetOffer` パターン（ `src/sora_connection.cpp` の `OnSetOffer` で `SetFrameTransformer` を再適用）の目的である「transform が外れないようにする」は、上記の 2 点で実現する
- 受信: `MediaStream` の設定 API 呼び出し時に対応する `RTCRtpReceiver` に設定する

### 提供しない機能（初版）

- `sendKeyFrameRequest`（受信側キーフレーム要求）: ネイティブ API が存在しないため提供しない。Sora は SFU でありサーバー側の自動 PLI/FIR で管理される

## 完了条件

- 公開 API（送信側: `Configuration`、受信側: `MediaStream`）が追加されていること
- `PeerChannel` で sender / receiver に `frameTransformer` が設定され、新規 offer による `nativeChannel` の再生成後も維持されること
- `Package.swift` の `libwebrtcVersion` が Encoded Transforms 対応のリリースに更新されていること
- ビデオ・オーディオ両対応であること
- 新規の公開 API に raw WebRTC 型が露出していないこと（0070 との整合）
- 既存のテストが通ること（SoraTests の全テスト。件数は固定しない）
- 公開 API の追加に伴い、`make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が通ること（CODEBASE.md の運用に従う）
- `skills/sora-ios-sdk/SKILL.md` に利用方法が記載されていること

## 解決方法

（未定）
