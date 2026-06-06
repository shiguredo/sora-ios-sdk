# VP9 ハードウェアアクセラレーションデコード対応

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-vp9-hwa-decode
- Polished: 2026-06-06

## 目的

VP9 映像のデコードに VideoToolbox を使ったハードウェアアクセラレーション（HWA）を適用し、モバイル端末での CPU 負荷・バッテリー消費・発熱を低減する。

## 優先度根拠

VP9 は Sora のデフォルトコーデック（`VideoCodec.default`）として広く使われており、HWA なしのソフトウェアデコード（libvpx）はモバイル端末でのバッテリー消費・発熱に直結する。webrtc-build 側の調査待ちで着手できない段階のため Low とする。

## 現状

`NativePeerChannelFactory.swift:51` で `RTCDefaultVideoDecoderFactory()` を引数なしで初期化している。この呼び出しでは VP9 の VideoToolbox HWA デコード（`supportsVP9VTB`）が無効になっており、VP9 デコードは libvpx ベースのソフトウェアデコードとなっている。

エンコーダー側は `WrapperVideoEncoderFactory`（`NativePeerChannelFactory.swift:50`）でカスタムラッパーが既に実装されているが、デコーダー側には対応するカスタムラッパーがない。

WebKit の `RTCDefaultVideoDecoderFactory` は `initWithH265:vp9Profile0:vp9Profile2:vp9VTB:av1:` イニシャライザを持ち、`vp9VTB:YES` を渡すことで VP9 の VideoToolbox HWA を有効化できる。しかし shiguredo-webrtc-build m148.7778.7.0 の WebRTC.xcframework がこのイニシャライザを公開しているかどうかは未確認である。

参考実装: https://github.com/WebKit/WebKit/blob/main/Source/ThirdParty/libwebrtc/Source/webrtc/webkit_sdk/objc/components/video_codec/RTCVideoDecoderVTBVP9.mm

### iOS での VP9 VideoToolbox HWA サポート範囲

- Apple A12 Bionic 以降（iPhone XS 以降）でのみ VP9 VideoToolbox HWA が利用可能
- SDK の最小サポートは iOS 14（`Package.swift` の `.iOS(.v14)` 設定による）
- iOS 14 対応端末でも A11 以前（iPhone X・iPhone 8 等）では HWA 不可、ソフトウェアフォールバックとなる

## 設計方針

以下の 2 アプローチを優先順位付きで確認し、pending 解除後に実装する。

### アプローチ A（SDK 側のみ、先に実現可否を確認すること）

shiguredo-webrtc-build m148.7778.7.0 の WebRTC.xcframework が `initWithH265:vp9Profile0:vp9Profile2:vp9VTB:av1:` イニシャライザを公開していれば、`NativePeerChannelFactory.swift:51` の初期化を変更するだけで webrtc-build への変更なしに対応できる。

イニシャライザの有無は xcframework のヘッダーで確認すること。確認手順の例:

```
find ~/Library/Developer/Xcode/DerivedData -name "RTCDefaultVideoDecoderFactory.h" 2>/dev/null
grep -n "initWith\|vp9VTB" <ヘッダーファイルのパス>
```

または `Package.swift` の `url` から WebRTC.xcframework.zip を直接ダウンロードし展開して確認する。

### アプローチ B（webrtc-build パッチ追加、アプローチ A が不可の場合）

shiguredo-webrtc-build に以下の変更を加えたパッチを作成し、新しい WebRTC.xcframework リリース後に `Package.swift` の `url` と `checksum` を更新する。

1. `RTCVideoDecoderVTBVP9.mm`（WebKit の実装を移植）をパッチとして追加する
2. `RTCDefaultVideoDecoderFactory.m` に VP9 VTB デコーダーを登録する変更を加える
3. `RTC_ENABLE_VP9` ビルドフラグが有効になっていることを確認する

アプローチ B を採用する場合、shiguredo-webrtc-build リポジトリへの別 issue を先行して起票し、xcframework のリリースが完了してから SDK 側の実装に着手すること（shiguredo org への書き込み権限が必要）。なお libwebrtc の将来バージョンアップ時にパッチの追従作業が必要になることも考慮すること。

## Pending 理由

以下の確認が完了していないため `issues/pending/` に移動する。

- shiguredo-webrtc-build m148.7778.7.0 の WebRTC.xcframework が `initWithH265:vp9Profile0:vp9Profile2:vp9VTB:av1:` を公開しているか（アプローチ A の可否を決定する）
- アプローチ A が不可の場合、shiguredo-webrtc-build への VP9 VTB パッチ追加の実現可能性

確認が完了したら次のいずれかのアクションに進む:

- アプローチ A が可能: `issues/` に戻し（reopen）、アプローチ A で実装に着手する
- アプローチ A が不可: shiguredo-webrtc-build に別 issue を起票し、xcframework リリース後に本 issue を reopen する

## 完了条件

- `NativePeerChannelFactory.swift:51` のデコーダーファクトリー初期化が VP9 VTB 対応版に変更されていること
- Apple A12 Bionic 以降の実機で VP9 映像受信時に VideoToolbox HWA が使用されること（Instruments の GPU フレームキャプチャ等で確認。シミュレーターでは確認不可）
- A11 以前の実機またはシミュレーターで VP9 映像受信が正常に動作すること（ソフトウェアフォールバック動作確認）
- アプローチ B を採用した場合は `Package.swift` の `url` と `checksum` が更新されていること
- `CHANGES.md` の `## develop` セクションに以下を追記すること

```
- [UPDATE] VP9 デコードに VideoToolbox ハードウェアアクセラレーションを使用するようにする
  - @voluntas
```
