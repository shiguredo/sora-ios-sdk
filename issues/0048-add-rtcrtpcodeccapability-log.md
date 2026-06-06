# RTCRtpCodecCapability をログに出力する機能を追加する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-rtcrtpcodeccapability-log
- Polished:

## 概要

端末で利用可能なコーデック情報（`RTCRtpCodecCapability`）を、アプリ起動時や接続時にログへ出力できるようにする。

## 背景

現状ではどのコーデックが使用可能かを確認する手段がなく、コーデック関連のデバッグや動作確認が困難。利用可能なコーデックをログに出力することで、問題の切り分けが容易になる。

参考: https://webrtc-review.googlesource.com/c/src/+/333402

## 根拠

コーデック関連のバグ調査（`0039`、`0040` など）において、端末がどのコーデックをサポートしているかが分かることはデバッグの効率向上に直結する。

## 対応方針

- `RTCRtpSender.sendCapabilities(forKind:)` および `RTCRtpReceiver.receiveCapabilities(forKind:)` から音声・映像のコーデック一覧を取得してログに出力する
- 出力タイミングは接続処理の初期化時（`PeerChannel` の初期化時など）が適切
- ログレベルは DEBUG とする
