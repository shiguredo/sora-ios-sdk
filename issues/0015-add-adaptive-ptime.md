# adaptivePtime に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-adaptive-ptime
- Polished: 2026-06-05

## 目的

音声送信における adaptivePtime（適応的パケット化時間）を設定できるようにする。現行 libwebrtc（`Package.swift` の `libwebrtcVersion`）の iOS 向けヘッダー `RTCRtpEncodingParameters.h` に `@property(nonatomic, assign) BOOL adaptiveAudioPacketTime;` が公開 API として存在することを確認済みである。これを有効化することで音声送信のフレーム長を動的に変更できる。

## 優先度根拠

Medium とする。libwebrtc 側の API が利用可能であることを確認済みであり、音声品質や帯域効率に関わる機能追加であるため Medium が妥当である。緊急のバグ修正ではないため High ではない。

## 現状

iOS SDK には adaptivePtime を制御する API が存在しない。音声送信トランシーバーは `Sora/PeerChannel.swift:447` の `if let audioMid = mid["audio"]` ブロック内で構成されているが、`sender.parameters.encodings` の `adaptiveAudioPacketTime` を設定する処理がない。

映像向けには `degradationPreference` を `sender.parameters` 経由で設定するパターンが確立している（`Sora/PeerChannel.swift:501-508`）。音声向けも同様のパターンで実装できるが、`degradationPreference` が `Optional` 値であるのに対し、`adaptivePtimeEnabled` は `Bool` 値であるため、ガードの書き方が異なる（`if let` でなく `if configuration.adaptivePtimeEnabled { ... }` となる）。

## 設計方針

1. `Sora/Configuration.swift` に `var adaptivePtimeEnabled: Bool = false` を追加する（既存の `bypassVoiceProcessing: Bool = false` 等のパターンに倣う）。デフォルト `false` で後方互換を維持する。`Configuration.init` のシグネチャは変更しない。
2. `if let audioMid = mid["audio"]` ブロック末尾（`Sora/PeerChannel.swift:473` の `}` 直前）に、`configuration.adaptivePtimeEnabled` が `true` の場合の処理を追加する。映像向け `degradationPreference` パターン（501-508 行目）と同様に `let parameters = audioTransceiver.sender.parameters` でコピーを取得し、各 `encoding` の `adaptiveAudioPacketTime` を `true` に設定して `audioTransceiver.sender.parameters = parameters` と書き戻す。libwebrtc の Objective-C API では `parameters` プロパティはアクセスのたびにコピーを返すため、書き戻しは必須である（書き戻さないと変更が無視されるがエラーにもならない）。`encodings` が空配列の場合はループが空振りするだけで問題ない。`audioEnabled = false` の場合でも `sender.parameters.encodings` に要素があれば `adaptiveAudioPacketTime` が `true` に設定されるが、音声トラックが存在しないため実際には影響がなく正常動作として許容する。`initializeSenderStream()` の直後に `updateSenderOfferEncodings()`（744 行目）が呼ばれるが、`updateOfferEncodings(_:)` は rid によるマッチングで encoding を特定する。音声 sender の encoding は rid を持たないため、映像サイマルキャスト用の offer encodings（各 rid あり）とはマッチせず、`adaptiveAudioPacketTime` は上書きされない。
3. `initializeSenderStream(mid:)` は `createAnswer()` 内の `if isSender { if initialOffer { ... } }` ブロック（`Sora/PeerChannel.swift:740-743`）からのみ呼ばれるため、受信専用ロールではこの関数自体が呼ばれず、`adaptivePtimeEnabled` の設定処理も実行されない。これは意図した動作である。

## テスト方針

`Configuration.adaptivePtimeEnabled` のデフォルト値（`false`）と型（`Bool`）は純粋な値型のプロパティであり、以下をユニットテストで検証する:

- `Configuration(url: URL(string: "wss://sora.example.com/signaling")!, channelId: "channel-id", role: .sendonly)` で生成したインスタンスの `adaptivePtimeEnabled` デフォルト値が `false` であること。
- `adaptivePtimeEnabled = true` に設定した `Configuration` インスタンスで値が保持されること。

`sender.parameters.encodings` への反映は `RTCRtpSender` の実オブジェクトが必要なため、モック不使用制約下では単体テストが困難である。反映の確認は実機・シミュレータでの結合テストで行う。

テストの追加先は新規ファイル `SoraTests/ConfigurationTests.swift` を作成すること（`SoraTests/` 配下に `Configuration` 向けテストファイルは存在しない）。

## 完了条件

- `Configuration` に `adaptivePtimeEnabled: Bool = false` プロパティが追加されること。
- `adaptivePtimeEnabled` が `true` の場合、音声送信トランシーバーの `sender.parameters.encodings` 各エンコーディングの `adaptiveAudioPacketTime` が `true` に設定されること。
- `adaptivePtimeEnabled` が `false`（デフォルト）の場合、既存の挙動が変更されていないこと（後方互換）。
- テスト方針に記載したユニットテストが通ること。
- `CHANGES.md` の `develop` セクションに以下の形式で追記すること（担当者行は変更内容より 2 文字分インデントを下げた `- @voluntas`）:

```
- [ADD] `Configuration.adaptivePtimeEnabled` を追加して音声送信の adaptivePtime を設定できるようにする
  - @voluntas
```

## 解決方法
