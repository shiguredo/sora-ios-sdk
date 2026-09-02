# 接続設定を immutable な Sendable snapshot へ変換する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-configuration-snapshot
- Polished: 2026-09-02

## 目的

利用者が渡した `Configuration` を非同期処理へそのまま保持せず、接続開始時に immutable かつ deep Sendable な内部 snapshot へ変換する。

`Configuration` が struct であることだけに依存せず、内部の参照型、`Any`、`Encodable`、handler を接続処理中に利用者から変更できない構造にする。

## 現状

`Sora/Configuration.swift` の `Configuration` は値型だが、次の non-Sendable または可変な値を保持する。

- `signalingConnectMetadata: Encodable?`
- `signalingConnectNotifyMetadata: Encodable?`
- `dataChannels: Any?`
- codec parameter と `ForwardingFilter.metadata` などの `Encodable?`
- 可変 class の `ICEServerInfo`
- 可変 class の `WebSocketChannelHandlers`
- 可変 class の `MediaChannelHandlers`
- audio device などの WebRTC / Objective-C object

`Sora/MediaChannel.swift` の initializer は `Configuration` を保存し、handler bag も参照のまま代入する。struct の浅い copy 後も、metadata、ICE server、handler の参照は利用者側と共有される。

`MediaChannel.connect` はバックグラウンドへ処理を移すため、利用者が `connect()` の戻り後に元の metadata や handler property を変更すると、接続処理と競合する。

現在の `Configuration` に `@unchecked Sendable` を付与しても、参照先の変更を防げないため解決にならない。

## 設計方針

### snapshot の生成時点

- `Sora.connect()` の同期 entry point 内で、最初の非同期 hop より前に `ConnectionConfigurationSnapshot` を生成する。
- snapshot 生成に失敗した場合は、WebSocket や PeerConnection を作る前に configuration error として終端する。
- `MediaChannel`、`PeerChannel`、`SignalingChannel` の内部処理は原則として snapshot を参照する。

### 値の凍結

- metadata と codec parameter は snapshot 生成時に JSON `Data` または Sendable な `JSONValue` へ encode する。
- `dataChannels` は許容形式を検証して immutable な値表現へ変換する。
- `ICEServerInfo` は URL、username、credential を immutable な内部 value type へ copy する。
- 接続中にサーバー（offer）由来で更新される値（`PeerChannel` の offer 受信時における `iceServerInfos` 更新など）は、凍結対象を利用者由来の設定に限定し、既存の更新経路は維持する。
- 配列、辞書、文字列、数値、enum は deep-safe な値だけを保持する。
- Objective-C / WebRTC object は一般設定 snapshot へ混在させず、専用 owner または adapter handle として分離する。

### handler の分離

- mutable handler bag を設定値から分離する。
- 既存 API では接続開始時に handler の immutable snapshot を取得し、接続途中の property 変更は進行中接続へ影響しない契約とする。
- `MediaChannel.handlers` など既存の公開 property 自体は維持し、接続処理中の配送は接続開始時に取得した snapshot を参照する。
- handler の executor 契約や新しい `@Sendable` event API は別 issue で扱う。

### 互換性

- 公開 `Configuration` の property と initializer は維持する。
- `Configuration: Sendable` または `@unchecked Sendable` は付与しない。
- 将来の新 API では deep Sendable な設定型と event handler を別型として公開できる内部構造にする。

## スコープ外

- `ICEServerInfo` を公開 struct に変更する破壊的 API 変更は行わない。
- 公開 RPC API の `Any` / `Sendable` 対応は別 issue とする。
- handler の `@Sendable` 化と配送 executor の公開契約は別 issue とする。
- 本 issue は `0100`（接続状態 owner）と `0101`（signaling owner）と同じファイル群・handler / snapshot 概念を共有するため、着手前に順序を調整する。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。

## テスト方針

モックやスタブは使用しない。

- 実 `Configuration` から snapshot を生成し、元の metadata object、ICE server、handler bag を変更しても snapshot が変化しないことを確認する。
- metadata、codec parameter、data channel 設定の encode 失敗が接続開始前に返ることを確認する。
- 実際の `Encodable` value type と reference type の両方で snapshot の不変性を検証する。
- 実 Sora への接続で、snapshot 化前後の signaling JSON と WebRTC 設定が一致することを確認する。
- metadata と data channel 設定の境界値、空値、不正 JSON object を検証する。
- テストには、struct の浅い copy では参照先を凍結できない理由を日本語コメントで明記する。

## 完了条件

- 最初の非同期 hop より前に `ConnectionConfigurationSnapshot` が生成されること。
- snapshot が immutable かつ deep Sendable であること。
- metadata、codec parameter、data channel 設定が snapshot 生成時に検証・凍結されること。
- ICE server が immutable な内部 value type へ copy されること。
- mutable handler bag が一般設定 snapshot から分離されていること。
- 接続開始後に `MediaChannel.handlers` などの handler property を変更しても進行中接続へ影響しないこと。
- 接続開始後に元の `Configuration` 内の参照型を変更しても進行中接続へ影響しないこと。
- 公開 `Configuration` に `@unchecked Sendable` を付与していないこと。
- signaling message と WebRTC 設定の既存挙動が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
