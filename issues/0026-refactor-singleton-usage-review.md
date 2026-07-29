# シングルトン使用箇所の設計を見直す

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-singleton-usage-review
- Polished: 2026-06-06

## 目的

`WrapperVideoEncoderFactory.simulcastEnabled` がグローバル状態として共有されており、複数接続が並行して存在するときにサイマルキャスト設定が混線し得る。`NativePeerChannelFactory` は既に接続単位のインスタンスとして扱われているため、エンコーダーファクトリーも接続単位に持たせ、グローバル状態を解消する。

本 issue のスコープは `WrapperVideoEncoderFactory.simulcastEnabled` の混線解消のみとする。`CameraVideoCapturer`・`Logger.shared`・`Sora.shared` の共有静的状態は本 issue のスコープ外とする。

## 優先度根拠

- 複数接続が並行するユースケースで `simulcastEnabled` が上書きされるリスクがあるが、単一接続の通常利用では問題が顕在化しない。
- `NativePeerChannelFactory` 自体は既に接続単位インスタンス化されており、残る影響範囲は `simulcastEnabled` の一変数に限られる。急ぐ必要がないため Low とする。

## 現状

`WrapperVideoEncoderFactory` はシングルトンで `simulcastEnabled` を可変プロパティとして保持している（`Sora/NativePeerChannelFactory.swift:6`・`Sora/NativePeerChannelFactory.swift:16`）。

`NativePeerChannelFactory.init()` はこのシングルトンを `RTCPeerConnectionFactory` の `encoderFactory:` 引数に渡す。

```swift
// Sora/NativePeerChannelFactory.swift:50-56
let encoder = WrapperVideoEncoderFactory.shared
let decoder = RTCDefaultVideoDecoderFactory()
nativeFactory =
  RTCPeerConnectionFactory(
    encoderFactory: encoder,
    decoderFactory: decoder,
    audioDeviceModule: audioDeviceModule)
```

`PeerChannel` は接続のたびにこのグローバル状態を 2 箇所で書き換える。

```swift
// Sora/PeerChannel.swift:260
WrapperVideoEncoderFactory.shared.simulcastEnabled = configuration.simulcastEnabled
```

```swift
// Sora/PeerChannel.swift:1035
WrapperVideoEncoderFactory.shared.simulcastEnabled = simulcast
```

`PeerChannel.swift:258` 付近には次の TODO コメントが存在する。

```swift
// TODO(zztkm): WrapperVideoEncoderFactory は type: offer メッセージを受け取ったときに
// 設定されるので、ここでの設定は不要かもしれない
```

この TODO が示すとおり、行 260 の設定は行 1035（`type: offer` 受信時）と二重になっている可能性がある。実装前に要否を確認し、不要であれば行 260 の設定も合わせて削除する。

## 設計方針

**`WrapperVideoEncoderFactory` を接続単位インスタンスにする**:

- `NativePeerChannelFactory` に `private let videoEncoderFactory: WrapperVideoEncoderFactory` を追加し、`init()` 内で `WrapperVideoEncoderFactory()` をインスタンス化する（`WrapperVideoEncoderFactory.shared` の参照を削除）。
- `NativePeerChannelFactory.init()` 行 50 の `let encoder = WrapperVideoEncoderFactory.shared` は `videoEncoderFactory` に置き換える。同 init の行 58 の `encoder.supportedCodecs()` も `videoEncoderFactory.supportedCodecs()` に更新する。
- `NativePeerChannelFactory` に `var simulcastEnabled: Bool` を forwarding プロパティとして追加し、`videoEncoderFactory.simulcastEnabled` への委譲とする。
- `PeerChannel.swift:260` と `:1035` の `WrapperVideoEncoderFactory.shared.simulcastEnabled = ...` を `self.nativePeerChannelFactory.simulcastEnabled = ...` に変更する（`PeerChannel.swift:156` で `let nativePeerChannelFactory: NativePeerChannelFactory` として保持されている）。
- `WrapperVideoEncoderFactory.shared`（`NativePeerChannelFactory.swift:6`）への参照がなくなった時点で `static let shared` 宣言を削除する。
- `WrapperVideoEncoderFactory` の行 4 のクラスコメント（`// WebRTC のエンコーダーファクトリーを共有して扱うため、@unchecked Sendable を付与します`）を実態に合わせて更新する。`@unchecked Sendable` を引き続き付与する場合は、付与理由（WebRTC の非 Sendable 型を保持するため）を正しく記載する。

**スレッドセーフ性**:

`NativePeerChannelFactory` は `@unchecked Sendable`（行 36）であり、コメントに「呼び出し側でスレッド安全性を担保する前提」と明記されている。`PeerChannel.swift:260` と `:1035` での書き込みが既存の `PeerChannel` のスレッドモデル（接続処理のキュー）上で行われているかを実装前に確認し、既存の担保方針の範囲内であれば追加の排他制御は不要とする。

**行 260 の TODO 調査**:

行 1035 の `type: offer` 受信時の設定だけで `simulcastEnabled` が正しく機能するかを確認し、行 260 が冗長であれば削除する。どちらのパスが先に呼ばれるか（`NativePeerChannelFactory` の作成タイミングと接続フローの順序）を `PeerChannel.swift` の初期化シーケンスで確認すること。調査結果と判断根拠を `## 解決方法` に記載すること。

**本 issue のスコープ外**:

- `CameraVideoCapturer.current` / `front` / `back` / `handlers` の共有静的状態は公開 API であり、本 issue では扱わない。
- `Logger.shared` および `Sora.shared` は本 issue では扱わない。

## テスト方針

モック・スタブは使用しない。

- `simulcastEnabled` の設定が接続単位に分離されていることを、サイマルキャスト設定の異なる 2 接続を並行して行う手動テストで確認する。
- 既存の全テストがパスすること（`swift test` または Xcode でテストを実行）。
- 単一接続での通常の映像送受信（サイマルキャストあり・なし両方）が引き続き正常に動作することを実機または Simulator で手動確認すること。

## 完了条件

- `WrapperVideoEncoderFactory` が `NativePeerChannelFactory` 内で接続単位インスタンスとして保持され、`static let shared` が削除されていること。
- `PeerChannel.swift` から `WrapperVideoEncoderFactory.shared` への直接参照がなくなっていること。
- `PeerChannel.swift:260` 付近の TODO を調査し、判断根拠を `## 解決方法` に記載していること。不要であれば該当行を削除していること。
- スレッドセーフ性の調査結果（`PeerChannel` のどのキューで `simulcastEnabled` が書き換えられているか、追加の排他制御が必要か否か）を `## 解決方法` に記載していること。
- `WrapperVideoEncoderFactory` のクラスコメントが接続単位インスタンスの実態を反映した内容に更新され、`@unchecked Sendable` の付与理由（WebRTC の非 Sendable 型を保持するため）が明記されていること。
- 既存の全テストがパスすること。
- 単一接続での映像送受信の挙動が変わらないこと。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` セクションが存在しない場合は新設すること）:
  ```
  - [UPDATE] WrapperVideoEncoderFactory を接続単位インスタンスにして simulcastEnabled のグローバル状態を解消する
    - @voluntas
  ```

## 解決方法
