# RTCVideoEncoderH264 がメモリから解放されない問題を調査する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/investigate-rtcvideoencoderh264-memory-leak
- Polished:

## 概要

`RTCVideoEncoderH264` インスタンスがメモリから解放されない問題（"never released from memory"）が報告されている。この問題が Sora iOS SDK の使い方において発生するかを調査する。

## 背景

WebRTC プロジェクトの Issue Tracker において `RTCVideoEncoderH264 never released from memory` として報告されている問題がある。

参考: https://bugs.chromium.org/p/webrtc/issues/detail?id=13763

現時点の Sora iOS SDK ではトラックの数が増減しないため、影響が出る可能性は低いと思われる。ただし再現条件に一致するケースがないか確認しておく必要がある。

## 調査内容

- `H.264 で送信設定して接続 → removeTrack でトラックを削除` の手順で再現するか確認する
- メモリプロファイラ（Instruments の Leaks / Allocations）で `RTCVideoEncoderH264` の解放を確認する
- 再現する場合、libwebrtc 側の問題か SDK 側の保持の問題かを切り分ける

## 根拠

メモリリークが蓄積するとアプリが OOM で終了するリスクがある。長時間接続・切断を繰り返す用途では特に問題になる可能性があるため、再現性の有無を確認しておく。
