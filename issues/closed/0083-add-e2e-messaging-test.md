# DataChannel messaging 送受信と stats 検証 E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed: 2026-08-20
- Model: GPT-5
- Branch: feature/add-e2e-messaging-test
- Polished: 2026-08-19

## 目的

DataChannel 経由のメッセージ送受信と統計情報を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/messaging.test.ts` 相当のテストを行う。

## 優先度根拠

- メッセージング機能は SDK が対応済みの主要機能であり、E2E での動作保証が必要
- ただし、DataChannel の接続・`switched` 受信・`onDataChannelOpened` の発火は `testSendonlySwitched` で検証済みであり、本 issue は送受信と stats の追加検証に限られるため Medium とする

## 現状

iOS SDK は `DataChannel` クラスで DataChannel 経由のメッセージ送受信をサポートしているが、`sendMessage` / `onDataChannelMessage` によるメッセージ送受信と data-channel stats の検証を行う E2E テストが存在しない。

なお、DataChannel シグナリングの接続・`switched` 受信・`onDataChannelOpened` の発火は `testSendonlySwitched`（`SoraTests/SendonlyE2ETests.swift`）として既に E2E 検証済みである。本 issue は同テストの構成（`dataChannelSignaling = true` / `ignoreDisconnectWebSocket = true` / `#spam` ラベル払い出し / ハンドラの connect 前登録 / `onReceiveSignalingJSON` での switched フィルタ / offer 判定による XCTSkip）を踏襲する。

## 設計方針

2 台の sendrecv クライアントを同一チャンネルに接続し、DataChannel 経由でメッセージを送受信する。

### テストの流れ

1. sendrecv 2 台を接続する。設定は以下を明示する:
   - `buildChannelId(unique: true)` で一意なチャンネル ID を生成し、2 台で共用する（残留接続との混在を防ぐ）
   - `dataChannelSignaling = true`（`switched` 受信の前提）
   - `ignoreDisconnectWebSocket = true`（DataChannel シグナリング有効時の WebSocket 切断で接続が終端しないようにするため）
   - `videoEnabled = false`、`audioEnabled = false`、`initialCameraEnabled = false`（映像・音声は使用しない。同一プロセスでの音声デバイス同時起動制約と、シミュレータでのカメラ・マイク権限要求を回避するため。メディアなし sendrecv 接続の先例が既存テストにないため、実装前にサーバーが受理することを確認する）
   - `dataChannels` でメッセージング用ラベルを払い出す。例: `[["label": "#spam", "direction": "sendrecv", "compress": false]]`（`direction` は Sora の `data_channels` 仕様の必須項目。`#` 始まりのラベルはメッセージング用として Sora が DataChannel を作成する）
2. client1 / client2 それぞれで、対象ラベルの `onDataChannelOpened` と `type: "switched"` の受信を待機する
   - ハンドラ（`onDataChannelOpened` / `onReceiveSignalingJSON` / `onDataChannelMessage`）は connect 呼び出しより前に `configuration.mediaChannelHandlers` 経由で登録する（`switched` は接続完了より先に到着し得る）
   - 共有状態の更新は `DispatchQueue.main.async` に束ねる（ハンドラは WebSocket 受信スレッドと libwebrtc の delegate スレッドから呼ばれるため）
   - `switched` の検知は `onReceiveSignalingJSON` で `type == "switched"` をフィルタする
   - 送信には両方の待機が必須である。`sendMessage` は `switchedToDataChannel` ゲート（`type: "switched"` 受信時のみ true）があるため、`onDataChannelOpened` だけでは "DataChannel is not open yet" で失敗する
   - 受信側の `onDataChannelOpened` 待機も必須である（送信側の DataChannel が open しても、受信側の `#spam` DataChannel が open する前に送ったメッセージは Sora が中継できないため、受信検証が不安定になる）
3. client1 → client2 にメッセージを送信し、client2 で受信を確認する
   - 送信は `MediaChannel.sendMessage(label:data:)` を使い、戻り値が nil であることを確認する
   - 受信は `onDataChannelMessage` で `label == 対象ラベル && data == 送信データ` を検証する（ハンドラは全ラベルで発火するため、ラベルと内容の一致を確認する）
   - 送信データは一意な文字列（例: UUID 文字列）の `Data` とする
4. client2 → client1 にメッセージを送信し、client1 で受信を確認する（手順 3 と同様に、`sendMessage` の戻り値 nil 確認・ラベルと内容の一致検証を行う）
5. 両方で `getStats` を取得し、対象ラベルの DataChannel stats を確認する
   - `stats.entries` から `type == "data-channel"` かつ `values["label"] == 対象ラベル` のエントリを特定し、`values["bytesSent"]` / `values["bytesReceived"]` / `values["messagesSent"]` / `values["messagesReceived"]` を `as? NSNumber` で取り出して 0 より大きいことを確認する
   - stats 集計の遅延に備え、リトライ付きで検証する（既存の `verifyVideoStats` と同様のパターン）
   - **実装前に、iOS libwebrtc の `getStats` が `data-channel` 型のレポートを報告するかを実機で確認する**（報告されない場合は完了条件の stats 検証を見直す）
