# Swift6Consumer

Sora を外部の iOS アプリと同じ形 (通常の SwiftPM package 依存) で `import Sora` し、
Swift 6 language mode と warnings-as-errors で compile できるかを検証する consumer package です。
外部のアプリが Sora を使う形を再現する検証用の package であり、テストデータでもサンプルアプリでもありません。

- 内部 API へ依存しない。test 用の import 属性や診断抑止の属性を一切使わない
- Sora の公開 API の baseline を保持し、意図しない削除・変更・準拠の削除と、baseline が現在の module と一致していないこと (追加を含む) を CI で検出する
- root package の target ではない。root の scheme 一覧や plugin の対象には影響しない
- 依存は root package への local path 依存である。公開タグや URL からの解決、iOS アプリへのリンク、
  `WebRTC.xcframework` の embed は検証せず、`import Sora` と `import WebRTC` が通ることだけを検証する

## 構成

| target | 既定隔離 | 検証する契約 |
| --- | --- | --- |
| `ConsumerCore` | `nonisolated` | 接続設定の組み立てと接続、handler への closure 代入、RPC と統計取得、`VideoRenderer` の非隔離実装 |
| `ConsumerUI` | `MainActor` | `@MainActor` を書かずに `VideoView` を生成して操作できること (既定隔離が MainActor であることの担保) |
| `ConsumerLegacy` | `nonisolated` | 非推奨 API が warning に留まり、warnings-as-errors でも build できること |

| ディレクトリ | 役割 |
| --- | --- |
| `Sources/<Target>/` | build 対象の scenario。1 file = 1 まとまりの契約 (複数の契約をまとめてよい) |
| `NegativeChecks/` | compile 失敗を期待する file。どの target にも含めない |
| `ApiBaseline/` | commit する公開 API baseline とその生成情報 |

## scenario の追加手順

1. `Sources/<Target>/<Scenario>.swift` を追加する。file を追加するだけで build 対象になる
2. 先頭に「検査する契約」と「期待する診断」を日本語のコメントで書く
3. `make consumer-build SCHEME=<Target>` で確認する。warnings-as-errors のため warning 1 件でも失敗する
4. 公開 API の追加 (新しい scenario が新しい API を使う場合) を伴うときは、同じ変更で
   `make api-baseline` を実行して baseline を更新する。追加は `make api-check` では検出できないが、
   CI が呼ぶ `make api-check-fresh` が検出する

scenario は型や関数として定義し、実行経路を持たない。`_ =` は次の 4 つの用途で使う。

- 未使用の戻り値や optional binding を消費する (`async throws` の API は `try await` で呼ぶ)
- 公開プロパティや公開メソッドへ compile で到達する (参照しないと型検査されないため)
- closure の引数を使わない場合に参照する。SwiftLint の `unused_closure_parameter` が既定で
  有効なため `{ _ in }` か `_ = 引数` にする (引数名を残すと closure の型が読みやすい)
- closure に外側の非 Sendable な値を capture させる (closure 型に `@Sendable` が付いた場合に
  compile で検出するため)

## 負例 (compile 失敗を期待する検証) の追加手順

1. `NegativeChecks/core-<名前>.swift` または `NegativeChecks/ui-<名前>.swift` を追加する。
   接頭辞は既定隔離を決める (`core-` は `nonisolated`、`ui-` は `MainActor`)。未知の接頭辞は失敗する
2. 1 行目に `// EXPECT-DIAGNOSTIC: <group 名>` を書く
3. group 名は推測せず、`swiftc -typecheck` の出力に出る `[#GroupName]` を実測して確定する
4. `make consumer-check-negative` で、compile に失敗し、かつ `error:` 行に `[#group 名]` が
   現れることを確認する

compile に失敗したことだけでは不十分 (無関係な typo でも失敗する) なため、
`make consumer-check-negative` は診断行 (`<file>:<line>:<column>: error:`) に現れる
`[#group 名]` まで検査する。診断が warning に降格した場合や、末尾のリンク行にしか
group 名が無い場合は通らない。あわせて、`[#group 名]` を含まない診断行が 1 件でもあれば
失敗させる (無関係な error が混ざった負例を成功扱いにしないため)。診断が引用するソース行と
キャレット注釈行は診断行として扱わない (負例のソースに `error:` という文字列があっても
誤検知しない)。ObjC SDK や
`UIView` 継承型への非隔離な呼び出しは error ではなく warning になるため、負例には使えない。

## 公開 closure の列挙手順

consumer package が受け渡しを検証する公開 closure は、次の手順で列挙して突き合わせる。

1. closure プロパティを列挙する: `git grep -nE 'public var [A-Za-z]+: *\(\(' -- Sora` と
   型が次行以降にある宣言の `git grep -n -A4 -E 'public var [A-Za-z]+:$' -- Sora`
2. closure 引数を列挙する: `git grep -n -B8 '@escaping' -- Sora | grep -E 'public (static )?func'`。
   `@escaping` が無い closure 引数 (`Sora.configureAudioSession(block:)` や `Optional.unwrap(ifNone:)` など) は
   この grep では列挙できないため、`git grep -nE 'public (static )?func' -- Sora` の結果から
   closure 型の引数を持つものも拾う
3. 囲っている型が公開 (`public class` / `public struct` / `public enum` / `public protocol`) の
   ものだけを対象にする。internal な型の `public` メンバ (`WebSocketChannelInternalHandlers` や
   `ConnectionTimer` など) は公開 API ではない
4. 対象の API を、handler 型に属するものは `Sources/ConsumerCore/HandlerCompatibility.swift`、
   それ以外は `Sources/ConsumerCore/CallbackCompatibility.swift` で受け渡しする
