# API ドキュメントを GitHub Pages で独立公開する

- Priority: Medium
- Created: 2026-06-26
- Completed:
- Model: Opus 4.7
- Branch: feature/add-deploy-apidoc-github-pages
- Polished: 2026-06-29

## 目的

これまで Jazzy で生成した API ドキュメントはメインドキュメント `https://sora-ios-sdk.shiguredo.jp/` のリポジトリ側へ手動でコピーして配信していた。コピー作業は手作業で、リリースのたびに API ドキュメントを最新化する手間が発生し、メインドキュメントのリポジトリに大量の生成物が混入していた。

API ドキュメントを `https://shiguredo.github.io/sora-ios-sdk/` の GitHub Pages で独立公開することで、生成・配信を CI で自動化し、メインドキュメントから API ドキュメントの生成物を切り離す。

## 優先度根拠

- ドキュメント配信の運用改善であり、ユーザー影響は無い
- リリース毎のコピー作業を継続することは可能なため、緊急性は低い
- ただし、コピー漏れや過去バージョンの混入リスクは存在するため、近いリリースタイミングで対応したい
- → Medium

## 現状

- API ドキュメント生成は `.jazzy.yaml` 経由の Jazzy
  - `swift_build_tool: xcodebuild` で Xcode プロジェクトの `Sora` scheme をビルドする
  - `module_version: 2026.1.0`（リリース毎に手動で更新する前提。本 issue 範囲外）
  - `root_url: https://sora-ios-sdk.shiguredo.jp/`
  - 出力先は `.jazzy.yaml` に未指定で Jazzy のデフォルト `docs/` に出力される
- 生成された `docs/` 配下をメインドキュメントリポジトリへ手動コピーして配信
- `https://shiguredo.github.io/sora-ios-sdk/` は GitHub Pages として既に有効化済み
  - `build_type: workflow`
  - `source.branch: develop`

## 設計方針

sora-js-sdk の `.github/workflows/deploy-apidoc.yml` を参考に、Jazzy + macOS runner 向けに調整した workflow を追加する。sora-js-sdk は Node.js ベース（`vp run doc`）だが、本リポジトリは Jazzy を使うため build ジョブの runner と手順が異なる。deploy / slack_notify ジョブの構成は sora-js-sdk に準ずる。

### deploy-apidoc.yml の構成

- workflow `name: deploy-apidoc`
- トリガー
  - `push: branches: [master]`（develop でマージした変更を master に cherry-pick して push するタイミングで発火）
  - `workflow_dispatch`（手動発火。再実行や master push 前の試行に使う）
  - `paths-ignore` は設定しない（master への push は cherry-pick によるワークフロー・ドキュメント変更が中心で頻度が低く、ドキュメント生成以外の変更で発火するリスクが小さいため）
- `permissions: contents: read`
- `concurrency: { group: pages, cancel-in-progress: false }`（GitHub Pages のデプロイ競合を防ぐため。`build.yml` / `ci.yml` には無いが Pages デプロイ固有の要件）
- `build` ジョブ
  - `runs-on: macos-26`（既存 `build.yml` と同じ）
  - env で `XCODE: /Applications/Xcode_26.2.app` を指定し `xcode-select -s` を実行
    - `XCODE_SDK` は指定しない（`.jazzy.yaml` の `xcodebuild_arguments` が `-destination 'generic/platform=iOS'` を指定しており、jazzy が内部で呼ぶ xcodebuild はこれを使うため）
  - `actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3`（既存 `build.yml` に揃える。sora-js-sdk 参考実装は v7.0.0 だが本リポジトリの `build.yml` / `ci.yml` は v6.0.3 に揃えているため、そちらに従う）
  - `gem install jazzy`（バージョン固定なし。Jazzy は Swift / Xcode のバージョンアップに追従して最新を使うことが前提のため固定しない。`module_version` は `.jazzy.yaml` 側で管理する。macOS runner で権限エラーが出る場合は `sudo gem install jazzy` に切り替える）
  - `jazzy`（カレントディレクトリの `.jazzy.yaml` を自動で読み、`docs/` に生成する）
  - `actions/upload-pages-artifact` で `path: docs`
    - SHA pin で指定する（sora-js-sdk 参考実装の `fc324d3547104276b827a68afc52ff2a11cc49c9 # v5.0.0` を採用する。実装時に最新 SHA を要確認）
- `deploy` ジョブ
  - `runs-on: ubuntu-slim`（`ci.yml` の slack_notify に揃える。`build.yml` は `ubuntu-24.04` だが Pages 系ジョブは `ci.yml` に揃える）
  - `needs: [build]`
  - `permissions: { contents: read, pages: write, id-token: write }`
  - `environment: { name: github-pages, url: ${{ steps.deployment.outputs.page_url }} }`
    - （実装時はブロック形式で展開して記述する）
  - `actions/deploy-pages` に `id: deployment` を指定する（`environment.url` が `steps.deployment.outputs.page_url` を参照するため必須）
    - SHA pin で指定する（sora-js-sdk 参考実装の `cd2ce8fcbc39b97be8ca5fce6e763baed58fa128 # v5.0.0` を採用する。実装時に最新 SHA を要確認）
  - `actions/configure-pages` は使わない（`.jazzy.yaml` の `root_url` で絶対 URL を固定するため、Pages の basePath 設定は不要）
