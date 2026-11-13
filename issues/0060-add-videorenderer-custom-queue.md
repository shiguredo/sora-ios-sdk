# VideoRenderer の実行キューを指定できるようにする

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-videorenderer-custom-queue
- Polished: 2026-11-13

## 概要

`VideoRenderer` プロトコルの実装メソッドを実行するキューを利用者が指定できるようにする。現在はメインキュー固定になっており、重い処理を実装するとメインキューへの負荷が増大して UI 更新に影響する可能性がある。

## 現状

`StreamFrameOwner` (`Sora/StreamFrameOwner.swift`) が `VideoRenderer` の 7 種類の callback (`onChange(size:)` / `render(videoFrame:)` / `onDisconnect(from:)` / `onAdded(from:)` / `onRemoved(from:)` / `onSwitch(video:)` / `onSwitch(audio:)`) をすべて main queue へ最終配送する。利用者が callback の実装内で別の queue へ hop すれば重い処理自体は main queue から外せるが、7 種類すべてを同じ executor に揃えるには callback ごとに hop が必要で、API として明示的にサポートされていない。また callback 自体は main queue で呼ばれるままで、main queue が止まると `maxPendingRendererFrameCount` の上限で frame が破棄される。

## 設計方針

`VideoRenderer` プロトコルに callback の実行 queue を指定するプロパティを追加する。既存の 7 つの callback requirement は変更しない。

```swift
public protocol VideoRenderer: AnyObject {
  /// nil のときは main queue へ最終配送する
  var callbackQueue: DispatchQueue? { get }
  // ...既存の 7 つの callback requirement はそのまま
}

extension VideoRenderer {
  /// 既定は nil (main queue へ最終配送する)
  public var callbackQueue: DispatchQueue? { nil }
}
```

- `callbackQueue` は 7 種類すべての callback の最終配送先に適用する (callback の種類と登録経路は変更しない)。`nil` と `.main` はどちらも main queue への配送を表す
- デフォルト実装は `public` にする。`public` でないと別 module の conformer が requirement を満たせない
- `callbackQueue` は renderer の設置時に SDK が 1 回だけ読む。`MediaStream.videoRenderer` setter の `rendererLock` 取得前に読み、owner が renderer / 世代と一緒に保持する。設置後の変更は反映しない
- getter は呼び出し元スレッドで 1 回だけ呼ばれる。getter は軽量で副作用の無い実装にし、`MediaStream` の setter など SDK の状態を変更する API を呼ばないこと (renderer の設置処理が再入する)。並行 queue を渡しても、1 つの stream では SDK が callback を 1 件ずつ配送するため同時に 2 つ走ることはない。同じ renderer instance を複数の stream に設定した場合は stream ごとに直列化され、callback が同時に走り得る (`MediaStream.videoFilter` と同じ)
- 配送先は event ごとに決める。`added` / `removed` / `disconnect` は event が対象とする renderer の `callbackQueue`、`frame` / `size` / `switch` は owner queue で取り出す時点の現在の renderer の `callbackQueue` を使う (取り出し後に renderer が交換された場合は世代照合で破棄する)。配送先 renderer が `nil` の event は main queue へ投入し、block 内の判定で破棄する (現行と同じ観測挙動)
- 配送は単一の連鎖にする。owner queue 上で配送要素を 1 件取り出して配送先 queue へ非同期に投入し、callback が戻った後に次の要素を owner queue 上で取り出す (同時に 2 件の callback を配送しない)。lock で保護した配送中フラグを持ち、`appendDeliveryLocked` はフラグが false のときだけ true にして owner queue へ連鎖開始を投入し、フラグが立っている間は連鎖を起動しない。連鎖は callback から戻って owner queue 上で配送待ちが空になった時点でフラグを false にする。これにより renderer を交換しても旧 renderer の `onRemoved` → 新 renderer の `onAdded` の順が保たれる。`appendDeliveryLocked` が event ごとに 1 block を投入する現行構造はこの形に変更する
- 世代照合・無効化判定・`pendingRendererFrameCount` の減算は `0105` と同じく配送先 queue の block 内で行う (owner queue の取り出し時点では判定しない。取り出し後に renderer が交換された frame を配送しないため)。判定コードは SDK の配送ロジックが実行し、利用者の callback には委ねない
- 配送中の要素は owner の lock 保護の storage に置き、配送先 queue の block は owner だけを capture する。block は lock 区間で要素を取り出して lock を解放してから callback を呼ぶ (lock 保持中に利用者コードを呼ばない。現行 `deliverNextOnMainQueue` と同じ)。非 Sendable な renderer / `MediaStream` / `MediaChannel?` / frame の payload を `@Sendable` closure へ載せない既存の制約を維持する
- 利用者 queue が停止すると配送は滞留する。frame の投入時の上限破棄は現行どおり `submitRendererFrame` の `maxPendingRendererFrameCount` で行う。配送待ちの frame 数は配送先 queue の block の先頭で、世代照合・無効化判定・callback の有無にかかわらず 1 回減算する (現行 `deliverNextOnMainQueue` と同じ)
- `VideoView` は `0122` まで legacy `VideoRenderer` に準拠するため `callbackQueue` を継承するが、本 issue では実装せず既定の `nil` (main queue) のままにする。UI 描画目的で `callbackQueue` を指定する使い方は対象外とし、`0027` の `MainActorVideoRenderer` 経路は `callbackQueue` を参照せず main queue 固定とする

## `0105` との関係

