# シングルトン使用箇所の設計を見直す

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-singleton-usage-review

## 目的

共有静的状態（シングルトン）経由で利用する設計は、所有関係やライフサイクル管理がわかりづらく、複数接続時には状態が混線するリスクがある。共有静的状態を整理し、所有関係とライフサイクルを明確にする。少なくとも `WrapperVideoEncoderFactory.simulcastEnabled` のグローバル書き換えによる複数接続時の混線を解消する。

## 優先度根拠

- 純粋な設計見直し（リファクタリング）であり、急ぐ必要がないため Low とする。
- 混線リスクのうち最も深刻だった `NativePeerChannelFactory` のシングルトン化は既に接続ごとのインスタンスへ変更済みであり、残る項目は緊急度が相対的に低い。

## 現状

接続単位で分離されるべき状態が、共有静的状態として残っている箇所がある。

`WrapperVideoEncoderFactory` がシングルトンで、`simulcastEnabled` を可変で保持している。

```swift
// Sora/NativePeerChannelFactory.swift:6
static let shared = WrapperVideoEncoderFactory()
// ...
// Sora/NativePeerChannelFactory.swift:16
var simulcastEnabled = false
```

`PeerChannel` が接続のたびにこのグローバル状態を書き換える。

```swift
// Sora/PeerChannel.swift:260
WrapperVideoEncoderFactory.shared.simulcastEnabled = configuration.simulcastEnabled
```

```swift
// Sora/PeerChannel.swift:1035
WrapperVideoEncoderFactory.shared.simulcastEnabled = simulcast
```

複数接続でサイマルキャスト設定の有無が異なる場合、設定が混線し得る。

加えて `CameraVideoCapturer` の共有状態がある。`front` / `back` はキャッシュされた実体で `stream` を保持し、`current` は `nonisolated(unsafe) static var` で各所が依存している。

```swift
// Sora/CameraVideoCapturer.swift:36
public private(set) nonisolated(unsafe) static var current: CameraVideoCapturer?
```

複数 `MediaChannel` でストリームや停止／再開対象が上書きされ得る。`Sora/VideoMute.swift:87` の `CameraVideoCapturer.current` 参照もこれに依存する。`handlers`（`Sora/CameraVideoCapturer.swift:170`、`nonisolated(unsafe) static var`）も全接続共通である。

さらに `Logger.shared`（`Sora/Logger.swift:192`、`sharedStorage` は `Sora/Logger.swift:190`）はログレベルや出力先が全接続共通であり、`Sora.shared`（`Sora/Sora.swift:98`）も静的シングルトンである。

なお `VideoHardMuteActor` の静的保持に起因する混線は別途扱うため、本 issue では対象外とする。

## 設計方針

- `WrapperVideoEncoderFactory` の `simulcastEnabled` グローバル状態を解消する。`NativePeerChannelFactory` 自体は既に接続単位インスタンス化されているため、エンコーダーファクトリーも接続単位に持たせる方向を優先的に検討する。あるいは常に `RTCVideoEncoderFactorySimulcast` を用いて切り替え用グローバル状態を削除する。
- `CameraVideoCapturer` の `front` / `back` / `current` / `handlers` の共有状態を、少なくとも `MediaChannel`（あるいはカメラ管理オブジェクト）所有のインスタンスへ寄せられないか検討する。
- `Logger` は注入可能なインスタンス設計への移行を検討する（複数 `Sora` インスタンスやテスト分離を重視する場合）。影響が広いため本 issue では方針整理に留める。
- 後方互換性: `CameraVideoCapturer.current` / `handlers`、`Logger.shared`、`Sora.shared` は公開 API であり、安易な削除はできない。公開 API の破壊が必要な項目は段階的 deprecate を前提に別途切り出す。

## 完了条件

- 各シングルトン／共有静的状態について、接続単位に持たせるべきか、共有のまま許容するかの方針が整理されていること。
- 少なくとも `WrapperVideoEncoderFactory.simulcastEnabled` のグローバル書き換えによる複数接続時の混線が解消されていること。
- 公開 API を破壊する項目は、影響範囲と移行手順が明確化され、必要なら別 issue に分割されていること。
- 既存の単一接続利用の挙動が変わらないこと。
- `CHANGES.md` の `## develop` セクションに該当する種別のエントリと担当者行を追記すること。

## 解決方法
