# E2E テストをテスト種別ごとに分割する

- Priority: Medium
- Created: 2026-08-13
- Completed:
- Model: deepseek-v4-flash
- Branch: feature/refactor-split-e2e-tests
- Polished:

## 目的

`SoraTests/SignalingE2ETests.swift`（1079 行）が肥大化し、可読性・保守性が低下している。E2E テストをテスト種別ごとに分割し、今後のテスト追加（0077 の h265、0088 の音声ハイブリッドなど）を容易にする。

## 優先度根拠

テストコードの保守性の改善であり、SDK の機能や動作に影響しない。E2E テストの追加が今後も継続するため、肥大化する前に分割しておく価値がある。Medium。

## 現状

- `SoraTests/SignalingE2ETests.swift` は 1079 行の単一ファイルで、7 つのテスト（recvonly 3、sendonly 2、sendrecv 1、simulcast 1）と共通ヘルパー、検証ヘルパーが混在している
- MARK コメントでセクション分割されているが、ファイル全体の把握と変更時の影響範囲の判断が難しい
- simulcast テスト + 検証ヘルパーが約 400 行を占めており、最も大きい

## 設計方針

テスト種別ごとにクラス分割し、共通部分はベースクラスに集約する。

- `E2ETestBase.swift`: ベースクラス（@MainActor、setUp / tearDown、共通ヘルパー）
- `RecvonlyE2ETests.swift`: recvonly テスト 3 件
- `SendonlyE2ETests.swift`: sendonly テスト 2 件
- `SendrecvE2ETests.swift`: sendrecv テスト 1 件 + 検証ヘルパー
- `SimulcastE2ETests.swift`: simulcast テスト 1 件 + 検証ヘルパー

## 完了条件

- 分割後のテストが全件成功すること（ローカルのビルド・テスト、CI の E2E テスト）
- テストの実行順・検証内容が分割前と変わらないこと（リファクタリングのみで動作変更しない）
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法

- ベースクラスに集約するもの:
  - setUp / tearDown（Sora インスタンス生成、Logger 設定、AVAudioSession の復元、`audioSessionActivatedByTest` フラグ）
  - 共通ヘルパー: `buildChannelId`、`buildConfiguration`（2 種）、`disconnectAndVerify`、`inboundVideoByteCounts`、`hasInboundVideo`
  - ベースクラスのメソッドはサブクラスからアクセスするため、`private` は `internal` に変更する
- 各テストクラスは `E2ETestBase` を継承する。テストメソッド名（`testConnectRecvonly` 等）は変更しない
- 検証ヘルパーの配置（テスト種別に固有のものは各テストクラスに配置）:
  - `verifyVideoStats` / `verifyVideoCodecAndOutbound`: `SendrecvE2ETests`（sendrecv 専用）
  - `simulcastOutboundVideoStats` / `hasSimulcastOutboundVideo` / `verifySimulcastStats` / `verifySimulcastCodecAndOutbound`: `SimulcastE2ETests`（simulcast 専用）
- 分割後の想定行数:
  - `E2ETestBase.swift`: 約 150 行
  - `RecvonlyE2ETests.swift`: 約 90 行
  - `SendonlyE2ETests.swift`: 約 170 行
  - `SendrecvE2ETests.swift`: 約 170 行
  - `SimulcastE2ETests.swift`: 約 400 行
- 既存の `E2ETests` クラスは削除し、4 つのテストクラスに置き換える
