# Configuration.videoBitRate に大きい値を設定すると H.264 エンコーダーがクラッシュする

- Priority: High
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-h264-encoder-crash-high-bitrate
- Polished: 2026-06-06

## 目的

`Configuration.videoBitRate` に大きい値（例: 20000 kbps）を設定すると、iOS のハードウェア H.264 エンコーダーがエンコードエラーを起こしアプリがクラッシュする。H.264 は広く使われるコーデックであり、高ビットレート指定時に無条件でクラッシュするのは許容できないため修正する。

## 優先度根拠

エンコーダーのクラッシュはアプリ強制終了を引き起こす致命的な不具合。H.264 を使用して高ビットレートを指定したアプリが一切使用できなくなる。H.265 エンコーダーでは同値を設定してもクラッシュしないため、H.264 固有の問題として High とする。

## 現状

### 再現手順

```swift
// クラッシュする設定例
configuration.videoCodec = .h264
configuration.videoBitRate = 20000
configuration.cameraSettings = CameraSettings(resolution: .vga480p, frameRate: 30, position: .back)
```

```swift
// クラッシュしない設定例（ビットレートを下げた場合）
configuration.videoCodec = .h264
configuration.videoBitRate = 15000
configuration.cameraSettings = CameraSettings(resolution: .vga480p, frameRate: 30, position: .back)
```

### エラーログ

`Sora.setWebRTCLogLevel(.verbose)` を設定すると以下のエラーが出力される。

```
libwebrtc ERROR: (RTCVideoEncoderH264.mm:769): H264 encode failed with code: -12902
```

エラーコード `-12902` は VideoToolbox の `kVTVideoEncoderMalfunctionErr` に相当する可能性がある（OSStatus コード）。これはエンコードプロセスの失敗（エラーリターン）であり、`EXC_BAD_ACCESS` などとは異なる。アプリ強制終了に至る経路の詳細はスタックトレースで確認する必要がある。

### 確認済み環境

- iPad Pro 11-inch / iOS（バージョン要確認）
- iPad Pro 12.9-inch / iOS（バージョン要確認）
- libwebrtc M116、M119（現在の SDK は m148.7778.7.0 を使用しており、m148 での再現確認が必要）

### コードの実態

`Configuration.videoBitRate: Int?` は `SignalingConnect.videoBitRate` を経由してシグナリングメッセージとして送られ、libwebrtc 内部で `RTCVideoEncoderH264.mm` がエンコードパラメーターを受け取る。SDK 側にビットレートの上限チェックやキャップの実装は現在存在しない。端末によってクラッシュが発生する閾値が異なる可能性がある。

## 設計方針

1. 現在の libwebrtc m148.7778.7.0 環境で再現を確認する。再現しない場合は libwebrtc 更新で解決済みと判断して close する
2. 再現する場合はスタックトレースを取得し、アプリ強制終了に至る経路を特定する
3. iOS の HW H.264 エンコーダーが受け付けるビットレート上限を VideoToolbox ドキュメントまたは実機計測で確認する
4. SDK 側でビットレートの上限チェックまたはキャップを実装する。変更対象候補は以下の 2 箇所。API 公開面での早期バリデーションが目的なら `Configuration.swift` の `videoBitRate` プロパティ（現在は単純な格納のみでバリデーションなし）、Sora への送信直前での変換が目的なら `PeerChannel.swift` の `sendConnectMessage` 内の `SignalingConnect` 生成箇所（`Sora/PeerChannel.swift`）。あるいは libwebrtc 側の問題であれば libwebrtc へのパッチ報告または当該バージョンの更新対応とする

なお、`0052-investigate-rtcvideoencoderh264-memory-leak.md` は `RTCVideoEncoderH264` のメモリリーク調査 issue であり、本 issue とは問題の性質は異なるが同一コンポーネントの調査として libwebrtc 内部の実装挙動に関する知見を参照すること。

## 完了条件

- m148 環境で再現を確認すること（再現しない場合は close）
- 上記再現手順でアプリがクラッシュしなくなること
- H.265 および通常ビットレート（15000 kbps 以下）の H.264 接続に影響がないこと
- ビットレート上限の値とその根拠が本 issue の調査結果として追記されること、かつコードコメントにも上限値と根拠を記載すること
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] Configuration.videoBitRate に大きい値を設定すると H.264 エンコーダーがクラッシュする問題を修正する
  - @voluntas
```
