# offer の encodings の networkPriority を RTCRtpEncodingParameters に反映する

- Priority: Medium
- Created: 2026-06-03
- Completed: 2026-07-02
- Model: Opus 4.8
- Branch: feature/add-network-priority-to-rtp-encoding
- Polished: 2026-06-05
- Reporter: @zztkm

## 目的

offer メッセージの `encodings` （サイマルキャストの各エンコーディング設定）に含まれる `networkPriority` を、送信側の `RTCRtpEncodingParameters` に反映できるようにする。現状の SDK はこの値を読み捨てており、指定したネットワーク優先度（DiffServ Code Point）がエンコーディングに反映されない。

なお `networkPriority` による DSCP マーキングを有効にするには `RTCConfiguration.enableDscp` が `true` である必要があるが、 `enableDscp` の設定追加は本 issue のスコープ外とする。本 issue はあくまで Sora から受信した `networkPriority` 値を `RTCRtpEncodingParameters` に反映することを目的とする。

## 依存関係

本 issue と `0031` (`issues/0031-investigate-offer-encodings.md`, Low) はいずれも `updateOfferEncodings(_:)` を変更する。本 issue (Medium) が優先されるため本 issue を先に進め、 `0031` は本 issue のマージ後に rebase して追従する。

## 優先度根拠

Medium とする。 `encodings` に `networkPriority` が含まれる場合に SDK がこれを反映しないと、指定が無視され意図したネットワーク優先度が適用されない。一方で `maxBitrate` / `scaleResolutionDownBy` などと同様に既存の反映処理へ 1 項目追加するだけのため対応範囲は限定的であり、既存機能の不具合ではないため High ではない。

## 現状

`SignalingOffer.Encoding` （ `Sora/Signaling.swift:389` ） に `networkPriority` プロパティが存在しない。 `Codable` 実装 （ `Sora/Signaling.swift:1070` ） の `CodingKeys` にも `networkPriority` がなく、デコード処理にも含まれていない。

エンコーディングの更新は `updateOfferEncodings(_:)` （ `Sora/PeerChannel.swift:1500` ） のみを経由する。 `Sora/Signaling.swift:412` の `rtpEncodingParameters` computed property は公開 API として定義されているが SDK 内部からは呼ばれておらず、実際の反映は `updateOfferEncodings(_:)` だけを通じて行われる。同メソッドでも `networkPriority` は設定していない。

WebRTC 側には `RTCRtpEncodingParameters.networkPriority` （型: `RTCPriority`、値: `RTCPriorityVeryLow` / `RTCPriorityLow` / `RTCPriorityMedium` / `RTCPriorityHigh` ）が存在する。現行の libwebrtc バージョン（ `Package.swift` の `libwebrtcVersion` ）において `RTCRtpEncodingParameters.networkPriority` が公開 API として利用可能であることは、xcframework のヘッダー `RTCRtpEncodingParameters.h` で確認できる。

`RTCRtpEncodingParameters.networkPriority` は Obj-C の nonnull プロパティであり、 `RTCRtpEncodingParameters()` を新規生成した時点で既定値が設定されている。このため Swift 側では `RTCPriority` は Optional ではない型として扱われ、 `nil` 代入や `nil` 判定ができない。値の反映は `if let value = encoding.networkPriority { ... }` のように Optional でガードした上でのみ行い、 `nil` の場合は `RTCRtpEncodingParameters` 側のプロパティに触れない方針とする。

`RTCConfiguration.enableDscp` は現行の `WebRTCConfiguration.swift` で設定されておらず、デフォルトの `false` のままである。 `networkPriority` の設定が実際に DSCP マーキングとして機能するかは `enableDscp` の値に依存するが、この設定の追加は本 issue のスコープ外とする。

## 実装内容

### Signaling.swift

- `SignalingOffer.Encoding` に `public let networkPriority: RTCPriority?` を追加した
- `CodingKeys` に `networkPriority` を追加し、 JSON の `"very-low"` / `"low"` / `"medium"` / `"high"` を `RTCPriority` へ変換するデコード処理を追加した
- 未知の文字列や空文字列は `nil` として扱い、 `Logger.warn(type: .signaling, message: "unknown networkPriority value: ...")` を出力するようにした
- `rtpEncodingParameters` に `networkPriority` の反映を追加した
  - `networkPriority == nil` の場合は `params.networkPriority` に触れず、 `RTCRtpEncodingParameters()` の既定値 (`.low`) を維持する

### PeerChannel.swift

- `updateOfferEncodings(_:)` に `networkPriority` の反映を追加した
- `RTCPriority` の `CustomStringConvertible` 実装を追加し、デバッグログで `"very-low"` / `"low"` / `"medium"` / `"high"` を出力するようにした
- 既存の `RTCDegradationPreference` の `switch` も `@unknown default` に統一した

### SoraTests/SignalingOfferEncodingTests.swift

- `networkPriority` のデコードテストに空文字列ケースを追加した
- `rtpEncodingParameters.networkPriority` のテストを、 `nil` 比較ではなく `RTCRtpEncodingParameters()` の既定値比較へ修正した
- `RTCPriority.description` のテストを維持し、ログ出力用の文字列表現を確認できるようにした

### CHANGES.md

```md
- [ADD] offer の encodings の networkPriority を RTCRtpEncodingParameters に反映する
  - SignalingOffer.Encoding に networkPriority: RTCPriority? プロパティを追加する
  - updateOfferEncodings と rtpEncodingParameters で networkPriority を反映する
  - @zztkm
```

## 変更ファイル一覧

- `Sora/Signaling.swift` — `networkPriority` プロパティ、デコード処理、 `rtpEncodingParameters` 反映を追加
- `Sora/PeerChannel.swift` — `networkPriority` のログ文字列表現と sender 反映を追加
- `SoraTests/SignalingOfferEncodingTests.swift` — デコード / 既定値比較テストを更新
- `CHANGES.md` — ADD エントリを更新
