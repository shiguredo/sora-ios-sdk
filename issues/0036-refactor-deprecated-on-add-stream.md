# deprecated な onAddStream への対応を行う

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-deprecated-on-add-stream
- Polished: 2026-06-06

## 目的

libwebrtc の `RTCPeerConnectionDelegate` における `peerConnection(_:didAdd stream:)` / `peerConnection(_:didRemove stream:)` への依存を解消し、track ベースの `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` へ移行する。stream ベースのコールバックは Plan B 由来であり、Unified Plan を前提とする現在の WebRTC では deprecated 扱いとなっている。将来 libwebrtc から削除される可能性があるため、内部実装を track ベースへ移行しておく。

## 優先度根拠

- 純粋な内部リファクタリングであり、現状の stream ベース実装でも動作に問題は出ていない。
- 単独で急いで進める性質ではないため Low とする。

## 現状

`Sora/PeerChannel.swift:1326` の `peerConnection(_:didAdd stream:)` と `Sora/PeerChannel.swift:1359` の `peerConnection(_:didRemove stream:)` で stream ベースのコールバックを使用している。

`didAdd stream:` では以下の処理を行っている。
- 同一 `streamId` の stream が既に存在する場合は早期 return する重複チェック（`Sora/PeerChannel.swift:1333〜1339`）
- multistream 時に `stream.streamId == clientId` の場合（自ストリーム）を除外するフィルタ（`Sora/PeerChannel.swift:1342〜1349`）
- 受信音声のボリューム設定（`stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max`）（`Sora/PeerChannel.swift:1352`）
- `BasicMediaStream` を生成して `add(stream:)` へ渡す処理

`add(stream:)` / `remove(streamId:)` は `PeerChannelInternalHandlers.onAddStream` / `onRemoveStream`（`Sora/PeerChannel.swift:38, 41`）を経由し、`Sora/MediaChannel.swift:418` で利用者向けの公開クロージャ `SoraHandlers.onAddStream` / `SoraHandlers.onRemoveStream`（`Sora/MediaChannel.swift:36, 39`、いずれも `public`）へ伝播する。

`RTCPeerConnectionDelegate` には track ベースの `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` が用意されており、`streams` 引数として `[RTCMediaStream]` が渡されるため stream ID（msid）の取得が可能である。

## 設計方針

- 内部では `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` を用い、外部へ公開するイベントは既存の `onAddStream` / `onRemoveStream` を維持することで後方互換性を確保する。
- **track 到着タイミングと stream ID 取得**: `didAdd receiver:streams:` は track ごとに呼ばれる。`streams` が空の場合はログを出してスキップする（stream に関連付けられていない track は SDK では扱わない）。`streams.first` から `streamId`（msid）と `RTCMediaStream` を取得し、以下の順序で処理する:
  1. 重複チェック: 同一 `streamId` が `self.streams` 配列に存在する場合はスキップ（現行の `didAdd stream:` と同じロジック）
  2. 自ストリームフィルタ: `configuration.isMultistream` かつ `streams.first?.streamId == clientId` の場合はスキップ（`clientId` が nil のときは false 判定となりスキップしない。現行コードと同等の挙動）
  3. `streams.first` から取得した `RTCMediaStream` を `BasicMediaStream(peerChannel:nativeStream:)` に渡して生成し、`add(stream:)` を呼ぶ（step 1 で空チェック済みのため force-unwrap 可）
  後続 track が同一 stream ID を持つ場合は重複チェックでスキップされる。
- **audio volume 設定の移行**: `receiver.track` を `RTCAudioTrack` にキャストできる場合のみ `source.volume = MediaStreamAudioVolume.max` を設定する（キャスト失敗は video track であることを意味するためスキップする）。`RTCAudioTrack` の型名は `WebRTC.xcframework` のヘッダーで確認すること。
- **remove 側の stream ID 取得**: `RTCRtpReceiver` の `streamIds: [String]` プロパティが利用可能かを `WebRTC.xcframework` のヘッダーで確認すること。利用可能な場合は `rtpReceiver.streamIds.first` で stream ID を取得する。利用できない場合は `didAdd receiver:streams:` 時に receiver → streamId のマッピングを `PeerChannel` 内に保持するフォールバック方式を採用する。エントリが見つからない場合は何もしない（現行の `remove(streamId:)` と同等の動作）。
- **スレッド安全性**: `RTCPeerConnectionDelegate` のコールバックは libwebrtc の内部スレッドから呼ばれる。既存の `streams` 配列やフォールバック方式で追加する receiver マッピングへのアクセスが data race にならないよう、現行コードのスレッド保護方法（または保護不要の根拠）を実装前に確認すること。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動・引数型（`MediaStream`）・呼び出しタイミングを変えない。内部実装のみを track ベースへ切り替える。

## テスト方針

- sendrecv 接続でリモートストリームの追加・削除が正しく通知されることを実機で確認する。
- multistream 接続で複数のリモートストリームが正しく追加・削除されることを実機で確認する。
- `onAddStream` / `onRemoveStream` コールバックが変更前後で同じタイミング・引数で呼ばれることを確認する。

## 完了条件

- `Sora/PeerChannel.swift` の `peerConnection(_:didAdd stream:)` が `peerConnection(_:didAdd receiver:streams:)` へ置き換えられており、以下の既存処理がすべて維持されていること:
  - 重複チェック（同一 `streamId` の stream が既存の場合はスキップ）
  - 自ストリームフィルタリング（`streams.first?.streamId == clientId` の場合はスキップ）
  - audio track の `source.volume = MediaStreamAudioVolume.max` の設定
- `Sora/PeerChannel.swift` の `peerConnection(_:didRemove stream:)` が `peerConnection(_:didRemove rtpReceiver:)` へ置き換えられており、stream ID の特定と `remove(streamId:)` の呼び出しが正しく動作すること。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動が変更前後で一致すること。
- ログメッセージは英語、コメントは日本語で記述されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` が存在しない場合は新設すること）:
  ```
  - [UPDATE] リモートストリームの追加・削除通知を track ベースへ移行する
    - @voluntas
  ```
