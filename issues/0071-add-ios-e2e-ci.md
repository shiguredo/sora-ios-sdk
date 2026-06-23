# iOS E2E テストを GitHub Actions の self-hosted macOS runner で CI 実行できるようにする

- Priority: Medium
- Created: 2026-06-22
- Completed:
- Model: GPT-5
- Branch: feature/add-ios-e2e-ci
- Polished: 2026-06-22

## 目的

Sora iOS SDK の E2E テストを、GitHub Actions の self-hosted macOS runner から継続的に実行できるようにする。

本 issue のスコープは **`recvonly` での接続テストを CI 実行できる基盤整備** とする。ダミー映像、ダミー音声を利用した送信系テストは 0067・0068 の完了後に別 issue で扱い、本 issue には含めない。

## 関連 issue

- 0067 (`feature/add-dummy-video-source`): ダミー映像送信。本 issue の前提ではないが、送信系 E2E の前段となる
- 0068 (`feature/add-dummy-audio-source`): ダミー音声送信。同上
- 0070 (`feature/change-migrate-to-webrtc-c-xcframework`): `WebRTC.xcframework` から `libwebrtc_c.xcframework` への移行。`Package.swift` と `SoraTests/` 構成を変更するため 0070 Phase 1〜4 と競合の可能性がある。本 E2E 基盤は `WebRTC.xcframework` のままで構築可能であり、0070 の進行に応じて E2E 側も追従改修を行う

## 優先度根拠

既存の build workflow はビルドと lint のみであり、E2E テストが CI に組み込まれていない状態では接続・切断・受信側シグナリングの回帰を継続的に検出できない。`recvonly` 接続であれば物理カメラ・物理マイクやダミー送信ソースに依存せず、追加作業の中心は workflow と環境注入・シークレット露出対策の整理であるため Medium とする。

## 現状

既存の `.github/workflows/build.yml` は GitHub-hosted の `macos-26` runner 上で以下のみを実行している。

- `xcodebuild ... clean build` によるビルド
- WebRTC Non-public API チェック
- `make fmt-lint`
- `make lint`

`xcodebuild test` は実行しておらず、E2E テスト用の job も存在しない。

`Package.swift` には `SoraTests` test target が存在するが、現状の `SoraTests` は `RidTests` などの軽量テストが中心であり、CI からシグナリング先や認証情報を注入して実行する E2E 前提の構成にはなっていない。

`SignalingChannel.send` (L302-303) は送信 JSON 文字列をそのまま `Logger.debug` に出力する。`Logger.shared.level` のデフォルトは `.info` であるためデフォルトでは出力されないが、E2E テストでログレベルを `.debug` に設定した場合、`metadata.access_token` などの機密情報が GitHub Actions の job log に露出するリスクがある。また `SignalingChannel.handle` (L339-341) では受信 JSON のデコード失敗時に `json` 全文を `Logger.error` に出力しており、認証ウェブフックの応答に secret が含まれる場合に受信側でも露出しうる。

SDK のシグナリングにおける認証情報は `Configuration.signalingConnectMetadata: Encodable?` として任意の構造体で渡され、SDK はその内部構造（キー名）を知らないため、単純な JSON キー名一致マスクは不可能である。マスクはエンコード済み JSON 文字列に対して行う必要がある。

## Sora サーバー要件

E2E テストの接続先となる Sora サーバーは以下の条件を満たすこと。

- `recvonly` ロールでの接続を受け付けること
- 認証方式として `metadata.access_token` を受け入れること
- E2E 用チャネル（`e2e-test` を含む channelId）を拒否しないポリシーであること
- CI 実行時に常時利用可能であること（停止・メンテナンス時は E2E ジョブが失敗するため、その場合は期待される失敗として扱う）

## 設計方針

### workflow の整備

`.github/workflows/ci.yml` を新規作成し、E2E 専用の `e2e` job を追加する。既存の `build.yml` は GitHub-hosted runner のまま変更しない。

**runner 指定**:

- `runs-on: [self-hosted, macOS, ARM64, Apple-M1]`
- このラベルを持つ self-hosted runner が本リポジトリに登録されていることが前提
- runner には事前に `sudo xcodebuild -license accept` を実行済みであること
- runner が利用不可能な場合、e2e job はキューに滞留する（`slack_notify` が `needs.e2e.result = 'skipped'` を想定できるよう対応）

**Xcode バージョン**:

- e2e job 用の環境変数として以下を設定する（build job と同様に Xcode を固定する）
  - `XCODE: /Applications/Xcode_26.2.app`
  - `XCODE_SDK: iphoneos26.2`
