# 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-duplicated-channel-id
- Polished:

## 概要

アプリで切断と接続を繰り返すと、サーバー側から `DUPLICATED-CHANNEL-ID` エラーが返ることがある。切断処理が完了する前に次の接続が開始されることで、同一チャンネル ID での多重接続が発生していると推測される。

## 再現条件

- 切断と接続を短い間隔で繰り返す
- 再現性は高くない（非確定的）

## 根拠

`DUPLICATED-CHANNEL-ID` エラーはサーバー側で同一チャンネルへの多重接続を検出した場合に返される。SDK 側で切断完了を確認してから次の接続を行う手段が提供されていないため、アプリ側での対処が困難な状態になっている。

切断処理完了ハンドラ（`0047-add-disconnect-complete-handler`）の実装が根本的な解決策の一つになり得る。

## 調査方針

- `MediaChannel.disconnect()` の完了タイミングと次の `connect()` 呼び出しとの競合状態を調べる
- シグナリングチャンネルおよび PeerConnection のクリーンアップが完了するまでの処理フローを確認する
- `0047` の切断完了ハンドラと合わせて修正できるか検討する
