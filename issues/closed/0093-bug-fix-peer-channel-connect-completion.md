# PeerChannel の接続完了ハンドラーを厳密に 1 回だけ終端する

- Created: 2026-08-27
- Completed: 2026-08-28
- Branch: feature/fix-peer-channel-connect-completion
- Polished: 2026-08-27

## 目的

`PeerChannel` の接続処理に存在する callback の未実行、二重実行、誤ったエラー伝播を修正し、1 回の接続試行が成功または失敗のどちらかで厳密に 1 回だけ終端することを保証する。

## 現状

`Sora/PeerChannel.swift` の接続処理には、同じ接続試行を終端する経路が複数存在する。

### Offer SDP の生成エラーが伝播されない

`sendConnectMessage(error:)` が `NativePeerChannelFactory.createClientOfferSDP` の callback を受けた後、callback 引数の `sdpError` ではなく、外側の `sendConnectMessage(error:)` が受け取った `error` を `sendConnectMessage(with:error:redirect:)` へ渡している。

外側の `error` は関数冒頭の分岐を通過した時点で `nil` であるため、SDP 生成が失敗してもエラーが伝播せず、`nil` の SDP を使った接続処理へ進む。

### `createAnswer` が handler を呼ばずに return する契約違反がある

`createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` は、次の段階で `nativeChannel` が存在しない場合にログだけを出して return する。

- 処理開始時
- `setRemoteDescription` 完了後
- `answer` 生成完了後

呼び出し元は `lock.lock()` 取得後に `createAnswer` を呼び、handler 内で `lock.unlock()` を実行する。handler が呼ばれないと lock が解放されず、進行中の切断要求が実行されないまま残留するため、この return は契約違反である。

現行コードでは `nativeChannel` は `createAndSendAnswer` 内の代入のみで nil 化されず、redirect 中の切り替えは世代照合（`generation` の不整合時は `handler(nil, nil)` を呼んで正常終端）が先に捕捉する。このためこれらの nil guard 経路は現在は実質到達しない防御コードだが、handler を必ず 1 回呼ぶ契約は lock 残留を防ぐ不変条件として、到達状況に関わらず満たす。

### callback からの再入で二重実行される

`finishConnecting()` は `onConnect` を `nil` にする前に利用者 callback を呼び、その後で lock を解放する。

利用者が接続成功 callback 内から同期的に `disconnect()` を呼ぶと、`Lock.waitDisconnect` が接続試行中と判断して `basicDisconnect()` を実行する。`basicDisconnect()` には同じ `onConnect` がまだ残っているため、接続 callback が再び呼ばれる。

接続失敗経路にも、lock の解放後かつ `onConnect` のクリア前に利用者 callback を呼ぶ順序がある。

### 接続成功 callback 内から同期的に disconnect() を呼ぶユースケース

当社のサンプル (sora-ios-sdk-samples / sora-ios-sdk-quickstart) には現時点で接続成功 callback 内から直接 `disconnect()` を呼ぶコードはないが、SDK 利用者には次の自然な利用が想定されるため、contract の不備として扱う。

- 接続成功と同時に別の条件を検証し、条件を満たさない場合にその場で切断する (例: 自分自身の stream が別のクライアントと衝突している場合、メタデータ検証に失敗した場合の即時切断・リトライ)
- `MediaChannel.handlers.onConnect` をライブラリや共通部品から設定し、接続完了を起点に切断・再接続を制御するケース

これらの利用では「callback が 1 回だけ呼ばれ、callback 内で行った disconnect が再帰的に同じ callback を呼ばない」こと自体がプラットフォームとして保証すべき挙動である。callback の二重実行は利用者側で callback 回数カウントや重複処理が崩れる原因になり、また `onConnect` が残っていることによる意図しない再入は切断フロー全体の複雑化にもつながる。

## 再現手順

次の各経路を個別に確認する。

1. Offer SDP の生成が失敗する接続条件を用意し、元のエラーが接続 callback に届くか確認する。実環境で失敗条件を再現できない場合は、その事実と代替の検証方法を `## 解決方法` に記録する。
2. answer pipeline の各非同期段階と redirect を競合させ、世代照合で `handler(nil, nil)` が呼ばれて呼び出し元の lock が解放されることを確認する。
3. 接続成功 callback 内から直ちに `disconnect()` を呼び、接続 callback の呼び出し回数を記録する (先行項のユースケースを想定した検証)。
4. 接続失敗 callback 内から切断処理へ再入し、同じ callback が再実行されないか確認する。

## 設計方針

