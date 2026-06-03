# type: offer の encodings 設定処理がリファクタ可能か調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-offer-encodings

## 目的

Sora から `type: offer` で受け取った `encodings` を sender の `RtpParameters` に反映する処理に、過去のワークアラウンドと思われるコードがある。`active`（`is_active`）が素直に反映されなかった経緯で `parameters` を毎回コピーして丸ごとセットし直す実装になっている。WebRTC の `RtpSender.setParameters` には反映条件（後述）があり、現在の実装がその制約に抵触していないか、ワークアラウンドが今も必要かを調査し、不要であればリファクタリングする。

## 依存関係

本 issue と `0008-add-network-priority-to-rtp-encoding` は、いずれも `updateOfferEncodings(_:)` を変更するため実装が衝突する。本 issue でワークアラウンドの構造を変更すると `0008-add-network-priority-to-rtp-encoding` の追加箇所がずれる。どちらかを先に進め、もう一方はその差分に追従すること。

## 優先度根拠

- 現状の実装で動作はしている。まず調査が主目的であり、ユーザー影響のある不具合報告ではないため Low とする。

## 現状

answer 生成時に offer の encodings を保持し、各 sender に対して反映している。

```swift
// Sora/PeerChannel.swift:800
sender.updateOfferEncodings(oldEncodings)
// ...
// Sora/PeerChannel.swift:806
offerEncodings = offer.encodings
```

実際の反映処理は `extension RTCRtpSender` の `updateOfferEncodings(_:)` にある。`parameters` を都度コピーして上書きし、最後に書き戻している。

```swift
// Sora/PeerChannel.swift:1484
func updateOfferEncodings(_ encodings: [SignalingOffer.Encoding]) {
  Logger.debug(
    type: .peerChannel, message: "update offer encodings for sender => \(senderId)")

  // parameters はアクセスのたびにコピーされてしまうので、すべての parameters をセットし直す
  let newParameters = parameters  // コピーされる
  for oldEncoding in newParameters.encodings {
    // ...
    oldEncoding.isActive = encoding.active
    // rid / maxFramerate / maxBitrate / scaleResolutionDownBy /
    // scaleResolutionDownTo / scalabilityMode を上書き
    // ...
  }

  parameters = newParameters
}
```

WebRTC の `RtpSender::SetParameters`（`pc/rtp_sender.cc`）には以下の制約があり、これに抵触している可能性がある。

- transceiver が stopped でないこと
- sender が stopped でないこと
- sender の `getParameters`（`parameters` 取得）が事前に呼ばれていること
- 最後に `getParameters` した際の transaction_id と、設定しようとしている parameters の transaction_id が一致すること

現実装は `let newParameters = parameters` で都度取得した直後に同じオブジェクトへ書き戻しているため transaction_id 制約は満たしていると考えられるが、`active` が素直に反映されなかった当時の事象が、この制約のどれに起因していたのかが整理されていない。

## 設計方針

まず調査し、その結果に基づいてリファクタリングの可否を判断する。

- 調査項目
  - `active`（`is_active`）が素直に反映されなかった当時の事象が、`SetParameters` のどの制約に起因していたかを特定する。
  - 現在の libwebrtc バージョン（`Package.swift` の `libwebrtcVersion`）での `RtpSender::SetParameters` の挙動を WebRTC ソースで確認する。
  - `parameters` を丸ごとコピーして書き戻す現在の方式が必須か、個別フィールドのみの更新で足りるかを確認する。
- リファクタリング方針（調査の結果ワークアラウンドが不要と判明した場合）
  - `updateOfferEncodings` の処理を簡潔化する。可能なら `extension RTCRtpSender` の責務分割やログの整理を行う。
  - sender / transceiver が stopped のケースのガードを `updateOfferEncodings` の冒頭で明示的に入れることを検討する。
- 後方互換性: 反映される RtpParameters の最終結果（各エンコーディングの値）が変更前後で同一であることを担保する。挙動が変わるリファクタリングは行わない。

## 完了条件

- `active` が反映されなかった当時の事象の原因が `SetParameters` の制約のどれに該当するか特定され、issue に記録されていること。
- 現行 libwebrtc での `SetParameters` 制約を踏まえ、現在のワークアラウンドが必要か不要かが結論付けられていること。
- 不要と判明した場合は `updateOfferEncodings` がリファクタリングされ、反映結果が変更前後で同一であることが確認されていること。必要と判明した場合は、なぜ必要かをコメントとして該当箇所に明記すること。
- 既存のテストがすべて通ること。
- リファクタリングを行った場合は `CHANGES.md` の `## develop` セクションに `[UPDATE]`（または `misc`）エントリと担当者行を追記すること。

## 解決方法
