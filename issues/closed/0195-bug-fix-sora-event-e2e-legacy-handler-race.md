# SoraEventE2ETests の legacy handler がシグナリング受信を取り逃す race を修正する

- Created: 2026-10-26
- Completed: 2026-10-27
- Branch: feature/fix-sora-event-e2e-legacy-handler-race
- Polished: 2026-10-26

## 目的

E2E Test が断続的に失敗する原因を解消し、CI を安定させる。

## 現状

- 2026-10-26 の develop へのマージ後の E2E Test ([run 40277143561](https://github.com/shiguredo/sora-ios-sdk/actions/runs/40277143561)) の attempt 1 で、`SoraEventE2ETests.testSingleConnectionDeliversLifecycleSignalingAndLegacyCorrespondence` が失敗した。
- 失敗した assertion は `legacySignalingCount` が `1` 以上であることを期待する `XCTAssertGreaterThanOrEqual` で、実際は `0` だった。
- 同じ run の再実行 (attempt 2) では成功し、attempt 1 でも失敗は当該テスト 1 件だけで、他のテストは失敗していない (522 テスト中 7 件はスキップ)。PR #435 の E2E と直前の develop の E2E も成功しており、断続的に発生する flaky である。
- 原因はテスト側のハンドラ登録タイミングの race である。
  - テストは接続完了 handler の中で `mediaChannel.subscribeEvents()` を同期的に開始している。
  - legacy の `onReceiveSignalingJSON` は、その handler から `DispatchQueue.main.async` で main queue に載せた後に設定している。
  - 接続直後にシグナリングを受信すると、新 API はそのイベントを受け取るが、legacy handler はまだ設定されておらず取り逃す。
  - テストは新 API の受信を待ってから切断するため、legacy handler が後から受信する保証がない。
- SDK は配送時点で設定されているハンドラにだけイベントを配送する挙動であり、SDK 側の不具合ではない。

## 設計方針

- テスト側で legacy handler を接続前に登録する。`Configuration.mediaChannelHandlers` の参照は `MediaChannel` の初期化時に `handlers` へ設定され、同じ `MediaChannelHandlers` インスタンスが共有されるため、`config.mediaChannelHandlers.onReceiveSignalingJSON` を `sora.connect` の前に設定すれば、接続直後の受信も取り逃さない。
- 接続後に `mediaChannel.handlers.onReceiveSignalingJSON` を設定する現在のコードは削除する。
- SDK の実装は変更しない。

## 完了条件

- `SoraEventE2ETests.testSingleConnectionDeliversLifecycleSignalingAndLegacyCorrespondence` が、legacy handler の登録タイミングに依存せず成功すること
- 変更がテストコードだけに限定されていること
- E2E Test を複数回実行しても同じ失敗が再発しないこと
- `make fmt-lint` と `make lint` が成功すること

## 解決方法

2026-10-27 に対応した。原因はテスト側の legacy handler の登録タイミングにあり、SDK の実装・公開 API は変更していない。

`SoraTests/SoraEventE2ETests.swift` の `testSingleConnectionDeliversLifecycleSignalingAndLegacyCorrespondence` を次のとおり修正した。

- `MediaChannel` のイベント購読を `sora.handlers.onAddMediaChannel` で接続の開始前に開始し、接続前の signaling も新 API で観測できるようにした
- `sora.connect` の前に `config.mediaChannelHandlers.onReceiveSignalingJSON` を設定し、受信した JSON を配送順に記録するようにした
- 接続完了 handler 内の `mediaChannel.handlers.onReceiveSignalingJSON` の設定を削除した
- legacy handler と新 API が受信した signaling JSON を順序込みで比較し、接続前の signaling を含めて同じ受信を観測したことを検証するようにした
- 接続前の `signalingReceivedJSON` は `connectionId` が確定する前のため nil になる契約を検証し、接続後の signaling の配送も待つようにした
- `MediaChannel` は `Configuration.mediaChannelHandlers` のインスタンスを `handlers` として共有するため、接続前に登録した handler でも接続前の受信を取り逃さない

確認した内容は次のとおり。

- `make fmt-lint` と `make lint` が成功した (CI の `swift6-consumer` job でも成功)
- `SoraTests` 全体の型チェックが成功した
- E2E Test を実行し、対象テストを含む 522 テスト (7 スキップ) が失敗 0 だった
  - run 40445693799 の e2e job (attempt 1) では対象テストが成功したが、別テストの WebSocket 接続失敗で job が失敗したため再実行した
  - 同じ run の e2e job (attempt 2) で 522 テスト (7 スキップ) が失敗 0 だった
  - 同じ run の tsan job も成功した

## 参考

- [E2E Test run 40277143561](https://github.com/shiguredo/sora-ios-sdk/actions/runs/40277143561)
- テストが追加されたコミット: `0e62ddf` (0110)
