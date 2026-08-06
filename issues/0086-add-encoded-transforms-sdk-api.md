# WebRTC Encoded Transforms 対応の Sora iOS SDK API 追加

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms

## 目的

WebRTC Encoded Transforms を Sora iOS SDK の公開 API として提供し、エンドツーエンド暗号化・フレーム改変（SEI 付加等）をアプリケーション側から実現できるようにする。

## 現状

- `Configuration` にフレーム変換のフックは存在しない
- `PeerChannel` は transceiver 経由で sender / receiver を操作している（送信初期化 `PeerChannel.swift:589-606` 、受信は `nativeChannel.receivers` を参照）
- 前提として 0085（webrtc-build パッチ + リリース）の完了が必要

## 設計方針

sora-python-sdk の API 設計を移植する（ビデオ・オーディオ両対応）。

### 公開 API（案）

- `Configuration` に `videoFrameTransformer` / `audioFrameTransformer`（protocol or closure）を追加
  - コールバック内で `frame.getData()` → 加工 → `frame.setData()` → `transformer.enqueue(frame)` の流れを基本形とする
  - コールバックは worker スレッドから呼ばれるため、適切なキューにディスパッチする
  - `getData()` はコピーされたデータを返すため、加工後に `setData()` で入れ替える
  - `enqueue()` 後はフレームの所有権がライブラリに移るため、再利用しない
- 受信側はトラックに対して `setFrameTransformer`（sora-python-sdk の `SoraMediaTrack.setFrameTransformer` 相当）

### PeerChannel への適用

- 送信: 送信初期化（ `audioTransceiver.sender` / `videoTransceiver.sender` ）に `frameTransformer` を設定
- 受信: トラック追加時に `audioTransceiver.receiver` / `videoTransceiver.receiver` に設定
- re-offer / update のたびに再適用（sora-python-sdk の `OnSetOffer` パターン踏襲。transform が外れないようにする）

### 提供しない機能（初版）

- `sendKeyFrameRequest`（受信側キーフレーム要求）: ネイティブ API が存在しないため提供しない。Sora は SFU でありサーバー側の自動 PLI/FIR で管理される

## 完了条件

- 公開 API（送信側: `Configuration`、受信側: トラック）が追加されていること
- `PeerChannel` で sender / receiver に `frameTransformer` が設定され、re-offer / update 後も維持されること
- `Package.swift` の `libwebrtcVersion` が Encoded Transforms 対応のリリースに更新されていること
- ビデオ・オーディオ両対応であること
- 既存のテスト（54 件）が通ること

## 解決方法

（未定）
