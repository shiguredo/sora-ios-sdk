# 画面キャプチャのドキュメントにアプリ内画面のみを対象とすることを明記する

- Created: 2026-10-20
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-capture-doc-scope
- Polished: {YYYY-MM-DD}
- Priority: Medium

## 目的

SDK の画面キャプチャは ReplayKit の `RPScreenRecorder` を使ったアプリ内画面キャプチャであり、他アプリの画面やホーム画面は取得できない。しかし、現行のドキュメントには「端末画面を配信する」と読める表現があり、全画面共有ができると誤解させる。利用者が「他アプリの画面が送れない」と気づくまで実装コストを払うことになるため、公開 API の doc コメントと利用ガイドに対象範囲を明記する。

## 現状

- `skills/sora-ios-sdk/SKILL.md` の「画面キャプチャ」節は「ReplayKit を利用して端末画面を配信する。」と書いている。実際にはアプリ内画面のみを対象とする。
- `Sora/MediaChannel.swift` の `startScreenCapture(settings:)` の doc コメントは「MediaChannel の接続中に ReplayKit を利用して画面キャプチャおよび映像配信を開始します」と書いており、対象範囲に触れていない。
- `Sora/MediaChannel.swift` の `stopScreenCapture()` の doc コメントは「ReplayKit を利用した画面キャプチャを停止します」、`isScreenCaptureActive()` の doc コメントは「画面キャプチャが動作中かを取得します」と書いており、対象範囲に触れていない。
- `Sora/ScreenCapture.swift` の `ScreenCaptureSettings` の doc コメントは「画面キャプチャの設定です。」と書いており、対象範囲に触れていない。
- `ScreenCaptureController.startCapture` は `RPScreenRecorder.shared().startCapture` を呼ぶ。`RPScreenRecorder` はアプリ内の音声・映像を録画する API で、他アプリの画面は対象外。
- 現行の ReplayKit 経路で他アプリを含む全画面共有を行うには Broadcast Upload Extension (`RPBroadcastSampleHandler`) と `RPSystemBroadcastPickerView` または Control Center からの開始が必要だが、SDK はこの構成を提供していない。
- `CHANGES.md` の 2026.2.0 の「iOS 端末画面をキャプチャして配信する ScreenCapture を追加する」も同じ表現だが、リリース済みの履歴は書き換えない。

## 設計方針

- 公開 API の doc コメント (`startScreenCapture(settings:)` / `stopScreenCapture()` / `isScreenCaptureActive()` / `ScreenCaptureSettings`) に、対象が「SDK を利用しているアプリ自身の画面」であり、他アプリの画面・ホーム画面・全画面は取得できないことを明記する。
- `skills/sora-ios-sdk/SKILL.md` の「画面キャプチャ」節の「端末画面」を「アプリ内画面」に修正し、現行の ReplayKit 経路では他アプリの画面を送るには Broadcast Upload Extension が必要で SDK は未対応であることを 1 文で補足する。
- iOS 27 以降の ScreenCaptureKit 対応に触れる場合は、実装済みと誤解させないよう「別途検討」とだけ書き、issue 番号は書かない。本 issue では ScreenCaptureKit の実装や API 追加は扱わない。
- `CHANGES.md` の過去のリリース済みエントリは書き換えない。今回の修正は `## develop` セクションに `[UPDATE]` として追記する。
- コードの挙動と公開 API は変更しない。doc コメントと利用ガイドだけを変更する。

## 変更対象

- `Sora/MediaChannel.swift`: `startScreenCapture(settings:)` / `stopScreenCapture()` / `isScreenCaptureActive()` の doc コメント
- `Sora/ScreenCapture.swift`: `ScreenCaptureSettings` の doc コメント
- `skills/sora-ios-sdk/SKILL.md`: 画面キャプチャ節の説明
- `CHANGES.md`: `## develop` に `[UPDATE]` を追記

## 完了条件

- `startScreenCapture(settings:)` の doc コメントに、アプリ内画面のみを対象とし、他アプリの画面・ホーム画面・全画面は取得できないことが書かれている。
- `SKILL.md` の画面キャプチャ節に「端末画面」ではなく「アプリ内画面」と書かれ、現行の ReplayKit 経路では全画面共有に Broadcast Upload Extension が必要で SDK は未対応であることが書かれている。
- `ScreenCaptureSettings` の doc コメントに対象範囲が書かれている。
- `Sora/`、`skills/`、`README.md` に「端末画面」という表現が残っていない (`CHANGES.md` のリリース済み履歴は除く)。
- `CHANGES.md` の `## develop` に `[UPDATE]` が追記されている。過去のリリース済みエントリは変更されていない。
- `make fmt-lint` と `make lint` が成功する。コードの挙動と公開 API は変わらないため、API baseline の再生成は不要。
- ドキュメント修正のみのためテストの追加は不要だが、既存テストが引き続き成功することを確認する。

## 関連 issue

- `0053`: 画面キャプチャ機能の追加 (closed)。当時の changelog の表現が今回の誤解の由来だが、リリース済み履歴は書き換えない。
- `0061`: App Extension 対応。現在の実装がアプリ内画面キャプチャであることに言及しているが、ドキュメント修正は対象外。
- `0192`: iOS 27 以降の ScreenCaptureKit 対応。全画面・他アプリ共有は SCK で追加する新機能であり、本 issue は既存 ReplayKit 経路の説明を正す独立した doc 修正。`0192` の完了を待たずに対応できる。

## 解決方法
