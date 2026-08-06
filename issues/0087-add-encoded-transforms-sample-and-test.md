# WebRTC Encoded Transforms 対応のサンプルアプリと E2E テスト

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms

## 目的

WebRTC Encoded Transforms のサンプルアプリと E2E テストを追加し、機能の動作確認と回帰防止を実現する。

## 現状

- サンプルアプリ（sora-ios-sdk-samples）に Encoded Transform のサンプルは存在しない
- E2E テスト（SoraTests/SignalingE2ETests.swift）に Encoded Transform のテストは存在しない
- 前提として 0085（webrtc-build パッチ + リリース）と 0086（SDK API 追加）の完了が必要

## 設計方針

### サンプルアプリ

- VideoChat に Encoded Transform のサンプルを追加する
- H264 フレームへの SEI 追加を実装する（sora-python-sdk の利用例と同様。NAL ユニットの付加）
- 送信側（sendonly / sendrecv）と受信側（recvonly / sendrecv）の両方で利用できるようにする

### E2E テスト

- sendonly でフレーム変換 → recvonly で受信確認のテストを追加する
  - Video: H264 SEI 追加の確認
  - Audio: フレームデータ変換の確認
- 変換後のフレームが順序を保ち、重複なく返されることを確認する

### ドキュメント

- CHANGES.md の develop セクションにエントリを追加する

## 完了条件

- サンプルアプリで Encoded Transform が動作すること（SEI 追加の確認）
- E2E テスト（ビデオ・オーディオ）が追加され、通ること
- CHANGES.md の develop セクションにエントリが追加されていること

## 解決方法

（未定）
