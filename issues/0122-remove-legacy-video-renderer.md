# legacy VideoRenderer API を削除する

- Created: 2026-08-27
- Completed:
- Branch: feature/remove-legacy-video-renderer
- Polished:

## 目的

移行期間を完了した legacy `VideoRenderer` API を次期 major version で削除し、`@preconcurrency` と `@unchecked Sendable` event box に依存する renderer 経路を撤去する。

## 前提

- `0105` の ordered frame / renderer ingress が実装済みであること。
- `0027` の MainActor UI renderer API が公開 release で提供されていること。
- `0060` の non-UI renderer 向け custom executor API が公開 release で提供されていること。
- `0107` の consumer fixture に legacy と新 API の移行例が存在すること。
- 次期 major version の作業として着手すること。

上記を満たしていない場合は、本 issue に着手しない。

## 現状

`Sora/VideoRenderer.swift` の legacy `VideoRenderer` は nonisolated protocol であり、`Sora/VideoView.swift` は `@preconcurrency VideoRenderer` として準拠している。

`VideoRendererAdapter` は `VideoRendererSizeEvent` と `VideoRendererFrameEvent` を `@unchecked Sendable` にして main queue へ渡す compatibility 経路を持つ。

`MediaStream.videoRenderer` の型も legacy protocol であるため、新 renderer API を追加した後も旧経路を削除しない限り暫定 workaround が残る。

## 設計方針

- legacy `VideoRenderer` protocol と旧登録 property を削除する。
- `VideoView` の `@preconcurrency VideoRenderer` 準拠を削除する。
- `VideoRendererSizeEvent`、`VideoRendererFrameEvent` と関連 TODO を削除する。
- UI renderer は MainActor API、non-UI renderer は custom executor API へ移行する。
- renderer callback は `0105` の sequence / epoch 付き ordered ingress だけから配送する。
- 新 API と同じ名前の compatibility wrapper を残さない。
- migration guide と API baseline を次期 major version の意図した破壊的変更として更新する。

## テスト方針

モックやスタブは使用しない。

- production code、test、sample、documentation に legacy `VideoRenderer` の参照が残っていないことを確認する。
- 実 `VideoView` と実 WebRTC frame で MainActor renderer を検証する。
- non-UI renderer を custom executor で実行し、MainActor に強制されないことを確認する。
- add、size、frame、switch、remove、disconnect の順序を確認する。
- API baseline が意図した削除だけを検出することを確認する。

## 完了条件

- legacy `VideoRenderer` protocol と旧登録 API が削除されていること。
- `VideoView` に `@preconcurrency` conformance が残っていないこと。
- renderer 用の `@unchecked Sendable` event box が削除されていること。
- UI と non-UI の新 renderer API が両方利用できること。
- migration guide と API baseline が更新されていること。
- strict concurrency と warnings-as-errors の build が成功すること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
