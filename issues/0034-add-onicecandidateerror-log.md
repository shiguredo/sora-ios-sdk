# RTCPeerConnectionDelegate に ICE candidate 収集失敗のログを追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-onicecandidateerror-log

## 目的

libwebrtc に追加された `peerConnection(_:didFailToGatherIceCandidate:)` コールバックを `RTCPeerConnectionDelegate` 実装で受け取り、ICE candidate のエラー情報をログ出力できるようにする。STUN / TURN サーバーへの到達失敗や ICE candidate の収集エラーをログに残し、接続不良のトラブルシュートを容易にする。

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

- `Sora/PeerChannel.swift` の `RTCPeerConnectionDelegate` 実装に `peerConnection(_:didFailToGatherIceCandidate:)` を追加し、`RTCIceCandidateErrorEvent` の各フィールド（`url` / `errorCode` / `errorText` / `address` / `port`）をログ出力する。
- 本 issue のスコープはログ出力に限定し、アプリケーションへのコールバック通知追加は別途判断する。
- STUN / TURN サーバーが複数ある場合は一部の失敗が正常系でも起こりうるため、過度に警告として扱わない。
- ログメッセージは英語で記述する。
- 既存のコールバックを変更しないため後方互換性に影響はない。

## 完了条件

- `peerConnection(_:didFailToGatherIceCandidate:)` が `Sora/PeerChannel.swift` に実装されていること。
- ICE candidate 収集失敗時に `url` / `errorCode` / `errorText` / `address` / `port` がログ出力されること。
- ログメッセージが英語で記述されていること。
- 既存の接続フローに影響がないこと。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] RTCPeerConnectionDelegate に ICE candidate 収集失敗のログ出力を追加する
    - @担当者
  ```

## 解決方法
