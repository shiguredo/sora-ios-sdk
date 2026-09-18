# ログと文字列表現からシークレットが漏れないようにする

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-secret-masking
- Polished: 2026-09-18

## 目的

利用者が設定した TURN の認証情報 (`username` と `credential`) が、ログ出力と文字列表現から平文で漏れないようにする。

ログはサポートや障害調査のために共有されることがあり、認証情報が含まれると TURN サーバーの不正利用につながる。

## 現状

`Sora/Logger.swift` の `maskSecrets` は `access_token` / `token` / `secret` / `authorization` / `credential` の 5 キーを対象に、`"key"\s*:\s*"[^"]*"` を `"key": "***"` へ置換する。`credential` は覆われているが `username` は対象外である。

`Sora/ICEServerInfo.swift` の `description` は `JSONEncoder` の出力をそのまま返す `CustomStringConvertible` の公開実装で、`username` と `credential` を含む。`Logger` を通さない文字列化 (利用者の `print`、`os_log`、クラッシュレポート、独自ログ基盤) では平文になる。

`Sora/PeerChannel.swift` は offer 受信時に `config.iceServerInfos` を debug ログへ出力する。`Logger` 経由のため `credential` はマスクされるが `username` は残る。

`Sora/URLSessionWebSocketChannel.swift` は受信した WebSocket メッセージを `Logger.debug` へ `"[\(host)] receive message => \(message)"` の形で出力する。`message` は `WebSocketMessage` の文字列表現で、JSON はエスケープされて文字列リテラルへ埋め込まれる (`string("{\"iceServers\":[{\"username\":\"...\",\"credential\":\"...\"}]}")`)。`maskSecrets` の正規表現はエスケープされていない `"key": "value"` しか一致しないため、この経路では対象キーの値がマスクされない。実機で、同じ TURN の `credential` が `PeerChannel` の `ICE server infos` (非エスケープ) では `***` にマスクされ、この経路では平文で出力されることを確認した (`username` も平文)。

`Sora/SignalingChannel.swift` は `urlCandidates` を info ログへ出力する。URL に userinfo (`wss://user:pass@host` 形式) が含まれる場合、マスクの正規表現に一致しないため平文で残る。

`maskSecrets` と `ICEServerInfo.description` のマスク挙動を検証するテストは存在しない。

## 設計方針

- `Logger.maskSecrets` の対象キーに `username` を追加する。
- エスケープされた JSON (`\"key\":\"value\"`) でもマスクが効くようにする。エスケープを解いた表現に対してマスクするか、ログへ渡すメッセージの組み立て側 (`URLSessionWebSocketChannel` の受信メッセージの出力など) でマスク済みの表現を作る。対象キーの一覧を 1 箇所にまとめる方針と整合させる。
- `ICEServerInfo.description` の扱いを決める。認証情報をマスクした文字列表現を返すか、`description` による文字列化の提供をやめて `Codable` の利用を促すか。公開 API のため後方互換への影響を評価し、破壊的変更になる場合は非推奨化と移行期間を設ける。
- `urlCandidates` のログでは URL の userinfo を除いた表現を使う。同等の処理が必要な箇所のために共通のヘルパーを用意する。
- `maskSecrets` の単体テストを追加し、各対象キー、エスケープされた JSON、JSON 以外の形式に対する挙動を固定する。
- マスクの対象キー一覧は定数として 1 箇所にまとめ、追加漏れが起きないようにする。

## 前提となる issue

- `0102` (完了済み): 接続設定の snapshot 化。本 issue は `ICEServerInfo.description` と `urlCandidates` のログのマスクを扱うため、`0102` の完了後に着手する。
- `0106` (develop にマージ済み): Logger の共有可変状態の同期。同じ `Sora/Logger.swift` の `maskSecrets` 周辺を変更するため、`0106` の完了後に着手する。`maskSecrets` と対象キーのロジックは `0106` で変更していない。

## 完了条件

- `username` を含む JSON 形式のログで、値がマスクされること。
- エスケープされた JSON を含むログ (`\"credential\":\"...\"` の形) でも、対象キーの値がマスクされること。
- `ICEServerInfo.description` またはその後継の文字列表現から `credential` と `username` の平文が得られないこと。
- userinfo を含む URL を `urlCandidates` に指定しても、ログに userinfo が出力されないこと。
- `maskSecrets` の単体テストが存在し、成功すること。
- 公開 API の挙動を変更する場合は `CHANGES.md` に記載し、移行方法を利用者向け文書に書いていること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
