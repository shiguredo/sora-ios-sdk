# Sora target に残る SendableClosureCaptures 警告を解消する

- Created: 2026-09-28
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-remove-sora-sendable-closure-captures
- Polished: {YYYY-MM-DD}

## 目的

Sora target に残る `#SendableClosureCaptures` 警告 24 件を解消し、`0108` の Sora target warnings-as-errors ゲートを有効化できる状態にする。`0108` の前提はこの警告群の解消を `0155` に求めているが、`0155` が解消するのは 1 件だけで、残りの担当が無い。

## 現状

2026-09-28 の Xcode 26.6 / Swift 6.3.3 で `Sora/` を Swift 6 言語モードで型検査すると `#SendableClosureCaptures` 警告が 26 件出る。内訳は次のとおりである (括弧内は 1 file あたりの件数)。

- `Sora/PeerChannel.swift` 12 件: `createAnswer` (8)、`initializeAudioInput` (1)、`handleSignalingOverWebSocket(_:)` (1)、`scheduleWebSocketDisconnectIfNeeded` (1)、`scheduleDisconnectTimerIfNeeded` (1)
- `Sora/MediaChannel.swift` 5 件: `connect` (2)、`getStats(handler:)` (3)
- `Sora/CameraVideoCapturer.swift` 3 件: `startNative` (2)、`stopNative(completionHandler:)` (1)
- `Sora/NativePeerChannelFactory.swift` 2 件: `createClientOfferSDP` (2)
- `Sora/ConnectionTimer.swift` 1 件: `run(timeout:handler:)` (1)
- `Sora/DataChannel.swift` 1 件: `dataChannel(_:didReceiveMessageWith:)` (1)
- `Sora/Sora.swift` 1 件: `0155` が解消する
- `Sora/Utilities.swift` 1 件: `Utilities.Stopwatch` の capture。`0115` の `Stopwatch` 削除で消える見込み

`Sora/Sora.swift` と `Sora/Utilities.swift` を除く 24 件が本 issue の対象である。`-warnings-as-errors` ではこれらが error になり、`0108` のゲートを塞いでいる。

対処の既存方針は、`0118` の「実行文脈が一致することを契約にしない」と、`0155` の `ConnectErrorHandlerBox` (保持する closure が `init` で確定した不変値で、1 つの block へ 1 回だけ渡す用途限定の box) である。同種の box は `Sora/CameraVideoCapturer.swift` の `CameraOperationCompletionBox` と `Sora/SignalingState.swift` の `SignalingQueueBlock` にもある。

## 前提となる issue

- `0155` (open): `Sora.connect` の設定エラー通知経路の 1 件を解消する。本 issue は `0155` の box の書き方を前例にする。
- `0115` (pending): `Utilities.Stopwatch` を削除する。`Sora/Utilities.swift` の 1 件はこの削除で消えるため本 issue の対象外とする (`0115` が先に完了していれば対象は 23 件になる)。
- `0108` (open): Sora target の warnings-as-errors 化。本 issue の完了が前提になる。`0108` の残存警告の担当記述を本 issue へ更新する。

## 設計方針

- 経路ごとに、用途を限定した内部 box または `Sendable` な値への写しで解消する。box を追加する場合は `0155` の `ConnectErrorHandlerBox` と同様に、保持する closure が `init` で確定した不変値であること、新しい並行性を導入しないこと、1 つの実行文脈へ 1 回だけ渡す使用契約であることを日本語コメントに書く (規約によりソースコードへ issue 番号は書かない)。
- `@unchecked Sendable` を付けるのは「入れ物」だけにし、capture した closure とその捕捉状態を `Sendable` にするものではないことをコメントに書く。捕捉状態の同期は、呼び出しスレッドを保証しない既存の挙動の下で利用者の責務である。
- 実行文脈の一致を契約にしない (`0118` の方針)。直列 queue 上での実行を根拠にできる経路はその事実を根拠として書き、根拠が無い経路は capture する値を `Sendable` な型へ写すか、box の外へ値を出さない構造へ直す。
- `@Sendable` 化で解消する場合は、公開 handler の型を変更しない (`0110` が legacy handler の型を変えない方針)。公開 API を変更する必要がある場合は、`0107` の consumer package と公開 API baseline への影響を確認し、同じ変更で baseline を再生成する。
- `0108` の「未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならない」に反しない根拠を、経路ごとにコメントと PR で示す。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` を追加する (公開 API と利用者の挙動の変更が無い場合)。

## スコープ外

- `Sora/Sora.swift` の 1 件 (`0155`)。
- `Sora/Utilities.swift` の 1 件 (`0115` の `Stopwatch` 削除)。
- WebRTC / AVFoundation module 由来の `add '@preconcurrency'` 警告 4 件 (`0174`)。
- `#DeprecatedDeclaration` 警告 (`0108` の除外設定と `0138`)。
- test target の warnings-as-errors ゲート (`0171`)。

## 変更対象

- `Sora/PeerChannel.swift` / `Sora/MediaChannel.swift` / `Sora/CameraVideoCapturer.swift` / `Sora/NativePeerChannelFactory.swift` / `Sora/ConnectionTimer.swift` / `Sora/DataChannel.swift`: 上記の経路ごとの解消
- `SoraTests/`: 解消した経路の回帰テスト (モックやスタブは使わない)
- `CHANGES.md`: `## develop` の `### misc` の `[UPDATE]`
- `issues/0108-update-swiftpm-language-mode.md`: 残存警告の担当を本 issue へ更新する

## テスト方針

モックやスタブは使用しない。

- `Sora/` を Swift 6 言語モードで型検査し、`Sora/Utilities.swift` を除いて `#SendableClosureCaptures` が 0 件になり、他の警告が増えていないこと (変更前後の log を比較する)。
- 修正した各経路の回帰テストを追加する。非同期 callback の通知順序・呼び出し回数・呼び出しスタック外の検証は、`SoraTests/ConnectConfigurationValidationTests.swift` の形 (expectation と、呼び出しスレッドの目印による同期通知の検出) に揃える。
- `make build` が成功すること (SwiftPM の cache に書き込めない環境では `Sora/` の型検査で代替し、その旨を「解決方法」に記録する)。
- `SoraTests` が失敗 0 件であること。
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること (公開 API を変更した場合は baseline を同じ変更で再生成する)。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/Utilities.swift` を除く `#SendableClosureCaptures` 警告が 0 件になり、他の警告が増えていないこと。
- 追加した box に安全性の根拠と使用契約が日本語コメントで書かれ、コメントに issue 番号が書かれていないこと。
- 追加・変更したテストが成功し、既存テストも失敗 0 件であること。
- `issues/0108-update-swiftpm-language-mode.md` の残存警告の担当記述が本 issue へ更新されていること。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` が追加されていること (公開 API の変更が無い場合)。

## 解決方法
