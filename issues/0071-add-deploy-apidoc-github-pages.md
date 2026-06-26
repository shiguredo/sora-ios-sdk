# API ドキュメントを GitHub Pages で独立公開する

- Priority: Medium
- Created: 2026-06-26
- Completed:
- Model: Opus 4.7
- Branch: feature/add-deploy-apidoc-github-pages
- Polished:

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
  - `swift_build_tool: xcodebuild` で SPM ベース
  - `module_version: 2026.1.0`
  - `root_url: https://sora-ios-sdk.shiguredo.jp/`
  - 出力先は未指定で、Jazzy のデフォルト `docs/`
- 生成された `docs/` 配下をメインドキュメントリポジトリへ手動コピーして配信
- `https://shiguredo.github.io/sora-ios-sdk/` は GitHub Pages として既に有効化済み
  - `build_type: workflow`
  - `source.branch: develop`（実質未使用、`build_type: workflow` のため）

## 設計方針

sora-js-sdk の `.github/workflows/deploy-apidoc.yml` を参考に、Jazzy + macOS runner 向けに調整した workflow を追加する。

### deploy-apidoc.yml の構成

- トリガー
  - `push: branches: [master]`（リリース時に `release/x.y.z` を `master` へマージするタイミングで発火）
  - `workflow_dispatch`（手動発火）
- `permissions: contents: read`
- `concurrency: { group: pages, cancel-in-progress: false }`
- `build` ジョブ
  - `runs-on: macos-26`（既存 `build.yml` と同じ）
  - env で `XCODE: /Applications/Xcode_26.2.app` を指定し `xcode-select -s` を実行
  - `actions/checkout` は SHA pin（既存 `build.yml` のバージョンに揃える）
  - `gem install jazzy`（バージョン固定なし）
  - `jazzy`（`.jazzy.yaml` を読み、`docs/` に生成）
  - `actions/upload-pages-artifact@v5` で `path: docs`
- `deploy` ジョブ
  - `runs-on: ubuntu-slim`
  - `needs: [build]`
  - `permissions: { contents: read, pages: write, id-token: write }`
  - `environment: { name: github-pages, url: ${{ steps.deployment.outputs.page_url }} }`
  - `actions/deploy-pages@v5`
- `slack_notify` ジョブ
  - `runs-on: ubuntu-slim`
  - `needs: [deploy]`
  - `if: ${{ !cancelled() }}`（deploy 失敗時も発火させる）
  - `permissions: actions: read`
  - `shiguredo/github-actions/.github/actions/slack-notify@main`
  - `slack_channel: sora-ios-sdk`
  - `notify_mode: failure_and_fixed`

### .jazzy.yaml の変更

- `root_url: https://sora-ios-sdk.shiguredo.jp/` を `root_url: https://shiguredo.github.io/sora-ios-sdk/` に変更する
  - 生成された HTML 内の絶対 URL（OG タグ等）が GitHub Pages を指すようになる

### GitHub Pages 設定変更

- `source.branch` を `develop` → `master` に変更する
  - `build_type: workflow` のため実質的な動作には影響しないが、master 運用と整合させて明示する
  - `gh api -X PUT repos/shiguredo/sora-ios-sdk/pages -f 'source[branch]=master' -f 'source[path]=/'` で変更
  - この変更は workflow のマージ後に作業者が実施する

### 変更しないもの

- `README.md` の「ドキュメント」リンク（`https://sora-ios-sdk.shiguredo.jp/`）は据え置く
  - メインドキュメントの配信先は変わらない
- メインドキュメント側（別リポジトリ）の API ドキュメントリンク差し替えは本 issue の対象外

## 完了条件

- `.github/workflows/deploy-apidoc.yml` が追加されている
- `.jazzy.yaml` の `root_url` が `https://shiguredo.github.io/sora-ios-sdk/` に更新されている
- `master` ブランチへの push（または `workflow_dispatch`）で workflow が成功し、`https://shiguredo.github.io/sora-ios-sdk/` に Jazzy 出力が配信されている
- `CHANGES.md` の `## develop` の `### misc` セクションに `[ADD]` で本変更が追記されている

## 解決方法

1. `.github/workflows/deploy-apidoc.yml` を新規作成する（上記「設計方針」の構成に従う）
2. `.jazzy.yaml` の `root_url` を更新する
3. `CHANGES.md` の `## develop` の `### misc` セクションに次のエントリを追加する
   - `- [ADD] API ドキュメントを GitHub Pages で公開するワークフローを追加する`
4. PR を出してマージする
5. マージ後に GitHub Pages の `source.branch` を `master` に切り替える（`gh api` で実施）
6. `workflow_dispatch` で初回デプロイを走らせて `https://shiguredo.github.io/sora-ios-sdk/` の表示を確認する
