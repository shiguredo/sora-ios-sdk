# RPC の pending 登録と invalidate の競合を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-rpc-pending-invalidation-race
- Polished:

## 目的

RPC の開始と DataChannel 切断が競合したときに、`RPCChannel` の解放後も pending が残り、async continuation が永久に再開されない問題を修正する。

response、timeout、切断、送信失敗、Task cancellation のどの経路でも、RPC を厳密に 1 回だけ終端させる。

## 現状

`Sora/RPC.swift` の `RPCChannel.call(methodName:params:isNotificationRequest:timeout:completion:)` は、次の処理を別々の排他単位で行っている。

- `dataChannel.readyState` による利用可能性確認
- RPC ID の採番
- `pendings` への登録
- DataChannel への送信
- timeout work item の予約

`RPCChannel.invalidate(reason:)` は、その時点で登録済みの pending を barrier 下で取り出して失敗させるが、RPCChannel 自体が invalidated であることを記録しない。

このため、次の実行順が成立する。

1. `call` が DataChannel の open を確認する。
2. 切断処理が `invalidate` を呼び、その時点の pending を削除する。
3. `call` が新しい pending を登録する。
4. `PeerChannel` が `RPCChannel` の参照を解放する。
5. timeout work item は `RPCChannel` を weak captureしているため何も実行しない。
6. completion が呼ばれず、`MediaChannel.rpc` の checked continuation が永久に再開されない。

response、timeout、invalidate が既に登録された同一 pending を取り合う経路は barrier 下の削除で 1 回に抑えられているが、invalidate 後の登録を防げていない。

## 再現手順

1. RPC 用 DataChannel が open になった実接続を用意する。
2. RPC の開始と切断を異なる Task から同時に実行する。
3. すべての RPC Task が規定時間内に成功または `rpcDataChannelClosed` で終端するか確認する。
4. 切断後に timeout を超えても完了しない Task が残ることを反復試験で確認する。

## 設計方針

- `RPCChannel` に invalidated 状態を持たせ、利用可能性確認と pending 登録を `invalidate` と同じ排他単位で行う。
- invalidated 後の `call` は pending を登録せず、直ちに `rpcDataChannelClosed` または対応するエラーで失敗させる。
- pending ごとに 1 回だけ遷移できる終端状態を持たせ、response、timeout、invalidate、送信失敗、Task cancellation を同じ `finishPending` 経路へ集約する。
- timeout の実行を `RPCChannel` の weak 参照だけに依存させない。所有者が解放される場合も pending の completion が終端する構造にする。
- timeout work item は pending 終端時に必ずキャンセルし、pending からも参照を切る。
- 利用者 completion は barrier または lock の外で呼ぶ。
- 本 issue では公開 RPC の `Any` / `Sendable` 契約は変更しない。公開 RPC API の Swift 6 対応は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- 実 DataChannel を使用し、RPC 開始と disconnect を多数回競合させる E2E テストを追加する。
- response、timeout、invalidate、送信失敗の各終端で completion の呼び出し回数を記録する。
- notification request は pending を作らず、送信結果だけで 1 回終端することを確認する。
- production の pending 管理実装へ実際のイベント順を入力し、すべての順列で pending が空になることを検証する。
- Task cancellation を対応範囲に含める場合は、キャンセル後に timeout work item と pending が残らないことを確認する。
- テストには、invalidate 後の pending 登録を再現するためのイベント順を日本語コメントで明記する。

## 完了条件

- `call` の利用可能性確認と pending 登録が `invalidate` に対して原子的であること。
- `invalidate` 後に pending を登録できないこと。
- RPCChannel が解放されても completion または continuation が未終端で残らないこと。
- response、timeout、invalidate、送信失敗、Task cancellation が競合しても厳密に 1 回だけ終端すること。
- 終端後に timeout work item と pending が残らないこと。
- completion を内部の barrier または lock の外で呼んでいること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
