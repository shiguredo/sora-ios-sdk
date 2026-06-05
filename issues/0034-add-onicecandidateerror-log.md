# RTCPeerConnectionDelegate に ICE candidate 収集失敗のログを追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-onicecandidateerror-log
- Polished: 2026-06-06

## 目的

`RTCPeerConnectionDelegate` が提供する `peerConnection(_:didFailToGatherIceCandidate:)` コールバックを実装し、ICE candidate のエラー情報をログ出力できるようにする。STUN / TURN サーバーへの到達失敗や ICE candidate の収集エラーをログに残し、接続不良のトラブルシュートを容易にする。

## 優先度根拠

- 機能追加ではなく調査補助のためのログ出力にとどまる。
- バグ修正やユーザー要望ではなく利便性向上が目的であるため Low とする。

## 現状

`Sora/PeerChannel.swift` の `RTCPeerConnectionDelegate` 実装には ICE candidate 関連のコールバックとして以下が実装されており、いずれも `Logger.debug` でログ出力している。

```swift
func peerConnection(
  _ nativePeerConnection: RTCPeerConnection,
  didGenerate candidate: RTCIceCandidate
) {
  Logger.debug(
    type: .peerChannel,
    message: "generated ICE candidate \(candidate)")
  ...
}
```

`Sora/PeerChannel.swift:1419` の `didGenerate` と `Sora/PeerChannel.swift:1432` の `didRemove` が実装されている。一方、ICE candidate の収集失敗を通知する `peerConnection(_:didFailToGatherIceCandidate:)` は実装しておらず、収集失敗時に何も記録されない。

イベント引数 `RTCIceCandidateErrorEvent` は次の情報を持つ。

- `address`: STUN / TURN サーバーとの通信に使用したローカル IP アドレス
- `port`: 通信に使用したポート
- `url`: 失敗が発生した STUN / TURN サーバーの URL
- `errorCode`: STUN エラーコード（サーバーへ到達できない場合は範囲外の 701）
- `errorText`: STUN reason text

## 設計方針

- `Sora/PeerChannel.swift` の `RTCPeerConnectionDelegate` 実装に `peerConnection(_:didFailToGatherIceCandidate:)` を追加する。挿入位置は `didRemove candidates:`（行 1432）の直後（行 1454 の `didOpen` の前）。
- `RTCIceCandidateErrorEvent` の各フィールド（`url` / `errorCode` / `errorText` / `address` / `port`）を `Logger.debug` でログ出力する。既存の `didGenerate` / `didRemove` コールバックも同様に `Logger.debug` を使用しており、ICE 関連ログは一貫してデバッグ用の詳細情報として扱うため統一する。STUN / TURN サーバーが複数ある場合は一部失敗が正常系でも起こりうるため `Logger.warn` は使用しない。
- `address` は mDNS アドレスやプライバシー保護モードでは空文字列になりうる。ログ出力は文字列補間（`\(event.address)`）で行うため、空文字列の場合はそのまま空として出力する（特別な nil ガードは不要）。
- 本 issue のスコープはログ出力に限定し、アプリケーションへのコールバック通知追加は別途判断する。
- ログメッセージフォーマット例。`RTCIceCandidateErrorEvent` は複数の独立したフィールドを持つため、既存の単一値コールバック（`"generated ICE candidate \(candidate)"`）とは異なり `key=value` 形式で各フィールドを列挙する。
  ```
  failed to gather ICE candidate: url=<url> errorCode=<errorCode> errorText=<errorText> address=<address> port=<port>
  ```

## テスト方針

モック・スタブは使用しない。

- 実装対象はデリゲートメソッドの追加のみでログ呼び出しだけを行うため、自動テストは対象外とする。
- 既存のテストがすべてパスすること。

## 完了条件

- `peerConnection(_:didFailToGatherIceCandidate:)` が `Sora/PeerChannel.swift` の `didRemove candidates:` 直後に実装されており、プロジェクトがビルドできること（ビルド成功によって `RTCPeerConnectionDelegate` にこのメソッドが定義されていることを確認する）。
- ICE candidate 収集失敗時に `url` / `errorCode` / `errorText` / `address` / `port` が `Logger.debug` でログ出力されること。
- ログメッセージが英語で記述されていること。
- 既存の接続フローに影響がないこと。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` が存在しない場合は新設すること）:
  ```
  - [ADD] RTCPeerConnectionDelegate に ICE candidate 収集失敗のログ出力を追加する
    - @voluntas
  ```

## 解決方法
