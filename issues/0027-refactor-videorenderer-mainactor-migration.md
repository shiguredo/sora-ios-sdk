# VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-videorenderer-mainactor-migration
- Polished: 2026-11-13
- Refreshed: 2026-11-13

## 目的

Swift 6 対応の際、`VideoRendererAdapter` で `DispatchQueue.main.async` に `renderer` / `frame` を直接キャプチャできずビルドエラーになった。`0105` は `@unchecked Sendable` な event box を使わず、owner queue → main queue の 2 段の非同期配送でこの制約を満たしたが、protocol が `@MainActor` を持たないため隔離は型では保証されない。

公開 API の互換性を維持したまま、UI 描画用の `@MainActor` renderer protocol と専用登録 API を追加し、`VideoView` を新しい経路へ移行する。全 renderer callback を同じ順序付き配送経路へ集約し、MainActor への最終配送を型と実行経路で保証する。

## 優先度根拠

- 現状は暫定対応により Swift 6 ビルドが通っている。renderer callback の配送 executor と順序は `0105` が main queue と単一経路で確定したが、`@MainActor` 隔離の型による保証は無く、ストリームをまたぐ相対順序と `MediaStreamHandlers` との相対順序は保証されない。
- 既存 API の互換性を維持した段階移行が必要であり、単純な annotation 追加では対応できない。

## 現状

`Sora/VideoRenderer.swift` の公開 protocol `VideoRenderer` には `@MainActor` が付与されていない。これに直接 `@MainActor` を付与すると既存実装者の公開 API を破壊する。

Swift 6 対応のビルドエラーを回避するために定義していた `VideoRendererSizeEvent` と `VideoRendererFrameEvent` は `0105` が削除した。`VideoRendererAdapter.setSize(_:)` と `renderFrame(_:)` は `StreamFrameOwner` の owner queue へ非同期に投入し、owner queue が順序を決めて main queue へ配送する。unchecked な event box は残っていない。

一方、`Sora/MediaStream.swift` の `BasicMediaStream` は、`0105` 以降 `VideoRendererAdapter` と同じ owner queue 経由で `onAdded(from:)`、`onRemoved(from:)`、`onSwitch(video:)`、`onSwitch(audio:)`、`onDisconnect(from:)` を main queue へ配送する。ただし protocol に `@MainActor` が無いため、これは実行時の取り決めであり型では保証されない。

`Sora/VideoView.swift` の `VideoRenderer` 準拠は `@preconcurrency` のままであり、撤去 TODO も残っている。MainActor 型である `VideoView` が nonisolated な legacy protocol へ準拠し続ける間は、Swift 6.3 では `@preconcurrency` を単純に除去できない。

公開登録口は `MediaStream.videoRenderer: VideoRenderer?` だけであるため、新しい protocol だけに準拠する renderer を登録する API も存在しない。

## 設計方針

### 前提

- `0107` で追加済みの consumer package (`TestConsumers/Swift6Consumer/`) で legacy と新 API の source compatibility を固定する。
- `0105` で frame ownership、sequence、全 renderer callback の ordered ingress と main queue 配送は確立済みである。
- `0060` の non-UI renderer 向け custom executor と、本 issue の UI 専用 MainActor 契約を分離する。

### 新しい UI renderer API

- UI 描画用の public `@MainActor` protocol `MainActorVideoRenderer: AnyObject` を追加する。callback は `onChange(size: CGSize)` / `render(videoFrame: VideoFrame?)` / `onAdded(from streamId: String)` / `onRemoved(from streamId: String)` / `onSwitch(video: Bool)` / `onSwitch(audio: Bool)` / `onDisconnect(from mediaChannel: MediaChannel?)` の 7 種類とする。
- legacy `MediaStream.videoRenderer` は維持し、`MediaStream` protocol に `@MainActor var mainActorVideoRenderer: MainActorVideoRenderer? { get set }` を追加する。
- 1 つの stream で同時に有効にできる renderer は 1 つとし、`videoRenderer` と `mainActorVideoRenderer` は同じ renderer slot を共有する。後から設定した方が有効になり、交換時は以前の renderer に `onRemoved` を 1 回だけ配送する。`nil` の代入は、その API で設定した renderer が有効なときだけ解除する。
- 世代 (`StreamFrameOwner.rendererGeneration`) と `VideoRendererAdapter` は両 API で共通化し、`videoRenderer` の getter は legacy renderer が有効なときだけその instance を返す。
- 全 callback を既存の `StreamRendererDelivery` の単一経路から配送し、`BasicMediaStream` から利用者 renderer を直接呼ばない。owner はどちらの protocol の renderer が有効かを保持し、`StreamRendererDelivery` を両方扱えるよう拡張する (`@unchecked Sendable` は追加しない)。main queue 上では `MainActor.assumeIsolated` を経由して新 protocol を呼び、非 Sendable な値を `@Sendable` closure へ載せない。
- `VideoRendererAdapter` を `RTCVideoTrack` から除去する経路を `terminate()` と `PeerChannel` の `didRemove stream` に追加する (`0105` の `terminate()` は adapter を native track から除去しないため、切断後も登録が残る)。`terminate()` 後に `videoRenderer` getter が無効化時の renderer を返す `0105` の契約は維持する。

### payload と順序

