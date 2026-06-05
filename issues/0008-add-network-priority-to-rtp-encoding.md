# offer の encodings の networkPriority を RTCRtpEncodingParameters に反映する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-network-priority-to-rtp-encoding

## 目的

offer メッセージの `encodings`（サイマルキャストの各エンコーディング設定）に含まれる `networkPriority` を、送信側の `RTCRtpEncodingParameters` に反映できるようにする。現状の SDK はこの値を読み捨てており、指定したネットワーク優先度（DiffServ Code Point）がエンコーディングに反映されない。

## 依存関係

本 issue と `0031-investigate-offer-encodings` は、いずれも `updateOfferEncodings(_:)` を変更する。本 issue は同メソッドに `networkPriority` の反映を追加し、`0031-investigate-offer-encodings` は同メソッドのワークアラウンド除去を検討するため、実装が衝突する。どちらかを先に進め、もう一方はその差分に追従すること。

## 優先度根拠

Medium とする。`encodings` に `networkPriority` が含まれる場合に SDK がこれを反映しないと、指定が無視され意図したネットワーク優先度が適用されない。一方で `maxBitrate` / `scaleResolutionDownBy` などと同様に既存の反映処理へ 1 項目追加するだけのため対応範囲は限定的であり、既存機能の不具合ではないため High ではない。

## 現状

offer の各エンコーディングは `SignalingOffer.Encoding` として受信するが、`networkPriority` に相当するプロパティが存在しない。

```swift
public struct Encoding {
  /// エンコーディングの有効・無効
  public let active: Bool

  /// RTP ストリーム ID
  public let rid: String?

  /// 最大ビットレート
  public let maxBitrate: Int?

  /// 最大フレームレート
  public let maxFramerate: Double?

  /// 映像解像度を送信前に下げる度合
  public let scaleResolutionDownBy: Double?

  /// エンコーディングを制限する最大のサイズ
  public let scaleResolutionDownTo: RTCResolutionRestriction?

  /// scalability mode
  public let scalabilityMode: String?
```

`Sora/Signaling.swift:389`

`RTCRtpEncodingParameters` への初期反映は `rtpEncodingParameters` で行っているが、`networkPriority` は設定していない。

```swift
public var rtpEncodingParameters: RTCRtpEncodingParameters {
  let params = RTCRtpEncodingParameters()
  params.rid = rid
  if let value = maxBitrate {
    params.maxBitrateBps = NSNumber(value: value)
  }
  if let value = maxFramerate {
    params.maxFramerate = NSNumber(value: value)
  }
  if let value = scaleResolutionDownBy {
    params.scaleResolutionDownBy = NSNumber(value: value)
  }
  if let value = scaleResolutionDownTo {
    params.scaleResolutionDownTo?.maxWidth = value.maxWidth
    params.scaleResolutionDownTo?.maxHeight = value.maxHeight
  }
  params.scalabilityMode = scalabilityMode
  return params
}
```

`Sora/Signaling.swift:412`

re-offer 等でエンコーディングを更新する `updateOfferEncodings(_:)`（`Sora/PeerChannel.swift:1484` 付近）でも `networkPriority` は設定していない。

WebRTC 側には反映先が存在する。`RTCRtpEncodingParameters.networkPriority`（型 `RTCPriority`、値は `RTCPriorityVeryLow` / `RTCPriorityLow` / `RTCPriorityMedium` / `RTCPriorityHigh`）が利用できる。

## 設計方針

1. `SignalingOffer.Encoding` に `networkPriority` を表すプロパティを追加する。`encodings` に含まれない場合を考慮しオプショナルとする。
2. `Encoding: Codable` の `CodingKeys` に `networkPriority` を追加し、`init(from:)` で `decodeIfPresent` する。`encodings` の文字列値（`"very-low"` / `"low"` / `"medium"` / `"high"` を想定）を `RTCPriority` へ変換するヘルパーを実装する。値の正確な文字列表現は確定後に合わせる。
3. `rtpEncodingParameters` と `updateOfferEncodings(_:)` の両方で、値が存在する場合のみ `params.networkPriority` / `oldEncoding.networkPriority` に設定する。
4. 後方互換性: プロパティはオプショナルとし、値が無い場合は何も設定しない。これにより既存挙動を変えない。

## 完了条件

- offer の `encodings[].networkPriority` がデコードされ、`SignalingOffer.Encoding` に保持されること。
- 初期エンコーディング生成（`rtpEncodingParameters`）で `networkPriority` が `RTCRtpEncodingParameters` に反映されること。
- re-offer 時の更新（`updateOfferEncodings(_:)`）でも `networkPriority` が反映されること。
- 値が存在しない場合は従来どおり `networkPriority` を変更しないこと。
- 文字列から `RTCPriority` への変換と `RTCRtpEncodingParameters` への反映を検証するテストを追加すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] offer の encodings の networkPriority を RTCRtpEncodingParameters に反映する
    - @担当者
  ```

## 解決方法
