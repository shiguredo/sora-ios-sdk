# RTCVideoEncoderH264 がメモリから解放されない問題を調査する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/investigate-rtcvideoencoderh264-memory-leak
- Polished: 2026-09-24

## 概要

`RTCVideoEncoderH264` インスタンスがメモリから解放されない問題（"never released from memory"）が報告されている。この問題が Sora iOS SDK の使い方において発生するかを調査する。

## 背景

WebRTC プロジェクトの Issue Tracker において `RTCVideoEncoderH264 never released from memory` として報告されている問題がある。

参考: https://issues.webrtc.org/42223987

現時点の Sora iOS SDK（libwebrtc m150.7871.3.5）ではトラックの数が増減しないため、影響が出る可能性は低いと思われる。ただし、H.264 を利用する接続では SDK は接続ごとに `RTCVideoEncoderH264` を生成し、切断時に `RTCPeerConnection` を close して解放するため、接続・切断を繰り返す用途で未解放が蓄積しないかを確認しておく必要がある。

## 現状

- Sora iOS SDK の公開 API には接続中のトラック追加・削除（`addTrack` / `removeTrack`）が存在しない。`MediaChannel` の公開 API に該当メソッドはなく、`MediaStream.videoEnabled` の切り替えはフレーム供給の停止でありトラックは残る
- 映像・音声トラックは `PeerChannel` の `initializeSenderStream` で生成され、offer 由来のトランスシーバーへ `sender.track` として割り当てられる。切断時は `PeerChannel` の `basicDisconnect` が `nativeChannel?.close()` で破棄する
- エンコーダーファクトリーは `Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory`（プロセス共有のシングルトン）で、H.264 は `RTCDefaultVideoEncoderFactory`（サイマルキャスト有効時は `RTCVideoEncoderFactorySimulcast` 経由）で選択される
- 本 issue が想定していた再現手順（トラック削除）は SDK の公開 API で実行できないため、SDK が実際に行うエンコーダーの生成・解放ライフサイクル（接続・切断）で確認する

## 調査内容

- `Configuration.videoCodec = .h264` で接続し、切断（`MediaChannel.disconnect`）完了後に Instruments の Leaks / Allocations で `RTCVideoEncoderH264` インスタンスの生成と解放（未解放の蓄積）を確認する。接続・切断を繰り返すシナリオと、`Configuration.simulcastEnabled` の true / false の組み合わせで実施する
- 未解放が蓄積する場合、libwebrtc 側の問題か SDK 側の保持の問題かを切り分ける。SDK 側の保持候補として `Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory`（プロセス共有シングルトン）と、切断経路の `PeerChannel.basicDisconnect` による `nativeChannel?.close()` を確認する

## 完了条件

- `Configuration.videoCodec = .h264` で接続した場合の `RTCVideoEncoderH264` の生成と解放が Instruments で確認でき、接続・切断を繰り返しても未解放が蓄積しないこと（`simulcastEnabled` の true / false の両方で確認）
- 未解放が蓄積する場合は、libwebrtc 側の問題か SDK 側の保持の問題かを切り分け、確認した libwebrtc バージョン（m150.7871.3.5）と実行環境・再現手順を本 issue に追記すること
- 調査結果（リーク有無、確認した環境、切り分け結果）を本 issue に記録すること

## 根拠

メモリリークが蓄積するとアプリが OOM で終了するリスクがある。長時間接続・切断を繰り返す用途では特に問題になる可能性があるため、再現性の有無を確認しておく。
