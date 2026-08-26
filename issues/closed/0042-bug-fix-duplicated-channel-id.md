# 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する

- Priority: Medium
- Created: 2026-06-06
- Completed: 2026-08-25
- Model: Sonnet 4.6
- Branch: feature/fix-duplicated-channel-id
- Polished: 2026-08-25
- Updated: 2026-08-25

## 目的

アプリで切断と接続を短い間隔で繰り返すと、Sora サーバーから `DUPLICATED-CHANNEL-ID` エラーが返ることがある。切断処理の完了（サーバー側セッション解放）前に次の接続シグナリングが送られると競合するが、SDK には切断完了を検知する手段がなく、かつ `Sora.connect()` が生成する新 MediaChannel からは旧接続の状態を参照できない。この競合状態を解消する。

## 優先度根拠

`DUPLICATED-CHANNEL-ID` が発生すると接続が失敗し、ユーザーが手動で再操作しなければならない。ただし再現性が低く（非確定的）、致命的なデータ損失はないため Medium とする。

## 現状

### コードの実態

`MediaChannel.connect()` は `state.isConnecting`（`ConnectionState.swift:18`）のみで排他制御しており、`isConnecting` は `state == .connecting` のみ `true` を返す（`.disconnecting` は含まない）。

`MediaChannel.internalDisconnect()` は `peerChannel.disconnect()` を呼び、呼び出し先の `Lock.waitDisconnect()`（`PeerChannel.swift:125-159`）が `Lock.count` の値によって分岐する（分岐の詳細と更新履歴は `0047` の現状を参照）。このうち競合するのは**遅延パス**のみで、`Lock.waitDisconnect()` が `shouldDisconnect` にパラメータを保存するだけで即座に返り、`basicDisconnect()` は進行中の非同期処理完了時の `Lock.unlock()`（`PeerChannel.swift:191-222`）から実行される。

遅延パスでは、アプリ側が `onDisconnect` ハンドラ内で即座に `connect()` を呼ぶと、`state == .disconnected` であるため接続が実行される。しかし `Sora.connect()` は新しい `MediaChannel` インスタンスを生成する（`Sora.swift:180`）ため、旧インスタンスの state ガードは再接続経路に介入できない。サーバー側のチャンネルクリーンアップが完了していない状態で同一チャンネル ID の接続シグナリングが送られ、`DUPLICATED-CHANNEL-ID` エラーを引き起こす。

`DUPLICATED-CHANNEL-ID` は Sora サーバーがシグナリングエラーとして返すもので、SDK 内部では `SoraError.webSocketClosed(statusCode:reason:)`（`SoraError.swift:22`）として伝搬し、`SoraCloseEvent.ok(code, reason)` に変換され（`MediaChannel.swift:626-639`）、切断ハンドラで通知される（`MediaChannel.swift:641`）。なお SDK にサーバーからの `type: error` シグナリング JSON を受信・解釈する経路はなく、上記は Sora サーバーが WebSocket Close Frame（code 1008 相当 + reason）で応答する前提に基づく。レースの存在が認識されており、既存 E2E の `testSendonlyReconnect`（`SendonlyE2ETests.swift:301-304`）には回避策として「即時再接続による DUPLICATED-CHANNEL-ID レースを避ける」ための 1 秒待機が入っている（`0079` で追加）。

### 再現条件

- 遅延パスの切断、すなわち count >= 2（接続試行中の answer 作成中）または count == 1 かつ `onConnect == nil`（接続確立後の再ネゴシエーション時の SDP 再ハンドシェイク）の間に切断が発生し、`onDisconnect` ハンドラ内で即座に `connect()` を呼ぶ。接続試行中かつ count == 1（`onConnect != nil`）の場合は 0024 の修正（`7db90af9`）で同期パスとなったため競合しない
- 再現性は低い（非確定的）。サーバー側のチャンネルクリーンアップに必要な時間が未確定のため

## 設計方針

修正方針は以下の 2 つが候補であり、**方針 A を採用する**（方針 B の見送り理由は後述）。

**方針 A（採用）**: `0047` で実装される切断完了ハンドラ（`onDisconnectComplete`）を利用し、アプリ側が「サーバー側のクリーンアップ完了に最も近い時点」で `connect()` を呼べるようにする（根本解決。ただしサーバー側の旧接続解放には TCP レベルのラグが存在するため完全な保証ではない（制約の詳細は完了条件参照）。また、従来の「`onDisconnect` ハンドラ内で即座に `connect()` する」構成のままでは解消しない。アプリ側の修正（`onDisconnectComplete` をトリガーにした再接続）が前提である）

