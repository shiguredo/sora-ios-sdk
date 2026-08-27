# VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-mainactor-video-renderer
- Polished: 2026-06-06
- Updated: 2026-08-27

## 目的

Swift 6 の `sending` チェックにより、`VideoRendererAdapter` で `DispatchQueue.main.async` に `renderer` / `frame` を直接キャプチャするとビルドエラーになる。現在は受け渡し専用イベント型を `@unchecked Sendable` で扱う暫定対応で回避している。

公開 API の互換性を維持したまま、UI 描画用の `@MainActor` renderer protocol と専用登録 API を追加し、`VideoView` を新しい経路へ移行する。全 renderer callback を同じ順序付き配送経路へ集約し、MainActor への最終配送を型と実行経路で保証する。

## 優先度根拠

- 現状は暫定対応により Swift 6 ビルドが通っているが、renderer callback 全体の actor safety と順序は保証されていない。
- 既存 API の互換性を維持した段階移行が必要であり、単純な annotation 追加では対応できない。

## 現状

`Sora/VideoRenderer.swift` の公開 protocol `VideoRenderer` には `@MainActor` が付与されていない。これに直接 `@MainActor` を付与すると既存実装者の公開 API を破壊する。

Swift 6 の `sending` エラーを回避するため、`VideoRendererSizeEvent` と `VideoRendererFrameEvent` を `@unchecked Sendable` として定義している。いずれも `weak var renderer: VideoRenderer?` を保持するため型として Sendable にできず、同時アクセスが起きない前提に依存している。

`VideoRendererAdapter.setSize(_:)` と `VideoRendererAdapter.renderFrame(_:)` は上記イベント型を生成し、`DispatchQueue.main.async` で main thread へ受け渡している。

一方、`Sora/MediaStream.swift` の `BasicMediaStream` は、`onAdded(from:)`、`onRemoved(from:)`、`onSwitch(video:)`、`onSwitch(audio:)`、`onDisconnect(from:)` を `VideoRendererAdapter` を経由せず、呼び出し元の executor 上で直接呼んでいる。size / frame だけを MainActor へ移しても、全 callback の隔離は成立しない。

`Sora/VideoView.swift` の `VideoRenderer` 準拠は `@preconcurrency` のままであり、撤去 TODO も残っている。MainActor 型である `VideoView` が nonisolated な legacy protocol へ準拠し続ける間は、Swift 6.3 では `@preconcurrency` を単純に除去できない。

公開登録口は `MediaStream.videoRenderer: VideoRenderer?` だけであるため、新しい protocol だけに準拠する renderer を登録する API も存在しない。

## 設計方針

### 前提

- `0107` の consumer fixture で legacy と新 API の source compatibility を固定する。
- `0105` で frame ownership、stream epoch、sequence、全 renderer callback の ordered ingress を確立する。
- `0060` の non-UI renderer 向け custom executor と、本 issue の UI 専用 MainActor 契約を分離する。

### 新しい UI renderer API

- UI 描画用の public `@MainActor` renderer protocol を追加する。
- legacy `MediaStream.videoRenderer` は維持し、新 protocol 専用の MainActor-isolated な登録 API を追加する。
- size、frame、add、remove、switch、disconnect の全 callback を同じ renderer delivery abstraction から配送する。
- `BasicMediaStream` から利用者 renderer を直接呼ばない。

### payload と順序

- `VideoFrame` 全体へ `@unchecked Sendable` を付与しない。
- `0105` で lifetime と thread affinity を保証した owned frame または狭い internal handle だけを executor 境界へ渡す。
- connection / stream の mutable reference が不要な新 callback は、Sendable な ID または immutable snapshot を利用する。
- 1 event ごとに独立した unstructured Task を生成せず、sequence と epoch を保持する単一経路から MainActor へ配送する。
- remove / disconnect 後の stale frame を破棄し、buffer 上限と drop 方針を定める。

### legacy compatibility

- legacy `VideoRenderer` と `MediaStream.videoRenderer` の型は本 issue では変更しない。
- `VideoView` が legacy protocol へ準拠し続ける場合、互換期間中の `@preconcurrency` は残す。
- 新経路は `@preconcurrency` と unchecked event box に依存しない。
- legacy protocol 全体の deprecation は、`0060` の custom executor 契約と移行先が確定した後に判断する。単純な `renamed:` は利用箇所を移行できないため使用しない。
- legacy API と event box の削除は、次期 major version の別 issue で扱う。

### `0070` との関係

- 本 issue を先行する場合は、WebRTC 型に依存しない renderer delivery abstraction を導入し、`0070` では vendor adapter だけを置き換える。
- `0070` が先行する場合も、UI 専用 MainActor と non-UI custom executor の契約を混在させない。

## テスト方針

モック・スタブは使用しない。

- `0107` の consumer fixture で、legacy `VideoRenderer` 実装、新 protocol だけの実装、新登録 API、`VideoView` の 4 ケースを通常の `import Sora` から compile する。
- 実 WebRTC frame と実 `VideoView` を使用し、全 callback が MainActor 上で実行されることを確認する。
- add、size、frame、switch、remove、disconnect の順序と、disconnect 後の stale frame 破棄を確認する。
- Main Thread Checker を補助的に有効化する。
- strict concurrency と warnings-as-errors で SDK と consumer fixture を build する。

## 完了条件

- UI 描画用の public `@MainActor` renderer protocol と専用登録 API が追加されていること。
- size、frame、add、remove、switch、disconnect の全 callback が同じ ordered delivery abstraction を経由すること。
- `VideoView` が新しい MainActor renderer API を利用すること。
- 新経路が `@preconcurrency` と `@unchecked Sendable` event box に依存していないこと。
- legacy `VideoRenderer` 準拠を残す場合だけ、`@preconcurrency` が compatibility boundary に限定されていること。
- raw `VideoFrame`、`MediaStream`、`MediaChannel` を新たな unchecked box で executor 越境させていないこと。
- callback の順序、buffer、drop、stale frame の契約が API documentation に記載されていること。
- 既存の `VideoRenderer` 実装が破壊的変更なしでビルドできること。
- strict concurrency と warnings-as-errors の build が成功すること。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [ADD] MainActor 前提の映像描画プロトコル MainActorVideoRenderer を追加する
    - @voluntas
  ```

## 解決方法