- step で `sudo xcode-select -s '${{ env.XCODE }}/Contents/Developer'` を実行する

**timeout**:

- `timeout-minutes: 45`（Simulator の初回ブート時間 最大 10 分 + 全テストケース実行 最大 15 分 + 安全マージン 20 分の積み上げ）

**Simulator 管理**:

- destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2`
- step 実行前に `xcrun simctl list devices` で該当デバイスの有無を確認する
- 存在しない場合は `xcrun simctl create 'iPhone 17 Pro'` で作成する
- 起動は `xcrun simctl boot 'iPhone 17 Pro'` で行い、`xcrun simctl bootstatus 'iPhone 17 Pro' -b` で起動完了を待つ（起動完了前にテストが開始されるとエラーになるため）
- テスト実行後は `xcrun simctl shutdown 'iPhone 17 Pro'` で停止する（best effort）

**テスト実行**（環境変数注入を含む）:

`xcodebuild test` に直接 `KEY=VALUE` を渡しても Simulator 上のテストプロセスには伝播しない。以下の手順で `.xctestrun` 経由で注入する。

1. `xcodebuild build-for-testing` で `.xctestrun` を生成する
2. `.xctestrun` ファイル内の `TestingEnvironmentVariables` ディクショナリに `E2E_SIGNALING_URL`、`E2E_ACCESS_TOKEN`、`E2E_CHANNEL_ID_PREFIX`、`E2E_CHANNEL_ID_SUFFIX`、`GITHUB_RUN_ID` を追加する（`plutil` で書き換え）
3. `xcodebuild test-without-building -xctestrun <path>` でテストを実行する

**成果物アップロード**:

- `xcodebuild test` の失敗時は、生成された `.xcresult` バンドルを `actions/upload-artifact` でアップロードする
- アップロードは `if: failure()` で実行する

### E2E テスト戦略

新規ファイル `SoraTests/E2ETests.swift` を作成し、以下のテストケースを実装する。

テストクラス: `E2ETests: XCTestCase`

非同期方式: `Sora.connect()` はコールバック形式の非同期 API であるため、`XCTestExpectation` を使用してコールバックの完了を待機する。

テストヘルパー: 全テストケースから参照される `buildConfiguration()` メソッドを定義し、環境変数未設定時は `XCTSkipUnless` でスキップする責務を一元化する。

#### テストケース一覧

1. `testConnectRecvonly` — `recvonly` で Sora に接続できること
   - `buildConfiguration()` で `Configuration` を構築し、`Sora.shared.connect(configuration: handler:)` を呼ぶ（`webRTCConfiguration` はデフォルト）
   - assert: `SoraHandlers.onConnect` が呼ばれること（`XCTestExpectation`, タイムアウト 30 秒）

2. `testDisconnectRecvonly` — 接続後に明示的切断ができること
   - `testConnectRecvonly` のロジックで接続を確立した後、`mediaChannel.disconnect(error: nil)` を呼ぶ
   - assert: `MediaChannelHandlers.onDisconnect` が正常切断コードで呼ばれること（タイムアウト 10 秒）

3. `testOfferAnswerCompleted` — `recvonly` で offer / answer が完了すること
   - `testConnectRecvonly` のロジックで接続を確立する
   - assert: `onConnect` コールバック内で渡される `MediaChannel` の `native?.connectionState` が `.connected` であること

手動テスト項目:

- ローカルの Xcode で `E2E_SIGNALING_URL` と `E2E_ACCESS_TOKEN` をスキーム環境変数に設定して E2E テスト 3 ケースを実行し、すべて成功することを確認
- 環境変数未設定時に `swift test` を実行し、全テストが skip されることを確認

PBT / fuzzing は本 issue 対象外。実 Sora サーバーとの通信が前提であり、モックやスタブは利用しない（CLAUDE.md 準拠）。

### エッジケース

- **環境変数未設定**: `E2E_SIGNALING_URL` が nil または空文字列の場合、`buildConfiguration()` が `XCTSkipUnless` でテストをスキップする。全テストケース（`testConnectRecvonly`、`testDisconnectRecvonly`、`testOfferAnswerCompleted`）がスキップ対象
- **`E2E_CHANNEL_ID_PREFIX` / `E2E_CHANNEL_ID_SUFFIX` が未設定**: prefix 未設定時は `""`、suffix 未設定時も `""` として扱い、channelId は `"e2e-test{github.run_id}"` のみで構成される
- **Simulator runtime 未インストール**: step 内で runtime の有無を確認し、なければ `xcrun simctl runtime add` でインストールを試みる。self-hosted runner 側で事前に runtime がインストールされていることが前提
- **Sora サーバー到達不能**: ネットワークエラーまたはタイムアウトにより `XCTestExpectation` がタイムアウトし、テストは失敗する。`slack_notify` が失敗を通知する
- **CI 同時実行と channelId 衝突**: channelId の suffix に `github.run_id` を使用する。同じ run_id 内で複数回の接続テストは行われないため衝突しない。複数ブランチの同時 push は異なる run_id となるため衝突しない
- **接続中の強制終了**: `xcodebuild test` プロセスが強制終了された場合、Simulator を shutdown する（step の trap ハンドラで対応）

### iOS 向け環境変数注入と Configuration 構築

iOS では E2E テストプロセスが `ProcessInfo.processInfo.environment` から環境変数を直接参照する。

**CI から注入する環境変数（GitHub Secrets または Variables）**:

| 環境変数名 | 用途 | 種別 | デフォルト |
|---|---|---|---|
| `E2E_SIGNALING_URL` | Sora シグナリング接続先 URL | secret | なし（必須） |
| `E2E_ACCESS_TOKEN` | `metadata.access_token` に設定する認証トークン | secret | なし（必須） |
| `E2E_CHANNEL_ID_PREFIX` | channelId の prefix | variable | `""` |
| `E2E_CHANNEL_ID_SUFFIX` | channelId の suffix | variable | `""` |

**channelId 構築ロジック**:

```swift
let prefix = ProcessInfo.processInfo.environment["E2E_CHANNEL_ID_PREFIX"] ?? ""
let suffix = ProcessInfo.processInfo.environment["E2E_CHANNEL_ID_SUFFIX"] ?? ""
let runId = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? UUID().uuidString
let channelId = "\(prefix)e2e-test\(runId)\(suffix)"
```

**Configuration 構築**:

```swift
guard let urlString = ProcessInfo.processInfo.environment["E2E_SIGNALING_URL"],
      !urlString.isEmpty,
      let url = URL(string: urlString),
      let accessToken = ProcessInfo.processInfo.environment["E2E_ACCESS_TOKEN"],
      !accessToken.isEmpty else {
    throw XCTSkip("E2E environment variables not set")
}

