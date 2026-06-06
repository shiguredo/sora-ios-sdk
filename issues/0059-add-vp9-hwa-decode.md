# VP9 ハードウェアアクセラレーションデコード対応

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-vp9-hwa-decode
- Polished:

## 概要

VP9 映像のデコードに VideoToolbox（VTDecompressionSession）を使ったハードウェアアクセラレーション（HWA）を適用し、CPU 負荷を低減する。

## 背景

WebKit リポジトリには `RTCVideoDecoderVTBVP9.mm` として VP9 の VideoToolbox デコーダーが実装されているが、libwebrtc 本体には含まれていない。

参考: https://github.com/WebKit/WebKit/blob/main/Source/ThirdParty/libwebrtc/Source/webrtc/sdk/objc/components/video_codec/RTCVideoDecoderVTBVP9.mm

現在の Sora iOS SDK では VP9 デコードはソフトウェアデコード（libvpx）となっており、高解像度・高フレームレートの VP9 映像受信時に CPU 負荷が高くなる。

## 対応方針

- WebKit の `RTCVideoDecoderVTBVP9.mm` を参考に、Sora iOS SDK 向けの VP9 HWA デコーダーを実装する
- libwebrtc のデコーダーファクトリー（`RTCVideoDecoderFactory`）に VP9 HWA デコーダーを登録する
- HWA が利用できない端末・OS バージョンではソフトウェアデコードにフォールバックする
- WebRTC-Build との連携が必要かどうか確認する

## 確認事項

- iOS における VP9 の VideoToolbox サポート対象 OS バージョンを確認する
- `RTCVideoDecoderVTBVP9.mm` の実装が現在の libwebrtc バージョンと互換性があるか確認する

## 根拠

VP9 は高圧縮効率のコーデックとして Sora でも広く使われているが、HWA なしのソフトウェアデコードは特にモバイル端末でのバッテリー消費・発熱に直結する。HWA 対応により受信性能と端末負荷が大幅に改善する。
