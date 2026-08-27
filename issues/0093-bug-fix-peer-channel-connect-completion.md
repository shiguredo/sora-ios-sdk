# PeerChannel の接続完了ハンドラーを厳密に 1 回だけ終端する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-peer-channel-connect-completion
- Polished:

## 目的

`PeerChannel` の接続処理に存在する callback の未実行、二重実行、誤ったエラー伝播を修正し、1 回の接続試行が成功または失敗のどちらかで厳密に 1 回だけ終端することを保証する。

## 現状

`Sora/PeerChannel.swift` の接続処理には、同じ接続試行を終端する経路が複数存在する。

### Offer SDP の生成エラーが伝播されない

`sendConnectMessage(error:)` が `NativePeerChannelFactory.createClientOfferSDP` の callback を受けた後、callback 引数の `sdpError` ではなく、外側の `sendConnectMessage(error:)` が受け取った `error` を `sendConnectMessage(with:error:redirect:)` へ渡している。

外側の `error` は関数冒頭の分岐を通過した時点で `nil` であるため、SDP 生成が失敗してもエラーが伝播せず、`nil` の SDP を使った接続処理へ進む。

### `createAnswer` が handler を呼ばずに終了する

`createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` は、次の段階で `nativeChannel` が存在しない場合にログだけを出して return する。

- 処理開始時
- `setRemoteDescription` 完了後
- `answer` 生成完了後

呼び出し元が `Lock.lock()` を取得してから `createAnswer` を呼んでいる経路では、handler が呼ばれないため `Lock.unlock()` に到達せず、切断処理が残留する。

### callback からの再入で二重実行される

`finishConnecting()` は `onConnect` を `nil` にする前に利用者 callback を呼び、その後で lock を解放する。

利用者が接続成功 callback 内から同期的に `disconnect()` を呼ぶと、`Lock.waitDisconnect` が接続試行中と判断して `basicDisconnect()` を実行する。`basicDisconnect()` には同じ `onConnect` がまだ残っているため、接続 callback が再び呼ばれる。

接続失敗経路にも、lock の解放後かつ `onConnect` のクリア前に利用者 callback を呼ぶ順序がある。

## 再現手順

次の各経路を個別に確認する。

1. Offer SDP の生成が失敗する接続条件を用意し、元のエラーが接続 callback に届くか確認する。
2. answer pipeline の各非同期段階と切断または redirect を競合させ、`nativeChannel` が切り替わる経路を確認する。
3. 接続成功 callback 内から直ちに `disconnect()` を呼び、接続 callback の呼び出し回数を記録する。
4. 接続失敗 callback 内から切断処理へ再入し、同じ callback が再実行されないか確認する。

## 設計方針

- 接続試行ごとに一意な ID と完了済み状態を持たせ、成功、失敗、timeout、redirect、利用者切断を 1 つの終端処理へ集約する。
- 終端処理では、先に callback を take-and-clear し、状態と lock を確定してから利用者コードを呼ぶ。
- `createAnswer` の handler を `Result<String, Error>` 相当の契約に整理し、すべての return 経路で厳密に 1 回呼ぶ。
- `nativeChannel` が存在しない場合を明示的な接続失敗として扱う。世代不一致を正常終了相当の `nil, nil` として扱う場合も、呼び出し元が必ず lock を解放できる結果を返す。
- Offer SDP callback では `sdpError` をそのまま終端処理へ渡す。
- callback は internal lock または接続状態 executor の外で呼ぶ。
- 本 issue は接続試行の終端保証に限定する。`ConnectionTask.cancel()` 自体の状態競合は `0092`、接続状態全体の executor 集約は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- production code の接続完了台帳を使い、成功、各 SDP 失敗、timeout、切断、redirect のイベント列を入力して完了回数を検証する。
- 実際の `PeerChannel` と WebRTC を使い、接続 callback 内からの即時 disconnect を検証する。
- 実 Sora への接続で成功 callback と切断 callback がそれぞれ 1 回だけ発火することを確認する。
- エラー経路の検証では、実際に失敗する入力または接続条件を使用し、成功結果を返す代替実装は使用しない。
- テストには、callback を呼ぶ前に状態を確定させる理由を日本語コメントで明記する。

## 完了条件

- Offer SDP 生成失敗時に元の `sdpError` が利用者へ通知されること。
- `createAnswer` のすべての return 経路で handler が厳密に 1 回呼ばれること。
- answer pipeline の途中で `nativeChannel` が失われても lock が残らないこと。
- 接続 callback 内から `disconnect()` を呼んでも接続 callback が二重実行されないこと。
- 成功、失敗、timeout、redirect、切断の競合時も 1 回の接続試行が厳密に 1 回だけ終端すること。
- callback 呼び出し中に internal lock を保持していないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
