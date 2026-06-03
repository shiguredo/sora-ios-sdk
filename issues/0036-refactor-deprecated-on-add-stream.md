# deprecated な onAddStream への対応を行う

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-deprecated-on-add-stream

## 目的

libwebrtc の `RTCPeerConnectionDelegate` における `peerConnection(_:didAddStream:)` / `peerConnection(_:didRemoveStream:)` への依存を解消し、track ベースの `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` へ移行する。stream ベースのコールバックは Plan B 由来であり、Unified Plan を前提とする現在の WebRTC では deprecated 扱いとなっている。将来 libwebrtc から削除される可能性があるため、内部実装を track ベースへ移行しておく。

## 優先度根拠

- 純粋な内部リファクタリングであり、現状の stream ベース実装でも動作に問題は出ていない。
- 他言語 SDK との API 整合や移行方針の合意が必要で、単独で急いで進める性質ではないため Low とする。

## 現状

stream ベースのコールバックで MediaStream を管理している。`peerConnection(_:didAdd stream:)` で `RTCMediaStream` を受け取り、`BasicMediaStream` を生成して `add(stream:)` で登録している。

```swift
func peerConnection(
  _ nativePeerConnection: RTCPeerConnection,
  didAdd stream: RTCMediaStream
) {
  ...
  let stream = BasicMediaStream(
    peerChannel: self,
    nativeStream: stream)
  add(stream: stream)
}
```

`Sora/PeerChannel.swift:1326` の `didAdd stream` と `Sora/PeerChannel.swift:1359` の `didRemove stream`（`remove(streamId:)` を呼ぶ）で扱っている。これらは内部ハンドラ `onAddStream`（`Sora/PeerChannel.swift:38`）を経由する。

```swift
peerChannel.internalHandlers.onAddStream = { [weak self] stream in
  ...
  weakSelf.internalHandlers.onAddStream?(stream)
  weakSelf.handlers.onAddStream?(stream)
}
```

`Sora/MediaChannel.swift:418` 付近で利用者向けの公開クロージャ `onAddStream` / `onRemoveStream`（`Sora/MediaChannel.swift:36`、`Sora/MediaChannel.swift:39`、いずれも `public`）へ伝播している。

libwebrtc の `RTCPeerConnectionDelegate` には track ベースの `didAddReceiver:streams:` / `didRemoveReceiver:` が用意されている。

## 設計方針

- 内部では `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` を用い、外部へ公開するイベントは既存の `onAddStream` / `onRemoveStream` を維持する方向で互換性を確保する。
- 以下の設計課題について事前に方針を決定する。
  1. **stream ID の取得**: `didAddReceiver` / `didRemoveReceiver` から stream ID（msid）を引けるか（libwebrtc objc sdk 側の実装漏れがないか）を確認する。
  2. **track 到着タイミング**: native では stream が揃ったタイミングを判定しづらい。最初に来た track の `streams` でフィルタする方式などを検討し、`BasicMediaStream` 生成と `add(stream:)` / `remove(streamId:)` の流れへ接続する。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動・引数型（`MediaStream`）・呼び出しタイミングを変えない。内部実装のみを track ベースへ切り替える。
- 自ストリームのフィルタリング（`stream.streamId == clientId`）の挙動を track ベースでも維持する。
- 移行が困難（msid が引けない等）と判明した場合は、その根拠を本 issue に追記する。

## 完了条件

- 内部のストリーム管理を `didAddReceiver` / `didRemoveReceiver` ベースへ移行できるかの調査結果がまとまっていること。
- 移行する場合、stream ID（msid）の取得方法と stream が揃ったと判定する条件が明確になっていること。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動と互換性が維持されていること。実機での動作確認を含むこと。
- ログメッセージは英語、コメントは日本語で記述されていること。
- 公開 API への影響有無を明確にし、`CHANGES.md` の `develop` セクションに該当する種別のエントリを追記すること:
  ```
  - [UPDATE] リモートストリームの追加・削除通知を track ベースへ移行する
    - @担当者
  ```

## 解決方法
