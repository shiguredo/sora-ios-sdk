# Swift6Consumer

Sora を外部の iOS アプリと同じ形 (通常の SwiftPM package 依存) で `import Sora` し、
Swift 6 language mode と warnings-as-errors で compile できるかを検証する fixture です。

- 内部 API へ依存しない。test 用の import 属性や診断抑止の属性を一切使わない
- Sora の公開 API の baseline を保持し、意図しない削除・変更・準拠の削除を CI で検出する
- root package の target ではない。root の scheme 一覧や plugin の対象には影響しない

## 構成

| target | 既定隔離 | 検証する契約 |
| --- | --- | --- |
| `ConsumerCore` | `nonisolated` | 接続設定の組み立てと接続、handler への closure 代入、RPC と統計取得、`VideoRenderer` の非隔離実装 |
| `ConsumerUI` | `MainActor` | `@MainActor` を書かずに `VideoView` を生成して操作できること (既定隔離が MainActor であることの担保) |
| `ConsumerLegacy` | `nonisolated` | 非推奨 API が warning に留まり、warnings-as-errors でも build できること |

| ディレクトリ | 役割 |
| --- | --- |
| `Sources/<Target>/` | build 対象の scenario。1 file 1 scenario |
| `NegativeChecks/` | compile 失敗を期待する file。どの target にも含めない |
| `ApiBaseline/` | commit する公開 API baseline とその生成情報 |

## scenario の追加手順

1. `Sources/<Target>/<Scenario>.swift` を追加する。file を追加するだけで build 対象になる
2. 先頭に「検査する契約」と「期待する診断」を日本語のコメントで書く
3. `make consumer-build SCHEME=<Target>` で確認する。warnings-as-errors のため warning 1 件でも失敗する
4. 公開 API の追加 (新しい scenario が新しい API を使う場合) を伴うときは、同じ変更で
   `make api-baseline` を実行して baseline を更新する。追加は `make api-check` では検出できない

scenario は型や関数として定義し、実行経路を持たない。戻り値のある API は未使用警告で
error にならないよう `_ =` で扱い、`async throws` の API は `try await` で呼ぶ。

## 負例 (compile 失敗を期待する検証) の追加手順

1. `NegativeChecks/core-<名前>.swift` または `NegativeChecks/ui-<名前>.swift` を追加する。
   接頭辞は既定隔離を決める (`core-` は `nonisolated`、`ui-` は `MainActor`)。未知の接頭辞は失敗する
2. 1 行目に `// EXPECT-DIAGNOSTIC: <group 名>` を書く
3. group 名は推測せず、`swiftc -typecheck` の出力に出る `[#GroupName]` を実測して確定する
4. `make consumer-check-negative` で、compile に失敗し、かつ `error:` 行に `[#group 名]` が
   現れることを確認する

compile に失敗したことだけでは不十分 (無関係な typo でも失敗する) なため、
`make consumer-check-negative` は `error:` 行に現れる `[#group 名]` まで検査する。診断が
warning に降格した場合や、末尾のリンク行にしか group 名が無い場合は通らない。ObjC SDK や
`UIView` 継承型への非隔離な呼び出しは error ではなく warning になるため、負例には使えない。

## 公開 API baseline

- `make api-baseline`: baseline を生成する。Xcode 26.6 と `iphoneos26.5` が必要
- `make api-check`: commit 済み baseline と build 済み module を比較する。CI が呼ぶのはこの target だけ
- baseline は `-I` / `-F` に渡す module と同じ SDK で dump する必要があるため、生成と比較を同じ Xcode と SDK で行う
- 生成・比較・更新の手順と、差分をレビューするときの注意は root の `CODEBASE.md` に書いてある

## 担当

どの作業がどの file を追加・削除するかは root の `issues/` を参照する。fixture が長く残る
成果物であり issue 番号は管理上都合で変わるため、この README と fixture の source には
issue 番号を書かず、検証したい契約と未対応である理由を書く。

| file | 検証する契約 | 追加・削除する作業 |
| --- | --- | --- |
| `Sources/ConsumerCore/ConnectSignaling.swift` | 接続設定の組み立て、接続、`ConnectionTask` | 変更しない |
| `Sources/ConsumerCore/HandlerCompatibility.swift` | 非推奨でない handler の closure 型、`VideoRenderer` の非隔離実装 | 非推奨 API を削除する作業が、対応する handler の代入を削除する |
| `Sources/ConsumerCore/MediaChannelRPC.swift` | RPC、統計取得、戻り値 `Error?` の API | Sendable な RPC API を追加する作業が、新しい RPC の scenario を追加する |
| `Sources/ConsumerUI/VideoViewScenario.swift` | 既定隔離が MainActor であること | `VideoRenderer` の隔離を見直す作業が更新する |
| `Sources/ConsumerLegacy/DeprecatedAPI.swift` | 非推奨 API が warning に留まること | 非推奨 API を削除する作業が、対象の参照を削除する |
| `NegativeChecks/core-sendable-capture.swift` | `MediaChannel` が Sendable でないこと | `MediaChannel` の Sendable 準拠を検討する作業が更新する |
| `NegativeChecks/ui-isolated-conformance.swift` | 隔離された conformance は非隔離文脈で使えないこと | 変更しない |
| `ApiBaseline/` | 公開 API の削除・変更の検出 | 公開 API を変更するすべての作業が、同じ変更で再生成する |
