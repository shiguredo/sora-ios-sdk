# libwebrtc を m156.8078.5.1 に更新する

- Created: 2026-10-26
- Completed: {YYYY-MM-DD}
- Branch: feature/update-libwebrtc-m156
- Polished: 2026-10-26

## 目的

現在の libwebrtc m155.8059.4.1 を、m156 系の最新ビルドである m156.8078.5.1 に更新する。

m156 には、SDK の録音制御・受信映像・SDP 交渉に影響する変更が入っている。上流の修正を取り込み、m156 上で SDK が回帰なく動作することを確認する。WebRTC.xcframework を前提とした更新であり、libwebrtc_c.xcframework への移行 (`issues/0070-change-migrate-to-webrtc-c-xcframework.md`) とは別に扱う。

## 現状

- `Package.swift` の `libwebrtcVersion` は `m155.8059.4.1` で、`binaryTarget` の `WebRTC` は `WebRTC.xcframework.zip` の checksum `dd76daf2045629e8c56d029ab42cb8041578f0b07d255a7b65a7180239ed5869` を参照している。
- `Sora/PackageInfo.swift` の `WebRTCInfo` は `M155` / `8059` / `4` / `1` / `5bd86a2f17a35dfc986b87d058f511e45805bd1d` である。
- `README.md` の libwebrtc バッジは `155.8059` で、`skills/sora-ios-sdk/SKILL.md` は `m155.8059.4.1` を参照している。
- `CHANGES.md` の `2026.4.0` に m155.8059.4.1 への更新が記録されている。

m155.8059.4.1 は `M155.8059@{#4}` (2026-10-05 ビルド) である。M156 ブランチだけに入っている `@#3` から `@#5` の修正 (VP8 の破損フレーム拒否、`SetDecoders()` のデコーダー再利用) は含まない。

m156.8078.5.1 は `M156.8078@{#5}` (2026-10-21 ビルド) である。`WebRTC.xcframework.zip` は 487,279,952 bytes、SHA-256 は `c98b26dcd21d7eda49ffb819c2f7ac3fd9344e6b26efe54e52e9a3e4032787a2`。

上流の `sdk/objc` では、m155.8059.4.1 と m156.8078.5.1 の間に公開ヘッダーの差分はなく、差分は `RTCPeerConnectionFactory.mm` と `RTCAudioSession.mm` の実装だけである。iOS 向け webrtc-build パッチも、`ios_audio_pause_resume.patch` の `runOnWorker` の実装以外は追加行・削除行が同一である。

## 変更点と影響範囲

| 変更 | 該当する SDK の箇所 | 影響 |
| --- | --- | --- |
| 専用 worker thread の廃止 (`57b98b1c`) | `AudioDeviceModuleWrapper.runOnWorker(_:)`、`NativePeerChannelFactory.init` | 録音の pause / resume が network thread 上で実行される。API と呼び出し経路は変わらない |
| `SetDecoders()` のデコーダー再利用 (`ce13eaa8`、`2a990ce0`) | `PeerChannel.createAndSendReAnswer(forReOffer:)`、`PeerChannel.createAndSendReAnswerOverDataChannel(forReOffer:)` | re-offer 時のデコーダー再生成とキーフレーム要求が減る |
| VP8 の破損フレーム拒否 (`3987dfb7`) | 受信 VP8 のデコード経路 | パケットロス時に破損フレームを描画しない |
| ペイロードタイプの割り当て変更 (`c0704625`、`e406e165`、`63b4356a`、`3f38d050`、`74a0ae52`) | `NativePeerChannelFactory.createClientOfferSDP`、`PeerChannel.createAndSendReAnswer(forReOffer:)` | answer の PT が以前と変わり得る。SDK は PT を固定していない |
| 送信レイヤー数と send parameters (`7a24158d`、`c250ac75`、`d5535331`、`95fceffa`) | `PeerChannel.initializeSenderStream(mid:)`、`PeerChannel.updateSenderOfferEncodings()` | レイヤー数不一致で落ちず、未適用の parameters が保持される |
| ICE role の保持 (`c88c2392`) | `PeerChannel.createAndSendReAnswer(forReOffer:)` | ICE restart なしの renegotiation で role が反転しない |
| 音声 APM と task queue 優先度 (`a2a40432`、`63f7a75c`、`a98a2e87`、`af859639` など) | `PeerChannel.initializeAudioInput()`、`AudioDeviceModuleWrapper`、`MediaChannel.setAudioHardMute(_:)` | 音声品質と遅延が変わり得る。API は不変 |
| stats の media-playout (`fbfb49af`) | `MediaChannel.getStats(handler:)`、`MediaChannel.getStatsSnapshot(handler:)`、`MediaChannel.getStatsSnapshot()` | 音声を受信していないとき media-playout が現れない |
| Rust の corruption detection (`b32e4b35`) | RTP ヘッダー拡張の解析 (SDK からは不可視) | 挙動は従来と同じ。ビルドに Rust のコードが入る |