- `VideoFrame` 全体へ `@unchecked Sendable` を付与しない。
- `0105` で lifetime と thread affinity を保証した owned frame または狭い internal handle だけを executor 境界へ渡す。
- connection / stream の mutable reference が不要な新 callback は `streamId` などの Sendable な ID または immutable snapshot を利用する。
- 1 event ごとに独立した unstructured Task を生成せず、sequence を保持する単一経路から MainActor へ配送する。
- remove / disconnect 後の stale frame を破棄し、buffer 上限は既存の `maxPendingRendererFrameCount` を流用する。上限超過時は新しく到着した frame を破棄する (ingress と同じ方針)。

### legacy compatibility

- legacy `VideoRenderer` と `MediaStream.videoRenderer` の型は本 issue では変更しない。
- `VideoView` は `0122` まで legacy `VideoRenderer` と `MainActorVideoRenderer` の両方に準拠する。`@preconcurrency` は `Sora/VideoView.swift` の `extension VideoView: @preconcurrency VideoRenderer` だけに付け、`Sora/` の他の宣言に増やさない。
- `VideoView` の `isRendering` は main thread 上でのみ読み書きする。新経路は `@MainActor` 隔離で型保証し、legacy 準拠経由の callback は main queue 配送の実行時保証に留める。`0122` で legacy 準拠を削除するまでこの状態を維持する。
- 新経路は `@preconcurrency` と unchecked event box に依存しない。
- legacy protocol 全体の deprecation は、`0060` の custom executor 契約と移行先が確定した後に判断する。単純な `renamed:` は利用箇所を移行できないため使用しない。
- legacy API の削除は次期 major version の `0122` で扱う。event box (`VideoRendererSizeEvent` / `VideoRendererFrameEvent`) は `0105` が削除済みである。

### `0070` との関係

- 本 issue を先行する場合は、renderer 配送の抽象を WebRTC 型に依存させない。`0070` の Phase 3 は `StreamFrameOwner` を、Phase 4 は `VideoView` / `VideoRenderer` / `VideoFrame` の vendor 依存を置き換えるため、本 issue の抽象が WebRTC 型に依存すると Phase 3 / Phase 4 の置換対象が増える。
- `0070` が先行する場合も、UI 専用 MainActor と non-UI custom executor の契約を混在させない。

## テスト方針

モック・スタブは使用しない。

- `0107` の consumer package で、legacy `VideoRenderer` 実装 (`TestConsumers/Swift6Consumer/Sources/ConsumerCore/HandlerCompatibility.swift` の `EmptyVideoRenderer`) と `VideoView` (`TestConsumers/Swift6Consumer/Sources/ConsumerUI/VideoViewScenario.swift`) の 2 ケースは compile 済みである。新 protocol だけの実装と新登録 API の 2 ケースを追加し、`VideoViewScenario.swift` と `NegativeChecks/ui-isolated-conformance.swift` を新しい隔離と登録 API に合わせて更新する。
- 実 WebRTC frame と実 `VideoView` を使用し、全 callback が main queue 上で実行されることを確認する。検査は callback 内で `Thread.isMainThread` を確認するテスト用 renderer で行う。
- add、size、frame、switch、remove、disconnect の順序と、disconnect 後の stale frame 破棄を確認する。
- legacy と新 API が同じ renderer slot を共有すること (後から設定した方が有効になり、以前の renderer に `onRemoved` が 1 回だけ配送されること、`nil` の代入が有効な側だけを解除すること) を確認する。
- Main Thread Checker は Xcode の scheme Diagnostics による手元確認に限り使い、CI の Thread Sanitizer job とは併用しない。
- strict concurrency と warnings-as-errors で SDK と consumer package を build する。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt` を再生成し、`make api-check-fresh` が成功することを確認する (Xcode 26.6 + `iphoneos26.5`)。

## 完了条件

- UI 描画用の public `@MainActor` protocol `MainActorVideoRenderer` と、`MediaStream.mainActorVideoRenderer` が追加されていること。
- 7 種類の全 callback が同じ ordered delivery abstraction を経由すること。
- `VideoView` が `MainActorVideoRenderer` に準拠し、新登録 API から設定できること。
- 新経路が `@preconcurrency` と `@unchecked Sendable` event box に依存していないこと。
- legacy `VideoRenderer` 準拠を残す間、`@preconcurrency` を付けた準拠宣言が `Sora/VideoView.swift` の 1 箇所だけであること (`grep -rnE '^extension .*: @preconcurrency' Sora/` が 1 行であることを確認する)。
- raw `VideoFrame`、`MediaStream`、`MediaChannel` を新たな unchecked box で executor 越境させていないこと。
- callback の順序、buffer (既存の `maxPendingRendererFrameCount`)、drop、stale frame の契約が、`Sora/VideoRenderer.swift` / `Sora/MediaStream.swift` の doc comment と `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節に記載されていること。
- `VideoRendererAdapter` を `RTCVideoTrack` から除去する `nativeVideoTrack?.remove(adapter)` が `terminate()` と `PeerChannel` の `didRemove stream` の経路で呼ばれていること (コードで確認する)。`terminate()` 後に `videoRenderer` getter が無効化時の renderer を返し、`videoRendererAdapterForTesting` が adapter を保持していること。
- 既存の `VideoRenderer` 実装が破壊的変更なしでビルドできること。
- strict concurrency と warnings-as-errors の build が成功すること。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること。
- `CHANGES.md` の `## develop` セクションの種別順 (`[ADD]` は `[FIX]` より前) に次のエントリを追加すること:
  ```
  - [ADD] MainActor 前提の映像描画プロトコル `MainActorVideoRenderer` と専用登録 API を追加する
    - @voluntas
  ```

## 解決方法
