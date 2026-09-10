# deprecated な onAddStream への対応を行う

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-deprecated-on-add-stream
- Polished: 2026-09-03

## 目的

libwebrtc の `RTCPeerConnectionDelegate` における `peerConnection(_:didAdd stream:)` / `peerConnection(_:didRemove stream:)` への依存を解消し、track ベースの `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` へ移行する。stream ベースのコールバックは Plan B 由来のレガシー API であり、Unified Plan を前提とする現在の WebRTC では非推奨扱いである（`RTCConfiguration.h` の `sdpSemantics` で Plan B の廃止が予告されている）。将来 libwebrtc から削除される可能性があるため、内部実装を track ベースへ移行しておく。

## 優先度根拠

- 純粋な内部リファクタリングであり、現状の stream ベース実装でも動作に問題は出ていない。
- 単独で急いで進める性質ではないため Low とする。

## 現状

`Sora/PeerChannel.swift` の `RTCPeerConnectionDelegate` 実装である `PeerChannel` の `peerConnection(_:didAdd stream:)` と `peerConnection(_:didRemove stream:)` で stream ベースのコールバックを使用している。

`didAdd stream:` では以下の処理を行っている。
- 同一 `streamId` の stream が既に `PeerChannel.streams` 配列に存在する場合は早期 return する重複チェック
- multistream 時に `stream.streamId == clientId` の場合（自ストリーム）を除外するフィルタ
- 受信音声のボリューム設定（`stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max`）
- `BasicMediaStream` を生成して `add(stream:)` へ渡す処理

`add(stream:)` / `remove(streamId:)` は `PeerChannelInternalHandlers` の `onAddStream` / `onRemoveStream`（`Sora/PeerChannel.swift`、いずれも internal）を経由し、`Sora/MediaChannel.swift` の接続セットアップ処理で利用者向けの公開クロージャ `MediaChannelHandlers.onAddStream` / `MediaChannelHandlers.onRemoveStream`（`Sora/MediaChannel.swift`、いずれも `public`）へ伝播する。

`RTCPeerConnectionDelegate` には track ベースの `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` が用意されており、`streams` 引数として `[RTCMediaStream]` が渡されるため stream ID（msid）の取得が可能である。

## 設計方針

- 内部では `peerConnection(_:didAdd receiver:streams:)` / `peerConnection(_:didRemove rtpReceiver:)` を用い、外部へ公開するイベントは既存の `onAddStream` / `onRemoveStream` を維持することで後方互換性を確保する。
- **track 到着タイミングと stream ID 取得**: `didAdd receiver:streams:` は track ごと（receiver ごと）に呼ばれる。`streams` が空の場合はログを出してスキップする（stream に関連付けられていない track は SDK では扱わない）。`streams.first` から `streamId`（msid）と `RTCMediaStream` を取得し、以下の順序で処理する:
  1. 自ストリームフィルタ: `configuration.isMultistream` かつ `streams.first?.streamId == clientId` の場合はスキップ（`clientId` が nil のときは false 判定となりスキップしない。現行コードと同等の挙動）
  2. 音声ボリューム設定: `receiver.track` を `RTCAudioTrack` にキャストできる場合のみ `source.volume = MediaStreamAudioVolume.max` を設定する（キャスト失敗は video track であることを意味するためスキップする）。重複チェックより前に行い、重複と判定された receiver でも音声なら必ず設定する（映像 track が先に到着して stream が追加済みでも、後続の音声 track のボリュームを現行と同等に max にするため）
  3. 重複チェック: 同一 `streamId` が `self.streams` 配列に存在する場合はスキップ（現行の `didAdd stream:` と同じロジック。後続 track が同一 stream ID を持つ場合はここでスキップされる）
  4. `streams.first` から取得した `RTCMediaStream` を `BasicMediaStream(peerChannel:nativeStream:)` に渡して生成し、`add(stream:)` を呼ぶ（`streams` が空でないことは本節冒頭で確認済みのため force-unwrap 可）
- **remove 側の stream ID 取得**: `RTCRtpReceiver` には `streamIds: [String]` プロパティは存在しない（使用している libwebrtc m150（`Package.swift` の `libwebrtcVersion`、branch-heads/7871 相当）の `RTCRtpReceiver.h` で確認済み。プロパティは `receiverId` / `parameters` / `track` のみ）。そのため `didAdd receiver:streams:` 時に receiver → streamId のマッピングを `PeerChannel` 内に保持するフォールバック方式を採用する。
  - `didAddReceiver` と `didRemoveReceiver` では `RTCRtpReceiver` のインスタンスがそれぞれ新規に生成されて渡されるため、インスタンスの同一性ではマッピングを引けない。receiver ごとに一意な `receiver.receiverId`（libwebrtc の `RtpReceiverInterface::id()`）をキーとして保持する。
  - マッピングには `streams` が空でない receiver をすべて登録する（重複チェックでスキップされた receiver も登録する。どの receiver の削除通知でも stream を確実に削除できるようにするため）。
  - `didRemove rtpReceiver:` では該当 `receiverId` のエントリを探し、見つかれば `remove(streamId:)` を呼び、あわせてマッピングのエントリも除去する。エントリが見つからない場合は何もしない（現行の `remove(streamId:)` で対象が見つからない場合と同等の動作）。
- **スレッド安全性**: `RTCPeerConnectionDelegate` のコールバックは libwebrtc のシグナリングスレッドから呼ばれる。現行コードは `streams` 配列へのアクセスに同期機構を使用しておらず、`add(stream:)` / `remove(streamId:)` の他呼び出し元（SDP パイプラインの `initializeSenderStream`）も同じ経路で実行される。receiver マッピングへのアクセスは現行の `streams` と同じ扱いでよい（本変更で新たな実行スレッドやアクセス経路は増えない）。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動・引数型（`MediaStream`）・呼び出しタイミングを変えない。内部実装のみを track ベースへ切り替える。

## テスト方針

- sendrecv 接続でリモートストリームの追加・削除が正しく通知されることを実機で確認する。
- multistream 接続で複数のリモートストリームが正しく追加・削除されることを実機で確認する。
- `onAddStream` / `onRemoveStream` コールバックが変更前後で同じタイミング・引数で呼ばれることを確認する。

## 完了条件

- `Sora/PeerChannel.swift` の `peerConnection(_:didAdd stream:)` が `peerConnection(_:didAdd receiver:streams:)` へ置き換えられており、以下の既存処理がすべて維持されていること:
  - 重複チェック（同一 `streamId` の stream が既存の場合はスキップ）
  - 自ストリームフィルタリング（`streams.first?.streamId == clientId` の場合はスキップ）
  - audio track の `source.volume = MediaStreamAudioVolume.max` の設定（映像 track が先に到着し stream が既に追加済みの場合でも、後続の音声 receiver に必ず設定されること）
- `Sora/PeerChannel.swift` の `peerConnection(_:didRemove stream:)` が `peerConnection(_:didRemove rtpReceiver:)` へ置き換えられており、`receiverId` によるマッピングからの stream ID の特定と `remove(streamId:)` の呼び出しが正しく動作すること。
- 公開 API の `onAddStream` / `onRemoveStream` の挙動が変更前後で一致すること。
- リモートストリームが同一 `streamId` につき 1 回だけ追加・削除されること（映像 track と音声 track の到着順に依存しない）。
- ログメッセージは英語、コメントは日本語で記述されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` が存在しない場合は新設すること）:
  ```
  - [UPDATE] リモートストリームの追加・削除通知を track ベースへ移行する
    - @voluntas
  ```