- `slack_notify` ジョブ
  - `runs-on: ubuntu-slim`
  - `needs: [deploy]`
  - `if: ${{ !cancelled() }}`（`if:` に status function を指定すると暗黙の `success()` チェックが外れるため、`build` が失敗して `deploy` が skipped になっても `slack_notify` は実行される。sora-js-sdk 参考実装と同じ挙動）
  - `permissions: actions: read`
  - `shiguredo/github-actions/.github/actions/slack-notify@main`
  - `status: ${{ needs.deploy.result }}`（`ci.yml` の `status: ${{ needs.e2e.result }}` と同じパターン。deploy の結果を正しく報告するため `job.status` ではなく `needs.deploy.result` を使う）
  - `slack_webhook: ${{ secrets.SLACK_WEBHOOK }}`
  - `slack_channel: sora-ios-sdk`
  - `notify_mode: failure_and_fixed`
  - `env: { GH_TOKEN: ${{ github.token }} }`（`notify_mode: failure_and_fixed` は前回実行結果を GitHub API で照会するため `GH_TOKEN` が必要。`ci.yml` でも指定済み。sora-js-sdk 参考実装には無いが本リポジトリでは `ci.yml` に揃える）
    - （実装時はブロック形式で展開して記述する）
  - 補足: `build.yml` / `ci.yml` の slack_notify は `notify_mode` 未指定（デフォルト動作）だが、本 workflow は Pages デプロイの失敗と復旧を Fixed 通知で捉えるため `failure_and_fixed` を指定する。3 workflow で slack_notify の挙動が異なることを許容する

### .jazzy.yaml の変更

- `root_url: https://sora-ios-sdk.shiguredo.jp/` を `root_url: https://shiguredo.github.io/sora-ios-sdk/` に変更する
  - 生成された HTML 内の絶対 URL（OG タグ等）が GitHub Pages を指すようになる
- `output: docs` の明示的追加は行わない（Jazzy のデフォルトが `docs/` であり、`.gitignore` でも `docs` を除外済みのため）

### GitHub Pages 設定変更

- `source.branch` を `develop` → `master` に変更する
  - `build_type: workflow` のためデプロイ自体には影響しないが、master 運用と整合させるため明示的に変更する
  - `gh api -X PUT repos/shiguredo/sora-ios-sdk/pages -f 'source[branch]=master' -f 'source[path]=/'` で変更
  - この変更は workflow のマージ後に作業者が実施する（PR スコープ外の手動 ops 操作）

### 変更しないもの

- `README.md` の「ドキュメント」リンク（`https://sora-ios-sdk.shiguredo.jp/`）は据え置く（メインドキュメントの配信先は変わらない）
- メインドキュメント側（別リポジトリ）の API ドキュメントリンク差し替えは本 issue の対象外
- メインドキュメントリポジトリへの `docs/` 手動コピーの廃止時期は本 issue では確定させない（リンク差し替えと並行して別 issue で調整する）

## 完了条件

実装スコープ（PR で完了するもの）:

- `.github/workflows/deploy-apidoc.yml` が追加されている
- `.jazzy.yaml` の `root_url` が `https://shiguredo.github.io/sora-ios-sdk/` に更新されている
- `CHANGES.md` の `## develop` の `### misc` セクションに `[ADD]` で本変更が追記されている

マージ後の手動作業（PR スコープ外、作業者が実施するもの）:

- develop でマージした変更を master に cherry-pick する
- GitHub Pages の `source.branch` を `master` に切り替える（`gh api` で実施）
- master への cherry-pick push で workflow が自動発火し、`https://shiguredo.github.io/sora-ios-sdk/` に Jazzy 出力が配信されていることを確認する
  - `workflow_dispatch` は再実行や master push 前の試行用の予備として利用可能

## 解決方法

1. `.github/workflows/deploy-apidoc.yml` を新規作成する（上記「設計方針」の構成に従う）
2. `.jazzy.yaml` の `root_url` を更新する
3. `CHANGES.md` の `## develop` の `### misc` セクションに次のエントリを追加する
   - `- [ADD] API ドキュメントを GitHub Pages で公開するワークフローを追加する`
   - `  - @<担当者>`
   - shiguredo-changelog 規約に従い、担当者行を 2 文字インデントして追加する
4. PR を出して develop にマージする
5. develop の変更を master に cherry-pick する
6. GitHub Pages の `source.branch` を `master` に切り替える（`gh api` で実施）
7. master への push で workflow が自動発火するので、`https://shiguredo.github.io/sora-ios-sdk/` の表示を確認する