struct E2EMetadata: Encodable {
    let access_token: String
}

var config = Configuration(
    urlCandidates: [url],
    channelId: channelId,
    role: .recvonly
)
config.signalingConnectMetadata = E2EMetadata(access_token: accessToken)
config.audioEnabled = false   // recvonly のため不要
config.videoEnabled = false   // recvonly のため不要
// multistreamEnabled はデフォルト (nil) のまま
```

### シークレット露出対策

#### マスク対象

SDK のログ出力において、以下のキーワードを含む可能性のある JSON フィールドの値をマスクする。

- `access_token`
- `token`
- `secret`
- `authorization`
- `credential`

#### 実装レイヤー

`SignalingChannel.send` 内で `Logger.debug` に JSON 文字列を渡す直前（L302-303）にマスク処理を挟む。また `SignalingChannel.handle` のエラーログ出力箇所（L339-341）でも同様のマスクを適用する。

加えて、`SignalingChannel.connect` (L213) では `Logger.info` レベルで `urlCandidates` を出力している。`E2E_SIGNALING_URL` がクエリパラメータに `access_token` を含む形式で渡される場合、`.info` レベルでも露出しうるため、E2E テストの `setUp()` で `Logger.shared.level = .warn` を設定し、`.info` 以下のログ出力を抑制する。

#### 実装方法

SDK のシグナリング認証情報は `Configuration.signalingConnectMetadata` 経由で任意の `Encodable` として渡されるため、`SignalingChannel` は metadata の内部構造（キー名）を知らない。したがって、エンコード済み JSON 文字列に対して正規表現で特定キー名にマッチする値を `***` に置換する方式を採用する。マスクの実装は `SignalingChannel` 内の private メソッドとして実装し、外部 API は変更しない。

#### 後方互換性

この変更は SDK のログ出力内容を変更するため、`Logger.debug` でシグナリング JSON 全文を観測している既存ユーザーにとっては破壊的変更となる。`CHANGES.md` には `[CHANGE]` として記載し、リリースノートで既存ユーザーに周知する。ログレベルが `.info` 以上（デフォルト）のユーザーには影響しない。

#### E2E テストコード側

E2E テストコード内では以下を遵守する:
- `channelId` の実値をログ出力しない（prefix / suffix の設定有無のみ出力）
- `E2E_SIGNALING_URL` の実値をログ出力しない
- `setUp()` で `Logger.shared.level = .warn` を設定する
- `Logger.shared.onOutputHandler` を上書きし、`print()` への標準出力を抑制するか、ログを XCTest の出力にリダイレクトする（`Logger.output` 内の `print(log.description)` (L311) が Simulator system log に流れ、ログ収集 step で迂回キャプチャされるのを防ぐため）

### Actions ログでのデバッグ性確保

- `xcodebuild test` の標準出力はそのまま job log に出力する
- テスト失敗時の原因特定を容易にするため、Simulator の system log を収集する。`xcrun simctl spawn booted log stream` をバックグラウンドで起動し、step 終了時は `trap` でプロセスを停止する

### Slack 通知

既存の `slack_notify` job を以下のように修正する。

```yaml
slack_notify:
  needs: [build, e2e]
  runs-on: ubuntu-24.04
  if: always()
  permissions:
    actions: read
  steps:
    - name: Slack Notification
      uses: shiguredo/github-actions/.github/actions/slack-notify@main
      with:
        status: ${{ needs.build.result == 'success' && needs.e2e.result == 'success' && 'success' || 'failure' }}
        slack_webhook: ${{ secrets.SLACK_WEBHOOK }}
        slack_channel: sora-ios-sdk
