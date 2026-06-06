# HTTP Proxy 対応 Phase 2（PAC ファイル対応または OS 設定の参照）

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-http-proxy-phase2
- Polished:

## 概要

HTTP Proxy 対応の Phase 2 として、OS のプロキシ設定を自動的に参照する機能、または PAC（Proxy Auto-Config）ファイルによるプロキシ設定に対応する。

## Phase 1 の実装状況（完了済み）

`Configuration.proxy` として `Proxy(host:port:username:password:)` を指定できる API がすでに実装されている。

- **WebSocket シグナリング**：`URLSessionWebSocketChannel` が `connectionProxyDictionary` を使って HTTP/HTTPS プロキシ経由で接続する
- **TURN**：`NativePeerChannelFactory` が libwebrtc の `RTCProxyType.https` にホスト・ポート・認証情報を渡してプロキシ経由の TURN 接続を行う

libwebrtc の内部実装を利用しているため、C++ SDK と同じ層でプロキシを処理できている。

## Phase 2 の対応内容

### 案 A：OS のプロキシ設定を参照する

- iOS の `CFNetworkCopySystemProxySettings()` または `URLSession` のシステムプロキシ設定を読み取り、自動的にプロキシを適用する
- ユーザーが手動でプロキシを指定しなくても OS 設定に従って動作するようになる

### 案 B：PAC ファイルによるプロキシ自動設定

- PAC ファイル（`FindProxyForURL` 関数を持つ JavaScript ファイル）の URL を指定できるようにする
- PAC ファイルを取得・評価して接続先に応じたプロキシを選択する
- PAC ファイルの評価には `JavaScriptCore` の利用を検討する

## 優先する案

案 A（OS 設定の参照）の方が実装コストが低く、企業ネットワーク環境での利用者にとっても自然な動作に近いため優先度が高い。

## 根拠

企業ネットワーク環境では HTTP Proxy が必須の場合があり、OS 設定に従ってプロキシが自動適用されることで利用者の設定コストが大幅に下がる。PAC ファイル対応はより高度なプロキシ制御を必要とする環境向け。
