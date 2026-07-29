# libwebrtc の Swift Package 更新を自動化できるか調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-libwebrtc-update-automation
- Polished: 2026-06-06

## 目的

libwebrtc のバージョン更新時に `Package.swift` のバージョン文字列と checksum を手作業で書き換えており、手順が煩雑でミスが起きやすい。Swift Package 側の更新をどこまで自動化できるかを調査し、方式を決定してスクリプトまたはワークフローを実装する。

## 優先度根拠

- バージョン更新のたびに発生する作業だが頻度は限られ、ユーザー影響のある不具合ではない。
- 自動化方式の選択に設計判断を要するため Low とする。

## 現状

`Package.swift:6` でバージョン文字列を定義し、`Package.swift:21-25` の `binaryTarget` でリリース URL と checksum を直書きしている。バージョン更新時は以下を手動で行う必要がある。

- `Package.swift:6` の `libwebrtcVersion` の書き換え
- `WebRTC.xcframework.zip` をダウンロードして `swift package compute-checksum` で checksum を再計算し `Package.swift:24` を書き換え
- `CHANGES.md` への更新エントリ追記

既存の `canary.py` は SDK 自身のバージョン文字列（`Sora/PackageInfo.swift`）を管理するツールであり、`Package.swift` の `libwebrtcVersion` や checksum の更新は対象外。本 issue の自動化対象と重複しない。

## 設計方針

以下の調査を行い、方式を決定した上で実装する。

### 調査項目

1. **Package.swift のパース方法の決定**: `let libwebrtcVersion = "..."` と `checksum:` の値は sed や正規表現での書き換えが構文的に脆弱（将来の改行・コメント挿入で壊れ得る）。信頼性の高いパース・書き換え方法（例: Python の行番号固定による置換、`swift-package-manager` ツール API の有無）を確認して決定する。
2. **セキュリティモデルの確認**: ダウンロードした `WebRTC.xcframework.zip` から `swift package compute-checksum` で計算した値を自動コミットする場合、ZIP 自体が改ざんされていないことを担保する手段を確認する。webrtc-build リリースに署名ファイルや `*.sha256` が提供されているかを調査し、案 B（GitHub Actions）で自動 PR を作成する際のサプライチェーンリスクへの対処方針を決める。
3. **webrtc-build リリース規則の確認**: `https://github.com/shiguredo-webrtc-build/webrtc-build/releases` でタグフォーマット（`mXXX.YYYY.Z.0` 形式）が安定しているかを確認し、結果を `## 解決方法` に記録する。HTTP 404 等の失敗時の処理方針も合わせて決定する。
4. **方式の比較・決定**: 以下の観点で案 A と案 B を比較し、採用方式を決定する。
   - セキュリティ: 外部バイナリを誰の権限で取得するか（ローカル vs CI 環境）
   - 運用コスト: メンテナンス負担・runner コスト・失敗時のロールバック手順
   - CI との統合: 既存 `build.yml` との関係、PR の自動作成と手動レビューの要否
   - トリガー: 手動実行のみか、webrtc-build のリリースイベント連動か
   - 案 A と案 B の併用の可否

  - **案 A**: `bin/` 配下のスクリプト（シェルまたは Python）として用意し、引数でバージョンを受け取る。`bin/` ディレクトリは現時点で存在しないため新設する。
  - **案 B**: GitHub Actions ワークフロー（`workflow_dispatch` でバージョン入力）として用意し、更新内容を PR として提出する。

### 実装

決定した方式に従ってスクリプトまたはワークフローを実装する。`CHANGES.md` の更新は手動作業として残すか自動化するかも決定する。

## テスト方針

モック・スタブは使用しない。

- 実装したスクリプト / ワークフローを実際に実行し、`Package.swift` のバージョン文字列と checksum が正しく書き換えられることを確認する。
- `swift package compute-checksum <URL>` の出力と、書き換え後の `checksum:` の値が一致することを確認する。
- 書き換え後に `build.yml` に準じたコマンドでビルドが通ることを確認する。

## 完了条件

- Package.swift のパース・書き換え方法が決定され、`## 解決方法` に記録されていること。
- セキュリティモデル（checksum 信頼性確保の方針）が `## 解決方法` に記録されていること。
- webrtc-build のタグフォーマットの安定性確認結果とエラー処理方針が `## 解決方法` に記録されていること。
- 案 A / 案 B の比較結果と採用方式の根拠が `## 解決方法` に記録されていること。
- 決定した方式に従ってスクリプトまたはワークフローが実装されていること。
- テスト方針に記載した確認がすべて完了していること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` セクションが存在しない場合は新設すること）:
  ```
  - [ADD] libwebrtc Swift Package 更新自動化スクリプトを追加する
    - @voluntas
  ```

## 解決方法
