# offer 受信後にエラーとなった場合すぐに切断されない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-slow-disconnect-after-offer-error
- Polished:

## 概要

SDP の設定でエラーが発生した場合、切断完了までに約 30 秒かかる。エラーが発生した時点で即座に切断されるべきである。

## 再現手順

1. サーバー側で AV1 コーデックを指定して接続する（iOS SDK が対応していないプロファイル、例: AV1 の profile 1）
2. 以下のエラーログが出力される

```
PeerChannel DEBUG: failed setting remote description: (Failed to set remote offer sdp: Failed to set remote video description send parameters for m-section with mid='video_...')
```

3. 接続エラーで終了するまでに約 30 秒かかる

## 根拠

SDP エラーは接続が継続できない致命的なエラーであり、30 秒間ユーザーが応答なしの状態で待たされることになる。エラー発生時は即座に切断処理を走らせる必要がある。

## 調査方針

- `PeerChannel.swift` の SDP 設定失敗後の切断フローを追う
- エラー発生後に切断までのタイムアウト処理がどこで発生しているか特定する
- エラー検知後に即座に `disconnect` を呼ぶよう修正できるか確認する