`0105` で 7 種類の renderer callback の最終配送が main queue に統一され、最終配送の実行箇所は `StreamFrameOwner` の `appendDeliveryLocked` / `deliverNextOnMainQueue` になった。`0060` はその最終配送先を利用者 queue に置き換える issue である。

- 順序の決定は `0105` の `StreamFrameOwner` の owner queue が担い、利用者 queue は最終配送先としてだけ使う (順序と drop の判断を利用者実装へ委ねない)。配送要素の取り出しは owner queue 上で行い、世代照合・無効化判定・frame 数の減算は `0105` と同じく配送先 queue の block 内で行う。
- 本 issue の対象は最終配送先の置き換えと、それを実現するための配送連鎖 (1 件ずつの取り出しと配送先 queue への投入) であり、callback の種類と登録経路は変更しない。

## `0027` との関係

`0027` (VideoRenderer を互換性を保って MainActor 前提 API へ段階移行する) は UI 描画用の `@MainActor` protocol `MainActorVideoRenderer` を追加し、`VideoView` を新経路へ移行する。legacy の `VideoRenderer` と `MediaStream.videoRenderer` の型は `0027` では変更しない。

- 本 issue は legacy `VideoRenderer` に custom executor 契約 (`callbackQueue`) を追加し、non-UI renderer (映像処理、機械学習などの用途) を対象とする。
- UI 描画は `0027` の MainActor 契約に委ねる。本 issue は `MainActorVideoRenderer` へ `callbackQueue` を追加せず、`0027` の新経路は main queue 固定のままとする (MainActor 配送を型で保証する契約と矛盾しないようにするため)。
- `0027` は legacy protocol 全体の deprecation を本 issue の custom executor 契約と移行先が確定した後に判断するとしている。本 issue が定める `callbackQueue` 契約がその移行判断の前提になる。
- `0027` が先行した場合、legacy renderer と `MainActorVideoRenderer` は同じ renderer slot を共有する。`callbackQueue` は legacy renderer が有効なときだけ参照し、`MainActorVideoRenderer` が有効なときは参照しない。

## 完了条件

- `VideoRenderer` protocol に `var callbackQueue: DispatchQueue? { get }` が追加され、`public var callbackQueue: DispatchQueue? { nil }` のデフォルト実装で `nil` が返ること (同名・同型の `callbackQueue` メンバーを持たない既存の実装者は変更不要であること)。
- `StreamFrameOwner` の renderer callback の最終配送先が、`callbackQueue` 指定時はその queue、`nil` と `.main` のときは main queue になること。
- 専用の直列 queue を返す renderer を 2 つ用意して交換し、旧 renderer の `onRemoved` が旧 queue で、新 renderer の `onAdded` が新 queue で、この順に呼ばれること。
- `callbackQueue` を指定した renderer の 7 種類の callback がすべてその queue で呼ばれ、世代照合・無効化判定による破棄は配送先 queue の block 内で SDK が行い、`maxPendingRendererFrameCount` の超過による破棄は投入時に行っていること (どちらも利用者実装へ委ねていないこと)。
- `callbackQueue` 未設定の既存実装者と `VideoView` の挙動が変わらず、`VideoView` に `callbackQueue` の実装が追加されていないこと。
- renderer callback の executor 契約が次の箇所に記載されていること。
  - `Sora/VideoRenderer.swift` の protocol doc、7 callback の doc、`VideoRendererAdapter` の型 doc
  - `Sora/MediaStream.swift` の `videoRenderer` / `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` / `MediaStream.terminate()` と `BasicMediaStream.terminate()` の doc
  - `Sora/MediaChannel.swift` の `setVideoHardMute` の doc
  - `Sora/PeerChannel.swift` の切断経路の `onDisconnect` に関するコメント
  - `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節、「描画」節、「イベントの購読」の表 (`VideoRenderer` の callback の行)
  - `Sora/StreamFrameOwner.swift` の `maxPendingRendererFrameCount` など内部 doc
- `issues/0072-add-sample-buffer-video-renderer.md` の `0060` に関する記述 (`queue` プロパティへの言及 3 箇所) を `callbackQueue` に更新していること。
- `CHANGES.md` の `## develop` の種別順 (`[ADD]` は `[FIX]` より前) に、`callbackQueue` の追加を表す `[ADD]` エントリを担当者行付きで追加していること。
- strict concurrency と warnings-as-errors で SDK と consumer package を build し、既存テストと追加テストが成功すること。単一連鎖の完了を待てるよう、`StreamFrameOwner` に配送待ち件数 (配送中の 1 件を含む) を返すテスト用 accessor を追加し、`SoraTests/StreamFrameOwnerTestHelpers.swift` の `drainOwnerAndMainQueue` を「配送先 queue を 1 hop 待つ → owner queue を drain → 配送待ち件数が 0 になるまで繰り返す」形に更新すること。main queue 以外の配送先 queue を持つテスト用に、対象 queue を待つヘルパーも追加すること。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること。

## 根拠

映像処理などの重い処理を含む `render(videoFrame:)` 実装を main queue で実行すると UI のフレームドロップに直結する。callback の実装内で別の queue へ hop する方法では、7 種類すべてを同じ executor に揃えるために callback ごとの hop が必要で、callback 自体は main queue で呼ばれ続け、main queue が止まると `maxPendingRendererFrameCount` の上限で frame が破棄される。利用者が配送先 queue を指定できる手段を SDK として提供することで、この 2 点を根本的に解消できる。