6. 切断する（`disconnectAndVerify`。失敗分岐では `disconnectAll` と未 wait の expectation の後始末を行う）
   - ハンドラ内の fulfill と後始末の fulfill が重複すると XCTest の "API violation - multiple calls made to fulfill" で失敗するため、`testSendonlySwitched` と同様に fulfill フラグと `XCTWaiter.wait(for:timeout: 0)` を併用する

### XCTSkip 条件

- サーバーが DataChannel シグナリング未対応の場合（offer に `data_channels` フィールドが含まれない場合）は、後始末を実行してから XCTSkip でスキップする（サーバー未対応と SDK の不具合を区別するため）
- サーバーがメッセージング未対応の場合（offer の `data_channels` に払い出したラベル `#spam` が含まれない場合）も同様に XCTSkip でスキップする（`onDataChannelOpened` が発火せず待機タイムアウトで XCTFail になるのを防ぐ。`testSendonlySwitched` と同じパターン）
- `switched` の受信タイムアウトではスキップしない（SDK の不具合として XCTFail する）

## テスト方針

- モック・スタブは使用しない
- 新規ファイル `SoraTests/MessagingE2ETests.swift` に `testSendrecvDataChannelMessaging` として追加する（sendrecv 2 台接続だが映像・音声を使用しないため、既存の `SendrecvE2ETests`（映像テスト）とは分離する）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration`）の XCTSkip に委譲する
- タイムアウト: 接続 35 秒 × 2 + 送信準備待機 10 秒 + メッセージ送受信待機 10 秒 × 2 + stats 検証 30 秒 + 切断 10 秒 × 2。全体を 3 分以内に収める
  - 送信準備待機（`onDataChannelOpened` と `switched` の 4 本の expectation）は 1 回の `XCTWaiter.wait` でまとめて待つ（クライアントごと・条件ごとに直列に待つと最悪 40 秒になり、3 分以内の制約を超えるため）

## Sora サーバー要件

- 0080 と同じ（DataChannel シグナリング有効・`metadata.access_token` 認証・`e2e-test` を含む channelId の受理）
- リアルタイムメッセージング（`data_channel_messaging`）が有効であること（クライアントの `data_channels` 要求を受理し、offer の `data_channels` に含めること）
- 同一チャンネルへの sendrecv クライアントの同時 2 接続を受け付けること

## 完了条件

- 各クライアントで対象ラベルの `onDataChannelOpened` と `type: "switched"` の両方を満たしてからメッセージを送信すること
- 各クライアントでメッセージが送受信できること（送信内容と受信内容が一致すること）
- `getStats` で対象ラベルの DataChannel stats が確認できること（bytesSent / bytesReceived > 0、messagesSent / messagesReceived > 0）
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法

`SoraTests/MessagingE2ETests.swift` を新規作成し、`testSendrecvDataChannelMessaging` を追加した。

- 2 台の sendrecv クライアント（`videoEnabled` / `audioEnabled` / `initialCameraEnabled` を false に設定）を `buildChannelId(unique: true)` の一意なチャンネル ID で接続する
- `dataChannelSignaling = true` / `ignoreDisconnectWebSocket = true` を設定し、`dataChannels` で `#spam`（`direction: "sendrecv"`、`compress: false`）を払い出す
- ハンドラ（`onReceiveSignalingJSON` / `onDataChannelOpened` / `onDataChannelMessage`）は connect 呼び出しより前に登録し、状態更新は main queue に束ねる
- 両クライアントの `switched` 受信と `#spam` の OPEN を 1 回の `XCTWaiter.wait` で待ってから、双方向でメッセージを送信し、受信内容が送信内容と一致することを検証する
- `getStats` で `type == "data-channel"` かつ `values["label"] == "#spam"` のエントリを特定し、`bytesSent` / `bytesReceived` / `messagesSent` / `messagesReceived` がすべて 0 より大きいことをリトライ付きで検証する
- offer に `data_channels` フィールドが含まれない場合（DataChannel シグナリング未対応）と、`#spam` が offer に含まれない場合（メッセージング未対応）は、後始末を実行してから XCTSkip でスキップする
- ローカル E2E 実行で、メッセージの双方向送受信と DataChannel stats の検証が成功することを確認した
- `CHANGES.md` の develop セクションの `### misc` に追記した