## 設計方針

- バージョン文字列、checksum、`WebRTCInfo`、README、CHANGES、SKILL.md を m156.8078.5.1 に揃える。
- SDK の振る舞いを変えるソースコード変更は行わない見込みとする (コメントの更新を除く)。専用 worker thread の廃止には webrtc-build の `ios_audio_pause_resume.patch` が追随済みで、SDK は既に `AudioDeviceModuleWrapper.runOnWorker(_:)` から `RTCPeerConnectionFactory.run(onWorker:)` を呼んでいる。
- 検証でコード変更が必要と判明した場合だけ、本 issue で修正する。
- m156 系の最新である m156.8078.5.1 を対象とし、m157.8103.0.0 は対象外とする。
- 同梱 `LICENSE.md` の差分を確認し、`THIRD_PARTY_LICENSES.md` に反映する。

## 完了条件

- `Package.swift`、`Sora/PackageInfo.swift`、`skills/sora-ios-sdk/SKILL.md` が m156.8078.5.1 を参照し、`README.md` の libwebrtc バッジが `156.8078` になっていること
- `WebRTC.xcframework.zip` の checksum が `Package.swift` の `checksum` と一致すること
- `make build` とユニットテストが成功すること
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功し、公開 API に差分がないこと
- 「検証内容」の各項目を実施し、結果と検証環境が「解決方法」に記録されていること
- `THIRD_PARTY_LICENSES.md` が新しい `LICENSE.md` の内容と一致していること
- `CHANGES.md` に m156.8078.5.1 への更新が記録されていること

## 解決方法

- `Package.swift` の `libwebrtcVersion` を `m156.8078.5.1` に変更し、`WebRTC` の `checksum` を新しい zip の SHA-256 に更新する。checksum はダウンロードした zip に対して `swift package compute-checksum` を実行して確定する。
- `Sora/PackageInfo.swift` の `WebRTCInfo` を `M156` / `8078` / `5` / `1` / `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d` に更新する。
- `README.md` の libwebrtc バッジを `156.8078`、リンクを `branch-heads/8078` に更新する。
- `skills/sora-ios-sdk/SKILL.md` の参照バージョンを `m156.8078.5.1` に更新する。
- `CHANGES.md` の `## develop` セクションに `[UPDATE] libwebrtc を m156.8078.5.1 に更新する` を追加し、利用者に影響する変更を補足する。
- 新しい `WebRTC.xcframework` の `LICENSE.md` を `THIRD_PARTY_LICENSES.md` と比較し、追加された `rust/cxx/v1`、`rust/foldhash/v0_2`、`rust_stdlib` と、`perfetto` の path の不一致を反映する。
- `AudioDeviceModuleWrapper`、`NativePeerChannelFactory`、`SoraTests/AudioDeviceModuleWrapperTests.swift` にある m155 を前提にしたコメントが m156 でも正しいかを確認し、必要なら worker thread が network thread を兼ねる旨を追記する。
- 「検証内容」を実施し、結果を「解決方法」に記録する。コード変更が必要になった場合は、その内容も記録する。

