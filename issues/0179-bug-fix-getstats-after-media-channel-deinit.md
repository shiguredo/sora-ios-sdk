# `MediaChannel` の解放開始後に `getStats` の完了 block が成功を返し得る問題を修正する

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/fix-getstats-after-media-channel-deinit
- Polished: {YYYY-MM-DD}

## 目的

`MediaChannel` の解放が始まった後に `RTCPeerConnection.statistics` の完了 block が走った場合、統計を成功として handler へ返し得る状態を直す。

変更前は完了 closure が `[weak self]` で `MediaChannel` を捕捉していたため、解放が始まると `self` が nil になり、handler は `MediaChannel is unavailable` の失敗を 1 回受け取っていた。`0177` はこの closure から `MediaChannel` の捕捉を消し、`PeerChannelTransportStorage` への弱参照と `MediaChannelStateStorage` (強参照) で現在の状態を読む形にした。この形では `MediaChannel` の `deinit` の実行中も `peerChannel` (stored property) がまだ生存するため `transportStorage` の弱参照は nil にならず、`stateStorage` は `.connected` のままなので同一性判定を通過し、成功を返す。

## 現状

- `Sora/MediaChannel.swift` の `deinit` は `prepareForDisconnect(error: nil)` と `_peerChannel?.disconnect(error: nil, reason: .user)` を呼ぶ。`prepareForDisconnect` は `state` を変えないため、`deinit` の実行中は `state` が `.connected` のままになる。
- `MediaChannelGetStatsContext` は `handler` / `peerConnection` / `stateStorage` (強参照) / `transportStorage` (弱参照) を保持する。完了 block は `transportStorage` が nil なら失敗を返し、nil でなければ `stateStorage.state == .connected` と `currentPeerConnection === context.peerConnection` を確認して成功を返す。
- Swift の弱参照は解放の開始時 (deinit の実行前) に nil 化される。変更前の `[weak self]` はこの性質に依存して解放開始を検出していた。`0177` の形は `MediaChannel` を捕捉しないため、この検出点を失っている。
- `0177` はこの挙動差を「`MediaChannel` の `deinit` 中に statistics の完了 block が走る狭い窓では、`transportStorage` が生存しているため `MediaChannel is unavailable` ではなく、`stateStorage` が `.connected` のままなら同一性判定を通過して success を返し得る。変更前の `[weak self]` はこの窓でも failure を返していた」と `## 残った懸念` に記録している。
- 窓は狭いが、`MediaChannel` を解放した利用者の handler に、解放済みチャンネルの統計が成功として届き得る。戻り値の `Statistics` は生きている `RTCPeerConnection` から取得した値であり、利用者は「チャンネルが有効な間に取得できた統計」と区別できない。

## 設計方針

- 解放の開始を、完了 block が読む storage へ明示的に記録する。`MediaChannel.deinit` の先頭で `stateStorage` の終端フラグを立て、完了 block が `state == .connected` を確認する前にこのフラグを確認して失敗を返す。
- 判定の追加は `getStats` の完了 block の配送先・呼び出し回数・順序を変えない。失敗は変更前と同じ `SoraError.peerChannelError(reason: "MediaChannel is unavailable")` とし、1 回だけ返す。
- 終端フラグは `MediaChannelStateStorage` の `lock` 配下で読み書きする。`deinit` からの書き込みは `connectionLifecycleLock` を取らない (`deinit` 中に他の lock を取ると、切断経路が保持している lock と競合し得る)。lock 順序に新しい辺を増やさない。
- `MediaChannel` の解放中に走る別の完了 block (`nativeChannel` を閉じる経路など) の挙動は変えない。本 issue が直すのは `getStats` の完了 block だけである。
- 完了 block から `MediaChannel` 本体を捕捉する形には戻さない (`0177` が消した捕捉を再導入しない)。解放の開始は storage のフラグで伝える。

## 前提となる issue

- `0177` (2026-09-29 完了): `MediaChannelGetStatsContext` の `stateStorage` / `transportStorage` の追加元。本 issue はこの形を保ったまま解放の検出を戻す。
- `0176` (open): `MediaChannel.getStats` の同一性判定の回帰テストと `#if DEBUG` の seam。本 issue のテストも同じ harness (`setConnectionStateForTesting(_:)` と `statistics` の完了 block を観測する seam) を使える可能性がある。実装時に `0176` の seam と重複しない形を決める。
- `0165` (完了): lock を保持したまま libwebrtc や利用者 handler を呼ばない方針。本 issue もこれに従う。

## 変更対象

- `Sora/MediaChannel.swift`: `MediaChannelStateStorage` への終端フラグの追加、`MediaChannel.deinit` での設定、`getStats` の完了 block での確認
- `SoraTests/`: `MediaChannel` の解放開始後に完了 block が失敗を返すことの回帰テスト
- `CHANGES.md`: `## develop` の `[FIX]` 群への追記 (担当者行 `@t-miya` を含める)

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- `MediaChannel` の解放開始後に `statistics` の完了 block を走らせ、handler が失敗を 1 回だけ受け取ることを固定する。実装時に、`0176` が設計した `#if DEBUG` の seam と同じ方式 (完了 block が判定の直前で呼ぶ internal な seam) で順序を確定的に作れるかを確認する。`DispatchSemaphore` で完了 block を停止させる方式は、`statistics` が signaling thread の完了を待つ場合に呼び出し元が停止するため使わない (`0176` の判断と同じ)。
- seam を追加できない場合は、その理由と代替の検証内容 (実装の読み合わせと `SoraTests` 全体を回帰の正本にすること) を `## 解決方法` に記録する。
- `SoraTests` 全体を実行し失敗 0 件であること。
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- 退行検出の確認: 終端フラグの確認を削った作業ツリーで追加したテストが失敗することを確認する。確認用の変更は commit しない。

## 完了条件

- `MediaChannel` の解放開始後に `getStats` の完了 block が走った場合、handler が `MediaChannel is unavailable` の失敗を 1 回だけ受け取ること。変更前の `[weak self]` と同じ配送であること。
- 追加したテストが現行の実装で成功し、終端フラグの確認を削ると失敗すること。
- `getStats` の完了 block が `MediaChannel` を捕捉していないこと (`#SendableClosureCaptures` が増えていないこと)。
- `SoraTests` 全体が失敗 0 件で、`make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- 公開 API のシグネチャと利用者に見える通常の接続経路の挙動が変わっていないこと。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `CHANGES.md` の `## develop` の `[FIX]` にエントリが担当者行付きで追加されていること。

## スコープ外

- `MediaChannel.state` の computed property 化と単一所有への整理。別 issue で扱う。
- `MediaChannel` の解放中に走る `getStats` 以外の完了 block の配送。
- `MediaChannel` への `Sendable` 準拠の追加。
- `0108` の Sora target warnings-as-errors ゲートと `0115` の `Utilities.Stopwatch` の削除。

## 解決方法
