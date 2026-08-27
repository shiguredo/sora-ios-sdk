# ConnectionTask の即時キャンセルが接続開始を止めない競合を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-connection-task-cancel-race
- Polished:

## 目的

`Sora.connect()` が返した `ConnectionTask` を直ちにキャンセルしても、バックグラウンドに投入済みの接続処理がそのまま開始される問題を修正する。

キャンセル要求を `PeerChannel` の設定前後にかかわらず保持し、キャンセル済みの接続が開始または完了扱いにならない状態遷移を保証する。

## 現状

`Sora/MediaChannel.swift` の `MediaChannel.connect(webRTCConfiguration:timeout:handler:)` は、`ConnectionTask` を生成した後、`basicConnect(connectionTask:webRTCConfiguration:timeout:handler:)` を `DispatchQueue.global()` へ投入してから呼び出し元へ戻る。

`ConnectionTask.peerChannel` は、バックグラウンド側の `basicConnect` が開始してから設定される。一方、`Sora/Sora.swift` の `ConnectionTask.cancel()` は、`peerChannel` が存在する場合にだけ `disconnect` を呼び、その後 `state` を `.canceled` にする。

このため、次の実行順が成立する。

1. `MediaChannel.connect` が `ConnectionTask` を返す。
2. `basicConnect` が `ConnectionTask.peerChannel` を設定する前に、利用者が `cancel()` を呼ぶ。
3. `peerChannel` が `nil` のため、切断処理は実行されない。
4. バックグラウンド側の `basicConnect` がキャンセル状態を確認せず、接続を開始する。
5. 後続の接続または切断 callback が `ConnectionTask.complete()` を呼び、`.canceled` を `.completed` に上書きする。

`ConnectionTask.state` と `peerChannel` は利用者のスレッドとバックグラウンド処理から同期なしで読み書きされるため、状態確認自体にもデータ競合がある。

## 再現手順

1. 実際の `Sora` インスタンスから `connect()` を呼ぶ。
2. 戻り値の `ConnectionTask` に対して、別の待機処理を挟まず直ちに `cancel()` を呼ぶ。
3. 接続 callback、切断 callback、`ConnectionTask.state` の遷移を記録する。
4. 接続処理が継続する、または最終状態が `.completed` になることを確認する。

実行タイミングに依存するため、単発確認ではなく反復して検証する。

## 設計方針

- `ConnectionTask` の状態と `PeerChannel` への紐付けを、1 つの lock または接続専用 executor の下で管理する。
- 状態遷移を少なくとも `connecting`、`cancelRequested`、`completed`、`canceled` に分け、終端状態から別の終端状態へ遷移させない。
- `PeerChannel` の設定前にキャンセルされた場合はキャンセル要求を保持し、接続開始前なら `basicConnect` を開始しない。
- 接続開始後にキャンセルされた場合は、`PeerChannel` の設定と同じ排他単位でキャンセル要求を確認し、確実に `disconnect` を呼ぶ。
- `complete()` は接続が正常に終端した場合だけ `.completed` へ遷移させ、`.canceled` を上書きしない。
- 利用者 callback は lock の外で呼び出し、callback から `cancel()` や `disconnect()` が再入しても deadlock しないようにする。
- 本 issue では公開 `Sora.connect()` のシグネチャを変更しない。async 接続 API の追加は `issues/0058-add-async-await.md` のスコープとする。

## テスト方針

モックやスタブは使用しない。

- 実際の `ConnectionTask` と接続状態管理実装を使い、返却直後、`PeerChannel` 設定中、接続完了直前の各タイミングで cancel を競合させる。
- production code の状態遷移部分を値とイベントで検証できる場合は、実際の状態遷移実装へイベント列を直接入力し、すべての順序で終端状態が一意になることを検証する。
- 実 Sora への E2E で即時 cancel を反復し、接続成功 callback が発火しないこと、切断後に接続が残らないことを確認する。
- Thread Sanitizer を有効にした Simulator テストを補助的に実行する。
- テストには、なぜ各タイミングを競合させる必要があるかを日本語コメントで明記する。

## 完了条件

- `ConnectionTask.state` と `peerChannel` の読み書きが同じ排他機構で保護されていること。
- `connect()` の戻り値を直ちに cancel しても接続処理が開始されないこと。
- `PeerChannel` 設定と cancel が競合しても、接続が確実に停止すること。
- `.canceled` が `.completed` に上書きされないこと。
- cancel、接続成功、接続失敗、切断 callback が競合しても終端処理が厳密に 1 回であること。
- callback から `cancel()` または `disconnect()` を呼んでも deadlock しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