5. 非推奨の API は `Sources/ConsumerLegacy/DeprecatedAPI.swift` で扱う
6. 検証できない API は、次の表に理由を書く

| 公開 closure | 検証する file |
| --- | --- |
| `SoraHandlers` / `MediaChannelHandlers` / `MediaStreamHandlers` / `CameraVideoCapturerHandlers` / `WebSocketChannelHandlers` の closure プロパティ | `Sources/ConsumerCore/HandlerCompatibility.swift` |
| `SoraHandlers.onChangeAudioRoute` (型が次行以降にある宣言) | `Sources/ConsumerCore/HandlerCompatibility.swift` |
| `Logger.onOutputHandler` | `Sources/ConsumerCore/CallbackCompatibility.swift` |
| `ScreenCaptureSettings.videoSampleBufferTransformer` / `onRuntimeError` (init の引数と property) | `Sources/ConsumerCore/CallbackCompatibility.swift` |
| `CameraVideoCapturer.stop` / `restart` / `change` / `flip` の完了 handler | `Sources/ConsumerCore/CallbackCompatibility.swift` |
| `CameraVideoCapturer.start` の完了 handler | 対象外。実機の `AVCaptureDevice.Format` が必要で、compile だけの consumer package では作れない |
| `MediaChannel.getStats(handler:)` | `Sources/ConsumerCore/MediaChannelRPC.swift` |
| `Sora.connect(configuration:webRTCConfiguration:handler:)` | `Sources/ConsumerCore/ConnectSignaling.swift` |
| `Sora.configureAudioSession(block:)` | `Sources/ConsumerCore/CallbackCompatibility.swift` |
| `Optional.unwrap(ifNone:)` / `Array.remove(_:where:)` (Sora が追加している標準型の extension) | `Sources/ConsumerCore/CallbackCompatibility.swift` |
| `SoraDispatcher.async(on:block:)` / `Utilities.Stopwatch(handler:)` | 対象外。非推奨化する作業が扱う |

handler 型の closure と `Sora.connect` と `Optional.unwrap(ifNone:)` / `Array.remove(_:where:)` には
非 Sendable な値を capture した closure を渡すため、closure 型に `@Sendable` が付いた場合は
compile で検出できる。`Logger.onOutputHandler` / `ScreenCaptureSettings` /
`CameraVideoCapturer` の完了 handler / `MediaChannel.getStats(handler:)` /
`Sora.configureAudioSession(block:)` は外側の値を capture しないため、`@Sendable` が付いても
compile は通る。これらは closure の型と引数が存在することを検証する。

## 公開 API baseline

- `make api-baseline`: baseline を生成する。Xcode 26.6 と `iphoneos26.5` が必要
- `make api-check`: commit 済み baseline と build 済み module を比較し、公開 API の削除・変更・準拠の削除を検出する
- `make api-check-fresh`: commit 済み baseline が現在の `Sora` module と一致していることを検証する。`make api-check` を実行したうえで fresh な dump と比較するため、追加も検出できる。CI が呼ぶのはこの target
- baseline は `-I` / `-F` に渡す module と同じ Xcode と SDK で扱う必要がある。生成・比較・更新の手順と、差分をレビューするときの注意は root の `CODEBASE.md` にある

## 担当

どの作業がどの file を追加・削除するかは root の `issues/` を参照する。consumer package が長く残る
成果物であり issue 番号は管理上都合で変わるため、この README と consumer package の source には
issue 番号を書かず、検証したい契約と未対応である理由を書く。

| file | 検証する契約 | 追加・削除する作業 |
| --- | --- | --- |
| `Sources/ConsumerCore/ConnectSignaling.swift` | 接続設定の組み立て、接続、`ConnectionTask` | `Sora.connect` の handler 型を変更する作業が更新する |
| `Sources/ConsumerCore/HandlerCompatibility.swift` | 非推奨でない handler の closure 型 (非 Sendable な値の capture で @Sendable 化を検出する)、`VideoRenderer` の非隔離実装、`import WebRTC` で WebRTC product を参照できること | 公開 handler の closure 型を変更する作業が更新する |
| `Sources/ConsumerCore/CallbackCompatibility.swift` | handler 型に属さない公開 closure の受け渡し | 公開 closure を追加・変更する作業が更新する |
| `Sources/ConsumerCore/MediaChannelRPC.swift` | RPC (利用者定義の `RPCMethodProtocol` 準拠型を含む)、統計取得、戻り値 `Error?` の API、公開プロパティの参照 | Sendable な RPC API を追加する作業が、新しい RPC の scenario を追加する |
| `Sources/ConsumerUI/VideoViewScenario.swift` | 既定隔離が MainActor であること | `VideoRenderer` の隔離を見直す作業が更新する |
| `Sources/ConsumerLegacy/DeprecatedAPI.swift` | 非推奨 API が warning に留まること (CI は期待する非推奨 API 名の一覧で検査する) | 非推奨 API を削除する作業が、対象の参照と `consumer-test.yml` の期待する非推奨 API 名の一覧を同時に更新する |
| `NegativeChecks/core-sendable-capture.swift` | `MediaChannel` が Sendable でないこと | `MediaChannel` の Sendable 準拠を検討する作業が更新する |
| `NegativeChecks/ui-isolated-conformance.swift` | 隔離された conformance は非隔離文脈で使えないこと | `VideoRenderer` の隔離を見直す作業が更新する |
| `ApiBaseline/` | 公開 API の削除・変更と、現在の module との不一致 (追加を含む) の検出 | 公開 API を変更するすべての作業が、同じ変更で再生成する |