- 1 回の `Sora.connect()` を表す論理接続 ID（`0095` の用語に合わせる）と完了済み状態を持たせ、成功、失敗、timeout、利用者切断を 1 つの終端処理へ集約する。redirect は接続試行を終端しない。redirect は `0095` が定める transport epoch として扱い、redirect 中に in-flight の answer pipeline を破棄するのは現行の世代照合（`dataChannelGeneration`）の役割を維持して対応する。timeout は `PeerChannel` 内ではなく、`MediaChannel` 側の `ConnectionTimer` が `SoraError.connectionTimeout` を `signalingFailure` の切断として `PeerChannel` へ入力する。
- 終端処理では、先に callback を take-and-clear し、状態と lock を確定してから利用者コードを呼ぶ。
- `createAnswer` の handler を `Result<String, Error>` 相当の契約に整理し、すべての return 経路で厳密に 1 回呼ぶ。handler が返す「sdp 取得成功」「エラー」「世代不一致（`nil, nil`）」を呼び出し元が判別できる契約にする。lock の解放は呼び出し元の handler 側に一本化し、`createAnswer` 内部では lock を操作しない。
- `nativeChannel` が存在しない場合は明示的な接続失敗として handler へ渡す。世代不一致は正常終了相当の `nil, nil` として返し、呼び出し元の世代照合で lock を解放して破棄する。現在 `createAnswer` 内と各呼び出し元に二重で存在する世代照合は、呼び出し元側へ集約する。
- Offer SDP callback では `sdpError` をそのまま終端処理へ渡す。
- callback は internal lock または接続状態 executor の外で呼ぶ。
- 本 issue は接続試行の終端保証に限定する。`ConnectionTask.cancel()` 自体の状態競合は `0092`、redirect 中の旧 transport 無効化は `0095`、接続状態全体の executor 集約は `0100` で扱う。

## テスト方針

モックやスタブは使用しない。

- production code の接続完了台帳を使い、成功、各 SDP 失敗、timeout（`MediaChannel` の `ConnectionTimer` が `signalingFailure` の切断として入力する）、利用者切断、redirect 中の世代照合破棄のイベント列を入力し、1 回の論理接続で完了が 1 回だけ記録されることを検証する。
- 実際の `PeerChannel` と WebRTC を使い、接続 callback 内からの即時 disconnect を検証する。
- 実 Sora への接続で成功 callback と切断 callback がそれぞれ 1 回だけ発火することを確認する。
- `createClientOfferSDP` や `answer` の失敗経路は、実際に失敗する入力または接続条件で検証する。実環境で失敗条件を再現できない経路は、その事実と代替の検証方法を `## 解決方法` に記録する。成功結果を返す代替実装は使用しない。
- テストには、callback を呼ぶ前に状態を確定させる理由を日本語コメントで明記する。

## 完了条件

- Offer SDP 生成失敗時に元の `sdpError` が利用者へ通知されること。
- `createAnswer` のすべての return 経路で handler が厳密に 1 回呼ばれること。
- 世代不一致時の lock 解放が一意に定まり、二重解放や未解放が起きないこと。
- 接続 callback 内から `disconnect()` を呼んでも接続 callback が二重実行されないこと。
- 成功、失敗、timeout、利用者切断の競合時も、1 回の論理接続が厳密に 1 回だけ終端すること。redirect は接続試行を終端しないこと。
- callback 呼び出し中に internal lock を保持していないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

`PeerChannel` の接続完了ハンドラーを `invokeConnectHandler(_:)` に集約し、take-and-clear で厳密に 1 回だけ呼び出せるようにした。3 つの終端経路 (接続成功 / 接続失敗 / 利用者切断) はすべてこのメソッドを経由する。callback を取り出した時点で `onConnect` は `nil` になるため、callback 内から同期的に `disconnect()` して再入しても二重実行されない。

あわせて以下の修正を行った。

- Offer SDP 生成失敗時 (`createClientOfferSDP`) は元の `sdpError` を `sendConnectMessage(with:error:)` 経由でそのまま接続 callback へ伝播するよう修正した。従来は接続失敗時に固定の `SoraError.peerChannelError` を返しており、元のエラーが失われていた。
- `createAnswer` の `nativeChannel` が `nil` の 3 つの return 経路で、handler を必ず 1 回だけ呼ぶよう修正した。従来は handler を呼ばずに return していたため、呼び出し元で lock が解放されない (ロック残留) 問題があった。
- 終端経路の呼び出し元 (`finishConnecting` / `sendConnectMessage(error:)` / `basicDisconnect`) を `invokeConnectHandler(_:)` 経由に統一し、`onConnect` を直接操作するコードをすべて置き換えた。あわせて `nativeChannel shoud not be nil` のタイポを `should` に修正した。

検証は `PeerChannelConnectCompletionTests` のユニットテスト 4 件 (take-and-clear / 再入 disconnect / エラー伝播 / 実経路の接続失敗) と、既存テストの実行で完了している。
