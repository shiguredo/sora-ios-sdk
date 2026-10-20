# WebRTC Encoded Transforms 対応のサンプルアプリと E2E テスト

- Priority: Medium
- Created: 2026-08-06
- Completed:
- Model: DeepSeek V4 Flash
- Branch: feature/add-encoded-transforms
- Polished: 2026-09-24

## 目的

WebRTC Encoded Transforms のサンプルアプリと E2E テストを追加し、機能の動作確認と回帰防止を実現する。

## 現状

- サンプルアプリ（sora-ios-sdk-samples の SamplesApp / VideoChat）に Encoded Transform のサンプルは存在しない
- E2E テスト（`SoraTests/` 配下のテスト種別ごとのクラスに分割されており、ベースクラスは `SoraTests/E2ETestBase.swift`。`SoraTests/SignalingE2ETests.swift` は 0089 の分割で存在しない）に Encoded Transform のテストは存在しない
- 前提として 0085（webrtc-build パッチ + リリース）と 0086（SDK API 追加）の完了が必要。0086 で追加される公開 API（送信側: `Configuration.videoFrameTransformer` / `audioFrameTransformer`、受信側: `MediaStream` への設定 API）を本 issue の実装で使用する

## 設計方針

### サンプルアプリ（sora-ios-sdk-samples）

- sora-ios-sdk-samples の VideoChat に Encoded Transform のサンプルを追加する（sora-ios-sdk-samples は別リポジトリであり、変更はそのリポジトリで行い、本 issue で管理する。0140 と同様の運用）
- 0054（samples に検証用途の機能を足さない）と 0167（samples を VideoChat 1 種類に集約する）の方針に従い、検証用の UI は追加せず、公開 API の利用例（実装の参考）として追加する
- 送信側: H264 フレームへの SEI 追加を実装する（sora-python-sdk の利用例と同様。H.264 の NAL ユニットを解析し、SEI NAL を付加する）
- 受信側: 受信したストリームに対して 0086 の受信側 API を設定し、受信側でも transform が動作する利用例を含める
- 送信側（sendonly / sendrecv）と受信側（recvonly / sendrecv）の両方で利用できるようにする

### E2E テスト

- `SoraTests/EncodedTransformsE2ETests.swift` を新設する（`E2ETestBase` を継承し、0075 の 2 クライアント接続パターンに倣う。分割後のクラスへ追加する方針は 0089 の実装結果に従う）
- sendonly でフレーム変換 → recvonly で受信確認のテストを追加する。一意な channelId で sendonly 1 台と recvonly 1 台を同一チャンネルに接続し、受信側の確認は 0086 の受信側 API に設定した transform で行う
  - Video: 送信側は `videoCodec = .h264` + DummyVideoCapturer とし、送信 transform で SEI 付加。受信側 transform で SEI NAL の存在を確認する
  - Audio: 送信側は DummyAudioDevice（0068 の方式）で音声を送信し、送信 transform でフレームデータを改変（例: 先頭バイトへのマーカー付加）。受信側 transform で改変を確認する
- 変換後のフレームが順序を保ち、重複なく返されることを確認する
  - 送信 transform でフレームごとに連番を付与し（SEI 内・音声ペイロード先頭）、受信側 transform で連番の重複が無いことを確認する
  - 受信は SFU 経由であり、ネットワークの再順序・欠落の影響を受け得るため、欠番・逆順をどう扱うかは実装時に定める（順序・重複の保証そのものは libwebrtc の変換パイプラインの契約であり、0085 の設計方針に基づく）
- 前提リスク: E2E テストの CI は Simulator のみで実行される（0077）。0077 では Simulator で H.265 エンコードが不能だったため、H.264 も Simulator で利用できない場合はビデオの E2E を実現できない。実装時に Simulator での H.264 エンコード可否を確認し、不可の場合は代替方針（VP8 でのフレーム改変に限定、または実機確認へ切り替え）を確定する

### ドキュメント

- `CHANGES.md` の `## develop` の `### misc` に E2E テスト追加のエントリを追加する（issue 番号は書かない。shiguredo-changelog に従う）
- sora-ios-sdk-samples の `CHANGES.md` にサンプル追加のエントリを追加する（0140 の完了条件と同じ扱い）

## 完了条件

- VideoChat に Encoded Transform のサンプル（送信側の SEI 付加と受信側の transform 設定例）が追加されていること
- サンプルアプリで Encoded Transform が動作すること（SEI 追加の確認）
- E2E テスト（ビデオ・オーディオ）が追加され、通ること（Simulator で H.264 が利用できない場合は、代替方針を本 issue に記録したうえでビデオの検証範囲を確定すること）
- 変換後のフレームが順序を保ち、重複なく返されることが E2E で確認できること（ネットワークの影響を受ける点とその扱いが実装時に確定していること）
- `CHANGES.md`（`### misc`）と sora-ios-sdk-samples の `CHANGES.md` にエントリが追加されていること

## 解決方法

（未定）
