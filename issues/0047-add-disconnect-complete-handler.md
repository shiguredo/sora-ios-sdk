# 切断処理の完了を示すイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-disconnect-complete-handler
- Polished:

## 概要

切断処理が完了したタイミングで呼ばれるイベントハンドラを追加する。現状は切断開始のタイミングは分かるが完了タイミングが分からないため、アプリ側でタイミングを取るのに曖昧な待機処理が必要になっている。

## 現状の問題

現時点のイベントハンドラでは切断処理の「完了」タイミングを知る手段がない。そのため切断後すぐに再接続しようとすると `DUPLICATED-CHANNEL-ID`（`0042` 参照）が発生することがある。アプリ側では UI 制御や感覚的な待機時間を設けることで対処しているが、これは本質的な解決ではない。

## 追加する API 案

以下のいずれか、または両方を追加する。

**案 A: `MediaChannelHandlers` にハンドラを追加**

```swift
MediaChannelHandlers.onDisconnectComplete: (() -> Void)?
```

**案 B: `MediaChannel.disconnect(error:)` に completionHandler を追加**

```swift
MediaChannel.disconnect(error: Error?, completionHandler: (() -> Void)?)
```

## 根拠

切断完了の通知がないことで、アプリ側でロジックを正確に組めない。切断 → 再接続のフローが安全に実装できるようになることは、`0042`（DUPLICATED-CHANNEL-ID）の根本解決にもつながる。

## 対応方針

- `MediaChannel.disconnect()` の処理が実際に完了するタイミングを `PeerChannel.swift` および `SignalingChannel.swift` で確認する
- 案 A または案 B のどちらがより自然な API 設計かを判断して実装する
- 既存の `onDisconnect` ハンドラとの役割の差異を明確にする