```

build と e2e のいずれかが失敗した場合は `failure` を通知する。e2e が runner 不在でスキップされた場合は `skipped` となり、上記の式では `failure` 扱いとなる。これは runner 不在を障害として通知する意図であり、許容する。

## 完了条件

- self-hosted macOS runner で E2E 用 job を実行できるようになっていること
- `xcodebuild test` で iOS Simulator 上の `recvonly` E2E テストを起動できること
- `E2E_SIGNALING_URL`、`E2E_ACCESS_TOKEN`、`E2E_CHANNEL_ID_PREFIX`、`E2E_CHANNEL_ID_SUFFIX` を CI から注入できること
- CI 実行ごとに衝突しない `channelId` を構築できること
- `recvonly` 接続、切断の E2E テストが物理デバイス非依存で動作すること
- secret を含むログが GitHub Actions の job log に露出しないこと（送信・受信両方の経路）
- `slack_notify` が build job と e2e job の結果を正しく参照できること
- runner 前提条件、利用する simulator、必要な secret / env の一覧が issue に整理されていること
- `CHANGES.md` に変更内容が `[ADD]` または `[CHANGE]` として追記されていること

## 解決方法

想定する変更対象:

- `.github/workflows/ci.yml` (新規)
  - `e2e` job の追加（`runs-on: [self-hosted, macOS, ARM64, Apple-M1]`、Xcode 26.2、`xcodebuild test` 実行）
  - Simulator の作成・起動・停止手順
  - Simulator system log 収集（`trap` による後始末を含む）
  - `xcodebuild test` 失敗時の `.xcresult` artifact アップロード
  - `slack_notify` の `needs` を `[build, e2e]` に変更し、両方の結果を参照するよう修正
- `SoraTests/E2ETests.swift` (新規)
  - 環境変数 `E2E_SIGNALING_URL`、`E2E_ACCESS_TOKEN`、`E2E_CHANNEL_ID_PREFIX`、`E2E_CHANNEL_ID_SUFFIX` の読み取りヘルパー
  - channelId 構築（`{prefix}e2e-test{github.run_id}{suffix}`）
  - `testConnectRecvonly`、`testDisconnectRecvonly`、`testOfferAnswerCompleted` の実装
  - 環境変数未設定時の `XCTSkipUnless` スキップ
  - `Configuration` の組み立て（`role: .recvonly`、`audioEnabled: false`、`videoEnabled: false`、`signalingConnectMetadata` に access_token 注入）
- `Sora/Logger.swift`
  - `output(log:)` 内でログメッセージの secret をマスクする
  - マスク処理は private static メソッドとして実装し、SDK の全ログ出力に適用する
- `CHANGES.md`
  - `[CHANGE]` エントリ: シグナリングチャンネルの debug ログ出力から secret をマスクするようにする
  - `### misc` セクションに `[ADD]` エントリ: iOS E2E テストを self-hosted macOS runner で CI 実行できるようにする

E2E 用の補助コードは `SoraTests` 配下に閉じ込め、SDK の公開 API は増やさない。
