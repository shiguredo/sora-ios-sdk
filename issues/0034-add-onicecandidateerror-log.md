# RTCPeerConnectionDelegate に ICE candidate 収集失敗のログを追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-onicecandidateerror-log
- Polished: 2026-11-17
- Refreshed: 2026-11-17

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
  // リダイレクト中または旧 RTCPeerConnection からの ICE candidate は無視する。
  // 旧 PC を close() した後に届く遅延 candidate が新接続のシグナリングに
  // 送信されるのを防ぐ。
  guard isCurrentPeerConnection(nativePeerConnection) else {
    return
  }
  Logger.debug(
    type: .peerChannel,
    message: "generated ICE candidate \(candidate)")
  ...
}
```

`Sora/PeerChannel.swift` の `didGenerate candidate:` と `didRemove candidates:` が実装されている。収集状態の変化は `peerConnection(_:didChange newState: RTCIceGatheringState)` が `Logger.debug` で記録している。一方、ICE candidate の収集失敗を通知する `peerConnection(_:didFailToGatherIceCandidate:)` は実装しておらず、収集失敗の詳細（対象サーバーの URL、エラーコード、理由）は SDK の `Logger` に記録されない。

イベント引数 `RTCIceCandidateErrorEvent` は次の情報を持つ。

- `address`: STUN / TURN サーバーとの通信に使用したローカル IP アドレス
- `port`: 通信に使用したポート
- `url`: 失敗が発生した STUN / TURN サーバーの URL
- `errorCode`: STUN エラーコード（サーバーへ到達できない場合は範囲外の 701）
- `errorText`: STUN reason text（サーバーへ到達できない場合は実装固有の詳細文字列）

## 設計方針

- `Sora/PeerChannel.swift` の `RTCPeerConnectionDelegate` 実装に `func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent)` を追加する。挿入位置は `didRemove candidates:` の直後（`didOpen dataChannel:` の前）。
- 既存の PC delegate（`didChange newState: RTCPeerConnectionState` / `didGenerate candidate:` / `didOpen dataChannel:`）と同様に、`isCurrentPeerConnection(_:)` でリダイレクト中または旧 `RTCPeerConnection` からの遅延イベントを無視してからログ出力する。旧 `RTCPeerConnection` からの遅延した収集エラーをそのままログすると、リダイレクト後の接続のトラブルシュートで誤情報になるため。その際、`isCurrentPeerConnection` の doc コメント（本ヘルパーの適用対象の列挙）にも本メソッドを追記する。
- `RTCIceCandidateErrorEvent` の各フィールド（`url` / `errorCode` / `errorText` / `address` / `port`）を `Logger.debug` でログ出力する。既存の `didGenerate` / `didRemove` コールバックも同様に `Logger.debug` を使用しており、ICE 関連ログは一貫してデバッグ用の詳細情報として扱うため統一する。STUN / TURN サーバーが複数ある場合は一部のサーバーへの到達失敗が起こりうるため `Logger.warn` は使用しない。
- `address` / `url` / `errorText` は `RTCIceCandidateErrorEvent.h` で `NS_ASSUME_NONNULL_BEGIN` の `NSString *` と宣言されており、Swift では非 optional の `String` になる。ログ出力は文字列補間（例: `\(event.address)`）で行うため、nil ガードは不要。
- 本 issue のスコープはログ出力に限定し、アプリケーションへのコールバック通知追加は別途判断する。
- ログメッセージフォーマットは次のとおりとする。`RTCIceCandidateErrorEvent` は複数の独立したフィールドを持つため、既存の単一値コールバック（`"generated ICE candidate \(candidate)"`）とは異なり `key=value` 形式で各フィールドを列挙する。
  ```
  failed to gather ICE candidate: url=<url> errorCode=<errorCode> errorText=<errorText> address=<address> port=<port>
  ```

## 関連 issue

- `issues/0070-change-migrate-to-webrtc-c-xcframework.md` (open): libwebrtc を `WebRTC.xcframework` から `libwebrtc_c.xcframework` へ移行する親 issue。Phase 3 で `OnIceCandidateError` の C コールバックへ置き換える予定であり、本 issue との実装分担は 0070 の Phase 0 までに調整する。本 issue は現行の `RTCPeerConnectionDelegate` に追加する。

## テスト方針

モック・スタブは使用しない。

- `RTCIceCandidateErrorEvent` の `address` / `url` / `errorText` は、現行の libwebrtc の public な `init` では設定されず nil のままである。ヘッダの `NS_ASSUME_NONNULL_BEGIN` により Swift では非 optional の `String` として公開され、nil は空文字列にブリッジされるため、空のイベントをログ出力経路へ渡してもクラッシュせず、各フィールドは空文字列または 0 として出力される。任意の値を持つイベントは public API だけでは生成できない。
- `SoraTests/RTCDescriptionTests.swift` に、`makePeerConnectionFixture()` で fixture を作り、`makeLogCollector()` の `collector.clear()` の後に `peerChannel.nativeChannel = fixture.peerConnection` を設定し、空の `RTCIceCandidateErrorEvent()` を渡して `peerConnection(_:didFailToGatherIceCandidate:)` を直接呼ぶテストを追加する。
- 次の 2 点を検証する。
  - `failed to gather ICE candidate: url= errorCode=0 errorText= address= port=0` のログが 1 件出力されること（メッセージ形式と 5 フィールドのキー）。
  - `nativeChannel` が別の `RTCPeerConnection`（または nil）のときは、同じ呼び出しでログが出力されないこと（`isCurrentPeerConnection` ガードの負例）。
- 実値（実際の STUN / TURN サーバーの URL、エラーコード、理由）の出力は、実接続で収集失敗を発生させた E2E または手動で確認する。
- 既存のテストがすべてパスすること。

## 完了条件

- `func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent)` が `Sora/PeerChannel.swift` の `didRemove candidates:` 直後に実装されており、プロジェクトがビルドできること。
- `RTCPeerConnectionDelegate` の `peerConnection:didFailToGatherIceCandidate:` は optional メソッドのため、ビルド成功だけでは実装漏れを検出できない。追加するテストからこのメソッドを直接呼び出してテストが成功することで、シグネチャの一致とログ出力を確認する。
- ICE candidate 収集失敗時に `url` / `errorCode` / `errorText` / `address` / `port` が `Logger.debug` でログ出力されること。空のイベントを使ったテストでメッセージ形式と 5 フィールドを確認し、実値は実接続で収集失敗を発生させた E2E または手動で確認する。
- `isCurrentPeerConnection` が false のときはログが出力されないこと。
- ログメッセージが英語で記述されていること。
- 既存の接続フローに影響がないこと。
- `CHANGES.md` の `## develop` セクションの主リストの `[ADD]` に以下を追記すること（種別順を守り、現在の `[UPDATE]` より前に置く）:
  ```
  - [ADD] ICE candidate の収集失敗時に url / errorCode / errorText / address / port をデバッグログに出力する
    - 既定のログレベル (`info`) では出力されない
    - @voluntas
  ```

## 解決方法