**方針 B（見送り）**: `Sora.connect()` レベルで、同一 channelId を持つ既存の `MediaChannel` の切断が未完了の場合に `SoraError.connectionBusy` を返す防衛的ガード。見送り理由:

- 同一 channelId への複数クライアント同時接続は正常な利用であり（既存 E2E の `SendrecvE2ETests` / `MessagingE2ETests` / `RpcE2ETests` 等が同一 channelId で 2 接続を行っている）、サーバーの `DUPLICATED-CHANNEL-ID` 判定は channelId 単独ではない。channelId のみの照合は正常利用を誤爆する
- 切断要求が `internalDisconnect()` に入った時点で旧 MediaChannel は `internalHandlers.onDisconnectLegacy?`（`MediaChannel.swift:615`）経由で `Sora._mediaChannels` から除去済み（`Sora.swift:181-190`）であり、`Sora.connect()` から既存 MediaChannel の切断未完了を照合できない（同期パス・遅延パスを問わない）
- 観測するためには Sora に「channelId → 切断要求中」のセッション表を持たせ、`basicDisconnect()` の完了通知を Sora へ配線する必要があり、0047 の設計（`basicDisconnectCompleted` は `private`、`internalHandlers` への完了ハンドラ追加はしない）を覆す。再設計の費用に対して効果が不確実（`basicDisconnect()` 完了後にもサーバー側解放遅れが残り、方針 A と同じ TCP ラグの制約を受ける）

もし将来方針 B を実装する場合は、セッション表の設計から別途 issue で検討する。

## 完了条件

- 方針 A（採用）: アプリが `onDisconnectComplete` をトリガーに `connect()` する構成で、切断 → 即時再接続のパターンで `DUPLICATED-CHANNEL-ID` エラーが発生しないこと（WebSocket シグナリング構成・通常条件下で。サーバー側の旧接続解放には TCP レベルのラグが存在するため完全な保証ではない。DataChannel シグナリング構成はスコープ外。検証は 0047 の完了条件・E2E（`testSendonlyReconnect` の 1 秒待機を発火待ちに置き換える変更）に委譲する）
- 通常の接続・切断フローに影響がないこと（同一 channelId の複数クライアント同時接続を含む既存 E2E が通ること。確認は 0047 の実装 PR で行う）
- `CHANGES.md` の `develop` セクションに以下を追記すること（追記先は 0047 の実装 PR。0047 の完了条件にも同旨を含める）

```
- [FIX] 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する問題を修正する
  - @voluntas
```

## 解決方法

- 本 issue は SDK のコード変更を含まない。方針 A の実装（`onDisconnectComplete` の追加）は `0047` で行い、本 issue は 0047 の実装完了をもって解決とする
- 検証（`testSendonlyReconnect` の変更と「onDisconnectComplete 発火をトリガーとした再接続の成功」、既存 E2E のリーグレッション確認）は 0047 の完了条件・解決方法に委譲する
- 本 issue を close する時点で、検証結果（E2E の成功の有無）と `CHANGES.md` の `[FIX]` エントリ追記状況を本セクションに記録する

### 実装結果

- 方針 A は `0047`（closed）で実装済み。`Sora/MediaChannel.swift` / `Sora/PeerChannel.swift` / `SoraTests/` への反映と、Swift 6 モードのビルド・単体テスト 5 件の実行済みを確認
- `CHANGES.md` の `## develop` に `[FIX]` エントリを追記済み（`onDisconnectComplete` ハンドラ追加による原因対処を説明。対応者: @t-miya）
- 実機確認（手動）: 接続と切断を数回繰り返し、エラーなし
- E2E 検証（`testSendonlyReconnect` の変更）は実サーバーが必要なため未実行。`SORA_SIGNALING_URL` / `TEST_API_URL` / `TEST_SECRET_KEY` を設定した CI で 0047 側の完了条件と併せて確認すること

## 関連 issue

- `0047-add-disconnect-complete-handler.md`: 切断完了ハンドラの追加（本 issue の方針 A に対応する根本解決策）
- `0024`（closed）: `Lock.waitDisconnect()` の接続試行中（`count == 1` かつ `onConnect != nil`）の同期パス化（本 issue の再現条件に影響）
- `0043`（closed）: ネットワーク切断検知の追加（`closed/0043` の関連 issue 節に、切断検知後の即時再接続で本 issue のレースが生じやすくなる旨が記録されている）
