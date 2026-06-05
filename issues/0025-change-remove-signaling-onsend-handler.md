# 送信シグナリングメッセージを書き換え可能な onSend ハンドラを削除する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/change-remove-signaling-onsend-handler

## 目的

送信するシグナリングメッセージを任意に書き換え可能なイベントハンドラ `SignalingChannelInternalHandlers.onSend` を削除する。送信内容を改ざんできる経路はセキュリティ上望ましくないため、送信メッセージを差し替える内部経路自体を仕様から取り除く。

## 優先度根拠

- セキュリティに関わる変更であり、放置すると送信メッセージ改ざんの余地を残し続ける。
- 緊急のクラッシュではなく、`onSend` を設定していない通常利用には影響しないため High ではない。セキュリティ観点から早めに対応すべきであり Medium とする。

## 現状

`SignalingChannelInternalHandlers` に送信メッセージを差し替えるクロージャ `onSend` が定義されている。

```swift
// Sora/SignalingChannel.swift:32
/// シグナリング送信時に呼ばれるクロージャー
var onSend: ((Signaling) -> Signaling)?
```

`send(message:)` では、送信直前にこのクロージャでメッセージを差し替える経路がある。

```swift
// Sora/SignalingChannel.swift:282
Logger.debug(type: .signalingChannel, message: "send message")
let message = internalHandlers.onSend?(message) ?? message
let encoder = JSONEncoder()
```

送信メッセージを差し替える経路は `onSend` のみである。`SignalingChannel` および `SignalingChannelInternalHandlers` は `public` ではなく、`onSend` も公開 API ではないが、送信メッセージを差し替える内部経路自体を取り除く。

## 設計方針

- `send(message:)` での `onSend` による差し替え呼び出しを削除し、受け取った `message` をそのまま利用する。
- 後方互換に配慮して即時削除ではなく、`onSend` プロパティ宣言に `@available(*, unavailable)` を付与して unavailable 化する。これにより、参照しているコードがあればビルド時に明確なエラーで気付ける。unavailable のメッセージは英語で、セキュリティ上の理由で削除した旨と代替手段がない旨を記載する。
- 削除に伴い `onSend` を参照している箇所が他に無いことを確認する。
- 後方互換性: 送信シグナリングメッセージをカスタマイズする手段が失われる。これはセキュリティ上意図した破壊的変更である。`onSend` を設定していた場合に限り送信メッセージの差し替えが行われなくなり、差し替えていない通常利用には影響しない。

## 完了条件

- `SignalingChannel` の送信経路から `onSend` による差し替えが取り除かれていること。
- `onSend` が unavailable 化され、参照箇所があればビルドエラーで検知できること。
- 既存の通常のシグナリング送受信の挙動が変わらないこと。
- 後方互換のない変更のため、`CHANGES.md` の `## develop` セクションに `[CHANGE]` エントリと担当者行を追記すること。

## 解決方法