## 検証内容

### 1. ビルドとメタデータ

- `swift package resolve` で m156.8078.5.1 の zip を取得でき、checksum が一致すること
- `.build/artifacts` の `WebRTC.xcframework/build_info.json` が `M156` / `5` / `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d` / `1` であること
- `make build` が成功すること
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること

### 2. 録音の pause / resume (worker thread)

- `SoraTests/AudioDeviceModuleWrapperTests.swift` が成功すること
- `SoraTests/StereoAudioOutputE2ETests.swift` の `setAudioHardMute` が成功すること
- 実機で `initialMicrophoneEnabled = false` として接続し、`MediaChannel.setAudioHardMute(false)` でマイクが復帰すること
- 実機で `MediaChannel.setAudioHardMute(true)` と `false` を繰り返し、録音インジケーターと音声送信が追随し、失敗しないこと

### 3. ステレオ

- `SoraTests/StereoAudioSDPTests.swift`、`SoraTests/StereoAudioOutputTests.swift`、`SoraTests/StereoAudioOutputE2ETests.swift` が成功すること
- 実機で `audioStereoOutputEnabled = true` の送受信ができ、`bypassVoiceProcessing` との組み合わせで SDP と音声が期待どおりになること

### 4. Simulcast と送信パラメーター

- `SoraTests/SimulcastE2ETests.swift` が成功すること
- answer に 3 層の rid が反映され、`degradationPreference` / `networkPriority` が `sender.parameters` に残ること (`adaptivePtime` は SDK に設定 API が無いため対象外)
- 帯域制限でレイヤーが落ちても切断しないこと

### 5. re-offer とスポットライト

- `SoraTests/PeerChannelRedirectInvalidationTests.swift` の re-offer 経路が成功すること
- 実サーバーでスポットライトの切り替えなど re-offer が発生する操作を行い、映像が止まらないこと
- 受信コーデックが変わってもデコードが継続し、キーフレーム要求が増えていないこと
- ICE が disconnected / failed にならないこと

### 6. コーデック

- VP8 / VP9 / AV1 / H.264 / H.265 の送受信が成功すること
- VP8 でパケットロスを発生させ、破損フレームを描画しないこと
- re-offer 後に受信コーデックが切り替わってもデコードが継続すること

### 7. 音声

- 音声の送受信とステレオ、AEC / AGC の効き、遅延に問題がないこと
- ミュート / 解除、手動音声 (`usesManualAudio`)、AudioSession の割り込みが従来どおり動作すること

### 8. 統計

- `SoraTests/StatisticsSnapshotE2ETests.swift` が成功すること
- 音声を受信していない状態で `media-playout` が現れないこと

### 9. E2E 全体

- `.github/workflows/e2e-test.yml` と同じ手順 (iPhone 17 Pro Simulator、OS 26.5) で E2E を実行し、成功すること
- 自動テストで再現できない項目は手動確認とし、端末、iOS、Xcode、Sora のバージョンを記録すること

## 参考

- [webrtc-build m156.8078.5.1](https://github.com/shiguredo-webrtc-build/webrtc-build/releases/tag/m156.8078.5.1)
- [webrtc-build の VERSION](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/m156.8078.5.1/VERSION)
- [webrtc-build の CHANGES.md](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/master/CHANGES.md)
- [57b98b1c: sdk: Stop using a distinct worker thread](https://webrtc.googlesource.com/src/+/57b98b1c)
- [3987dfb7: Reject corrupted frames in the VP8 video decoder](https://webrtc.googlesource.com/src/+/3987dfb7)
- [ce13eaa8: Avoid reusing released decoders after SetDecoders()](https://webrtc.googlesource.com/src/+/ce13eaa8)
- [2a990ce0: Keep unchanged video decoders across SetDecoders()](https://webrtc.googlesource.com/src/+/2a990ce0)
