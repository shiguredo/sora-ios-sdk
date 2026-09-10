# E2E テストをテスト種別ごとに分割する

- Priority: Medium
- Created: 2026-08-13
- Completed: 2026-08-13
- Model: deepseek-v4-flash
- Branch: feature/refactor-split-e2e-tests
- Polished: 2026-08-13

## 目的

E2E テストをテスト種別ごとに分割し、今後のテスト追加（0077 の h265、0088 の音声ハイブリッドなど）を容易にする。

## 優先度根拠

テストコードの保守性の改善であり、SDK の機能や動作に影響しない。E2E テストの追加が今後も継続するため、肥大化する前に分割しておく価値がある。Medium。

## 現状

- `SoraTests/SignalingE2ETests.swift` は 1079 行の単一ファイルで、7 つのテスト（recvonly 3、sendonly 2、sendrecv 1、simulcast 1）と共通ヘルパー、検証ヘルパーが混在している
- MARK コメントでセクション分割されているが、ファイル全体の把握と変更時の影響範囲の判断が難しい
- simulcast テスト + 検証ヘルパーが約 400 行を占めており、最も大きい

## 設計方針

テスト種別ごとにクラス分割し、共通部分はベースクラスに集約する。テストメソッド名と検証内容は変更しない（リファクタリングのみ）。

## 完了条件

- 分割後のテストが全件成功すること（ローカルのビルド・テスト、CI の E2E テスト）
- 分割前後でコードの純粋移設であること（`git diff` で分割前後の変更全体を確認し、`XCTAssert*` 等の検証コードとテストメソッド名に変更がないこと）
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

なお、XCTest はクラス間・メソッド間の実行順を保証しないため、実行順の一致は完了条件としない。各テストは毎回 `sora = Sora()` を生成し、sendrecv / simulcast は一意な channelId（`buildChannelId(unique: true)`）を使用するため、実行順に依存しない。

## 解決方法

分割後のファイル構成:

- `E2ETestBase.swift`: ベースクラス（約 160 行）
- `RecvonlyE2ETests.swift`: recvonly テスト 3 件（約 100 行）
- `SendonlyE2ETests.swift`: sendonly テスト 2 件（約 170 行）
- `SendrecvE2ETests.swift`: sendrecv テスト 1 件 + 検証ヘルパー（約 300 行）
- `SimulcastE2ETests.swift`: simulcast テスト 1 件 + 検証ヘルパー（約 400 行）

ベースクラス（`E2ETestBase`）に集約するもの:

- setUp / tearDown（Sora インスタンス生成、Logger 設定、AVAudioSession の復元）
- プロパティ: `sora`、`originalLogLevel`、`originalAudioCategory` / `originalAudioMode` / `originalAudioOptions`、`audioSessionActivatedByTest`、`InvalidURLError` 構造体
- 共通ヘルパー: `buildChannelId`、`buildConfiguration`（2 種）、`disconnectAndVerify`、`inboundVideoByteCounts`、`hasInboundVideo`
- ファイル先頭の環境変数ドキュメント（`SORA_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX`）
- `disconnectAll(channels: [MediaChannel])`: sendrecv と simulcast に 16 行ずつ重複している切断ヘルパーを集約する（分割の副次効果として重複を排除する）
- 各ファイルの import は `AVFoundation` / `XCTest` / `@testable @preconcurrency import Sora` が必要

アクセス制御の変更:

- `E2ETestBase` はサブクラスからアクセスするため、以下の `private` を `internal` に変更する:
  - メソッド: `buildChannelId`、`buildConfiguration`（2 種）、`disconnectAndVerify`、`inboundVideoByteCounts`、`hasInboundVideo`、`disconnectAll`
  - プロパティ: `sora`（全サブクラスのテストメソッドが使用）、`audioSessionActivatedByTest`（`testSendonlyDummyAudio` が書き込む）
  - `originalLogLevel` 等の setUp / tearDown 専用プロパティと `InvalidURLError` は `private` のまま
- `E2ETestBase` は継承されるため `final` にしない。サブクラス 4 つは既存スタイルどおり `final class` にする
- `@MainActor` はサブクラスに継承されるため、サブクラスへの明示的な付与は不要

検証ヘルパーの配置（テスト種別に固有のものは各テストクラスに配置する）:

- `verifyVideoStats` / `verifyVideoCodecAndOutbound`: `SendrecvE2ETests`（`testSendrecvDummyVideo` 専用）
- `simulcastOutboundVideoStats` / `hasSimulcastOutboundVideo` / `verifySimulcastStats` / `verifySimulcastCodecAndOutbound`: `SimulcastE2ETests`（`testSimulcastDummyVideo` 専用）
- これらは単一クラス内で完結するため、`private` のまま移動できる

既存の `E2ETests` クラスと `SoraTests/SignalingE2ETests.swift` は削除し、上記 5 ファイルに置き換える。

分割による副作用と確認手順:

- `E2ETestBase` はクラス名が "Base" で終わるため、XCTest のテストスイート検出対象（"Test" / "Tests" で始まるか終わるクラス）にならない。ベースクラスにはテストメソッドを置かない
- recvonly / sendonly テストは非一意なチャンネル ID（`e2e-test`）を使用するため、CI の単一シミュレータ・直列実行を前提とする（並列実行設定に変更する場合はチャンネル ID の一意化が必要）
- 確認手順:
  - `make build`（`SWIFT_VERSION=6` でのビルド）
  - `make fmt-lint` / `make lint`
  - ローカルの `xcodebuild test`（環境変数未設定のため E2E テストは XCTSkip される）
  - CI の e2e ジョブ（Sora サーバー + 環境変数が必要）

他 issue との整合:

- 0077（h265）は「`E2ETests` に追加」と記載されており、分割後に参照先がなくなるため、0077 の実装時は `SendonlyE2ETests` に追加するよう本文を更新する
- 0088（音声ハイブリッド）も `SoraTests/SignalingE2ETests.swift` を参照しているため、`SendrecvE2ETests` に追加するよう本文を更新する
- 0079〜0083 / 0087 も同様に `E2ETests` を参照しているため、実装時に分割後のクラスへ追加する

## 実装結果

- `SoraTests/SignalingE2ETests.swift`（1079 行）を削除し、5 ファイルに分割した
  - `E2ETestBase.swift`: ベースクラス（@MainActor、setUp / tearDown、共通ヘルパー 6 種、`disconnectAll(channels:)`）
  - `RecvonlyE2ETests.swift`: recvonly テスト 3 件
  - `SendonlyE2ETests.swift`: sendonly テスト 2 件
  - `SendrecvE2ETests.swift`: sendrecv テスト 1 件 + 検証ヘルパー 2 種
  - `SimulcastE2ETests.swift`: simulcast テスト 1 件 + 検証ヘルパー 4 種
- アクセス制御: `sora` / `audioSessionActivatedByTest` / 共通ヘルパー 6 種 / `disconnectAll` を `internal` に変更した（サブクラスからアクセスするため。setUp / tearDown 専用のプロパティと `InvalidURLError` は `private` のまま）
- sendrecv と simulcast で 16 行ずつ重複していた切断ヘルパーを `disconnectAll(channels:)` としてベースクラスに集約した
- テストメソッド名と検証内容は変更していない（純粋移設）
- `E2ETestBase` は non-final（サブクラスが継承するため）、サブクラス 4 つは `final class`
- `CHANGES.md` の `### misc` に「[CHANGE] E2E テストをテスト種別ごとに分割する」を追記済み
- 検証: `SWIFT_VERSION=6` ビルド成功、全テスト成功、swift-format / SwiftLint 通過
