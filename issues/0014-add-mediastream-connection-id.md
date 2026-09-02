# MediaStream に connectionId を追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-mediastream-connection-id
- Polished: 2026-09-02

## 目的

`MediaStream`（内部実装は `BasicMediaStream`）が公開している `streamId` はストリームを識別する WebRTC レベルの ID であり、Sora の接続 ID（`connectionId`）と同じ値になるとは限らない。`MediaStream` プロトコルには `mediaChannel: MediaChannel? { get }` が公開されており `stream.mediaChannel?.connectionId` という間接的な経路が存在するが、`mediaChannel` は弱参照のため解放後は `nil` になる可能性がある。`connectionId` プロパティを `MediaStream` プロトコルに直接追加することで、接続 ID を安全かつ直感的に取得できるようにする。

## 依存関係

`0013-investigate-local-stream-id-connection-id`（送信側ストリームの streamId 改善検討）と関連する。0013 は「代替アプローチとして `MediaStream` ラッパーに `connectionId` プロパティを持たせる方式は native streamId に依存しないため後方互換性の面で安全」と結論付けており、本 issue はその方針に沿う実装を行う。

## 優先度根拠

Low とする。具体的な不具合報告ではなく、API のわかりやすさ向上を目的とした改善であるため、緊急性は低い。

## 現状

`MediaStream` プロトコルには `streamId`、`mediaChannel` 等が公開されているが、`connectionId` を直接返すプロパティが存在しない。`MediaChannel` には `connectionId: String?` が公開されており（`Sora/MediaChannel.swift` の `MediaChannel.connectionId` プロパティ）、`stream.mediaChannel?.connectionId` という間接経路が存在する。しかし `mediaChannel` は弱参照のため解放後に `nil` を返し、信頼性に欠ける。

`BasicMediaStream` は `peerChannel: PeerChannel` への強参照を保持しており（`Sora/MediaStream.swift` の `BasicMediaStream.peerChannel` プロパティ）、`PeerChannel` は offer 受信時に `connectionId`（型 `String?`）を保持している（`Sora/PeerChannel.swift` の `PeerChannel.connectionId` プロパティ、設定箇所は `PeerChannel.handleSignalingOverWebSocket`）。`peerChannel` は強参照のため、`mediaChannel` が解放された後も `peerChannel.connectionId` は参照可能である。

送信側 `BasicMediaStream` の `streamId` は `configuration.publisherStreamId`（デフォルト `"mainStream"`）が設定されており（`Sora/PeerChannel.swift` の `PeerChannel.initializeSenderStream` 内の `createNativeSenderStream(streamId: configuration.publisherStreamId)`）、`connectionId` とは異なる値である。受信側 `BasicMediaStream` の `streamId` は Sora サーバーから送られてきた `RTCMediaStream.streamId` がそのまま設定される（`Sora/MediaStream.swift` の `BasicMediaStream.init(peerChannel:nativeStream:)`）。Sora サーバーが受信側ストリームの msid として `connectionId` を設定するかどうかはサーバー実装に依存するため、`streamId` を `connectionId` のエイリアスとして扱うことはできない。

## 設計方針

1. `MediaStream` プロトコルに `connectionId: String? { get }` を追加する（Optional とする。offer 受信前は `nil` であるため。offer 受信後は `SignalingOffer.connectionId` が non-Optional `String` のため常に非 nil となる）。
2. `BasicMediaStream` に computed property として `var connectionId: String? { peerChannel.connectionId }` を実装する。`peerChannel` への強参照を通じて取得するため、`mediaChannel` が弱参照解放後であっても正確な値が得られる。送信側・受信側ともに同じ経路で `connectionId` を参照できる。
3. 既存の `streamId` は変更しない。後方互換を維持する。

## テスト方針

`BasicMediaStream` は `internal` クラスだが、`SoraTests/ScreenCaptureFrameGenerationTests.swift` の `makeSenderStream` が実接続なしで `BasicMediaStream(peerChannel:nativeStream:)` を構築しており、`MediaChannel.peerChannel` から `PeerChannel` も取得できる。同様のパターンで `MediaChannel.peerChannel.connectionId` に値を設定してから `BasicMediaStream` を構築すれば、モック不使用のままプロパティ委譲の単体テストが可能である。本 issue の変更はプロパティ委譲の 1 行実装でありコードパスは trivial だが、委譲の回帰防止のため単体テストを追加する。実接続が必要な非 nil 時の挙動は統合テストや実機動作確認で検証する。

## 完了条件

- `MediaStream` プロトコルに `var connectionId: String? { get }` が追加されること。
- `BasicMediaStream` が `connectionId` を `peerChannel.connectionId` として実装すること。
- `connectionId` のプロパティ委譲を検証する単体テストが追加されること（`MediaChannel.peerChannel.connectionId` に値を設定して `BasicMediaStream` を構築し、`connectionId` が同値を返すことを確認する）。
- 既存の `streamId` の挙動が変更されていないこと（後方互換）。
- `CHANGES.md` の `develop` セクションに `[CHANGE]` エントリと担当者行を追記すること（`public protocol` への property 追加は外部実装者にコンパイルエラーを引き起こす後方互換のない変更）。
