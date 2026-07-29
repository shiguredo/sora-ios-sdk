# ローカルストリームの streamId に connectionId を設定できるか調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-local-stream-id-connection-id
- Polished: 2026-06-05

## 目的

ローカルストリーム（送信側 sender）の streamId に、現状の `"mainStream"` 固定値ではなく Sora が発行した `connectionId` を設定できるかを調査し、実現可能性と制約を明確にする。ストリームの識別を Sora 側の接続単位と一致させることが狙いである。

## 調査結果

### 結論: 実現可能

ソースコード分析の結果、`connectionId` は送信ストリーム生成より前に確定するため、streamId に `connectionId` を設定することは技術的に可能である。

### 呼び出し順序の検証

`PeerChannel.swift` の処理フロー:

1. `handleSignalingOverWebSocket` で offer 受信 → `connectionId = offer.connectionId`（`PeerChannel.swift:1027`）
2. `createAndSendAnswer` → `createAnswer` の内部で `initializeSenderStream(mid:)` が呼ばれる（`PeerChannel.swift:742`）
3. `initializeSenderStream` 内で `createNativeSenderStream(streamId:)` が呼ばれ、`configuration.publisherStreamId` が渡される（`PeerChannel.swift:434-435`）

`connectionId` の確定（ステップ 1）は stream 生成（ステップ 2-3）より前であり、タイミングの問題は存在しない。issue 作成当初に想定された「offer 受信より前の stream 生成」は発生していない。

### 実現方式の候補

`publisherStreamId` が既定値 `"mainStream"` かつ `connectionId` が非 nil の場合に、`self.connectionId` を streamId として使用する方式:

```swift
let streamId: String
if configuration.publisherStreamId == defaultPublisherStreamId,
   let connId = self.connectionId {
    streamId = connId
} else {
    streamId = configuration.publisherStreamId
}
```

### 変更が必要な箇所

| ファイル | 行 | 内容 |
|----------|-----|------|
| `PeerChannel.swift` | 434-435 | `createNativeSenderStream(streamId:)` の引数を connectionId 対応に変更 |
| `MediaChannel.swift` | 191 | `senderStream` の比較ロジックを connectionId 対応に変更 |
| `MediaChannel.swift` | 199 | `receiverStreams` の判定ロジックを同様に変更 |

### 後方互換性の考慮

- `publisherStreamId` を明示指定している利用者は、これまで通り指定値が優先される。
- `connectionId` が nil の場合（異常系）、従来通り `"mainStream"` が使われる。
- 既存利用者のほとんどは `publisherStreamId` を明示指定していないため、暗黙的な挙動変更となる。挙動変更の周知が必要。

### 代替アプローチ

`RTCMediaStream` の streamId を変更する代わりに、`MediaStream` ラッパーに `connectionId` プロパティを持たせて識別に使う方式もある。こちらの方が native streamId に依存しないため後方互換性の面で安全だが、`MediaStream` の `streamId` との二重管理になる。

## 次のステップ

本調査の結果、streamId への connectionId 設定は技術的に可能である。実装にあたっては別 issue を立て、以下の設計判断を行う:

1. streamId を connectionId に変更する方式を採用するか、`MediaStream` ラッパーに connectionId プロパティを追加する方式を採用するか
2. 既定挙動の変更をオプトインにするか（新フラグを追加するか）
3. 受信側の connectionId 公開（`0014-add-mediastream-connection-id`）との整合性

## 解決方法

ソースコードの処理フローを解析し、`connectionId` が送信ストリーム生成より前に確定することを確認した。実装方針の詳細は別 issue で対応する。
