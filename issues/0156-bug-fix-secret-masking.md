# ログと文字列表現からシークレットが漏れないようにする

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-secret-masking
- Polished:

## 目的

利用者が設定した TURN の認証情報 (`username` と `credential`) が、ログ出力と文字列表現から平文で漏れないようにする。

ログはサポートや障害調査のために共有されることがあり、認証情報が含まれると TURN サーバーの不正利用につながる。

## 現状

`Sora/Logger.swift` の `maskSecrets` は `access_token` / `token` / `secret` / `authorization` / `credential` の 5 キーを対象に、`"key"\s*:\s*"[^"]*"` を `"key": "***"` へ置換する。`credential` は覆われているが `username` は対象外である。

`Sora/ICEServerInfo.swift` の `description` は `JSONEncoder` の出力をそのまま返す `CustomStringConvertible` の公開実装で、`username` と `credential` を含む。`Logger` を通さない文字列化 (利用者の `print`、`os_log`、クラッシュレポート、独自ログ基盤) では平文になる。

`Sora/PeerChannel.swift` は offer 受信時に `config.iceServerInfos` を debug ログへ出力する。`Logger` 経由のため `credential` はマスクされるが `username` は残る。

`Sora/SignalingChannel.swift` は `urlCandidates` を info ログへ出力する。URL に userinfo (`wss://user:pass@host` 形式) が含まれる場合、マスクの正規表現に一致しないため平文で残る。

`maskSecrets` と `ICEServerInfo.description` のマスク挙動を検証するテストは存在しない。

## 設計方針

- `Logger.maskSecrets` の対象キーに `username` を追加する。
- `ICEServerInfo.description` の扱いを決める。認証情報をマスクした文字列表現を返すか、`description` による文字列化の提供をやめて `Codable` の利用を促すか。公開 API のため後方互換への影響を評価し、破壊的変更になる場合は非推奨化と移行期間を設ける。
- `urlCandidates` のログでは URL の userinfo を除いた表現を使う。同等の処理が必要な箇所のために共通のヘルパーを用意する。
- `maskSecrets` の単体テストを追加し、各対象キーと JSON 以外の形式に対する挙動を固定する。
- マスクの対象キー一覧は定数として 1 箇所にまとめ、追加漏れが起きないようにする。

## 前提となる issue

- `0102`: 接続設定の snapshot 化。本 issue は `ICEServerInfo.description` と `urlCandidates` のログのマスクを扱うため、`0102` の完了後に着手する。
- `0106`: Logger の共有可変状態の同期。同じ `Sora/Logger.swift` の `maskSecrets` 周辺を変更するため、どちらかを先行させもう一方を rebase する。

## 完了条件

- `username` を含む JSON 形式のログで、値がマスクされること。
- `ICEServerInfo.description` またはその後継の文字列表現から `credential` と `username` の平文が得られないこと。
- userinfo を含む URL を `urlCandidates` に指定しても、ログに userinfo が出力されないこと。
- `maskSecrets` の単体テストが存在し、成功すること。
- 公開 API の挙動を変更する場合は `CHANGES.md` に記載し、移行方法を利用者向け文書に書いていること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
