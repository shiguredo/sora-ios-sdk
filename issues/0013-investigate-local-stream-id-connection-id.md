# ローカルストリームの streamId に connectionId を設定できるか調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch:

## 目的

ローカルストリーム（送信側 sender）の streamId に、現状の `"mainStream"` 固定値ではなく Sora が発行した `connectionId` を設定できるかを調査し、実現可能性と制約を明確にする。ストリームの識別を Sora 側の接続単位と一致させることが狙いである。

## 依存関係

`0014-add-mediastream-connection-id`（受信側 MediaStream への connectionId 追加）と領域が近いが、本 issue は送信側ストリームの streamId を対象としており論点が異なる。受信側の connectionId 公開方針と整合を取ること。

## 優先度根拠

Low とする。機能上の不具合ではなく、固定値による直接的な不具合は報告されていない。streamId を connectionId に揃えることはストリーム識別の改善・整合性向上が目的であり、緊急性は低い。固定値前提のロジックへの影響確認が必要なため、慎重に進める Low とする。

## 現状

送信ストリームの streamId の既定値は `"mainStream"` 固定である。

```swift
private let defaultPublisherStreamId: String = "mainStream"
```

`Sora/Configuration.swift:6`

```swift
/// パブリッシャーのストリームの ID です。
/// 通常、指定する必要はありません。
public var publisherStreamId: String = defaultPublisherStreamId
```

`Sora/Configuration.swift:248`

送信ストリーム生成時にこの固定値が使われる。

```swift
.createNativeSenderStream(
  streamId: configuration.publisherStreamId,
```

`Sora/PeerChannel.swift:434`

Sora が発行した connectionId は offer メッセージ受信時に取得できる（`Sora/SignalingOffer.connectionId`、`Sora/Signaling.swift:443`）。

```swift
connectionId = offer.connectionId
```

`Sora/PeerChannel.swift:1027`

`publisherStreamId` は送信ストリームの判定にも利用されている。固定値変更時にこの判定が壊れないよう注意が必要である。

```swift
public var senderStream: MediaStream? {
  ...
  stream.streamId == configuration.publisherStreamId
```

`Sora/MediaChannel.swift:191`

送信ストリームは offer 受信より前（`initializeSenderStream`、`Sora/PeerChannel.swift:422` 付近）で生成される箇所があり、生成時点では connectionId が未確定である可能性がある。生成タイミングと connectionId 確定タイミングの前後関係が論点となる。

## 設計方針

- 送信ストリームの生成タイミングと offer 受信（connectionId 確定）のタイミングを整理し、送信ストリームの streamId を connectionId に設定できる順序かどうかを確認する。
- `RTCMediaStream` の streamId を生成後に変更できるか、もしくは connectionId 確定後に送信ストリームを生成する構成へ変更できるかを調査する。
- `MediaChannel.senderStream` / `receiverStreams` 等で `publisherStreamId` を固定値前提に比較しているロジックが、connectionId ベースでも正しく送受信ストリームを判別できるかを確認する。
- `publisherStreamId` を明示指定している利用者の挙動を壊さないこと。既定挙動を connectionId へ切り替えるか、オプトインにするかを判断する。

## 完了条件

- 送信ストリームの streamId に connectionId を設定できるかどうかを、生成タイミングの制約を踏まえて結論づけること。
- 実現可能な場合は変更方針と後方互換への影響を整理すること。実現困難な場合は代替案を提示すること。
- 調査結果に基づき、対応を行う場合は別 issue として方針を立てること。
- 調査結果と結論を `issues/` 配下の本 issue に記録すること。

## 解決方法
