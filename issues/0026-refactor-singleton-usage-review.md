# シングルトン使用箇所の設計を見直す

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-singleton-usage-review
- Polished: 2026-09-02
- Updated: 2026-08-27

## 目的

`WrapperVideoEncoderFactory.simulcastEnabled` がグローバル状態として共有されており、複数接続が並行して存在するときにサイマルキャスト設定が混線し得る。`NativePeerChannelFactory` は既に接続単位のインスタンスとして扱われているため、エンコーダーファクトリーも接続単位に持たせ、グローバル状態を解消する。

本 issue のスコープは `WrapperVideoEncoderFactory.simulcastEnabled` の混線解消のみとする。`CameraVideoCapturer`・`Logger.shared`・`Sora.shared` の共有静的状態は本 issue のスコープ外とする。

## 優先度根拠

- 複数接続が並行するユースケースで `simulcastEnabled` が上書きされるリスクがあるが、単一接続の通常利用では問題が顕在化しない。
- `NativePeerChannelFactory` 自体は既に接続単位インスタンス化されており、残る影響範囲は `simulcastEnabled` の一変数に限られる。急ぐ必要がないため Low とする。
- 現在の simulcast E2E は shared state の混線を避けるため、同一プロセス内の全接続で `simulcastEnabled = true` に統一しており、異なる設定の並行利用は検証できていない。

## 現状

`Sora/NativePeerChannelFactory.swift` の `WrapperVideoEncoderFactory` はシングルトンで `simulcastEnabled` を可変プロパティとして保持している。

`NativePeerChannelFactory.init(bypassVoiceProcessing:audioDevice:)` は、custom `RTCAudioDevice` を利用する経路と通常の `RTCAudioDeviceModule` を利用する経路の両方で、このシングルトンを `RTCPeerConnectionFactory` の `encoderFactory:` 引数に渡す。

`Sora/PeerChannel.swift` の `PeerChannel.connect(handler:)` と `PeerChannel.handleSignalingOverWebSocket(_:)` は、接続開始時と `type: offer` 受信時にこのグローバル状態を書き換える。

`PeerChannel.connect(handler:)` には次の TODO コメントが存在する。

```swift
// TODO(zztkm): WrapperVideoEncoderFactory は type: offer メッセージを受け取ったときに
// 設定されるので、ここでの設定は不要かもしれない
```

この TODO が示すとおり、接続開始時の設定は `type: offer` 受信時の設定と二重になっている可能性がある。実装前に要否を確認し、不要であれば接続開始時の設定も削除する。

`SoraTests/SimulcastE2ETests.swift` の `testSimulcastDummyVideo` は同一プロセスで複数接続を作るが、shared state の混線を避けるため全接続で `simulcastEnabled = true` に統一している。

## 設計方針

**`WrapperVideoEncoderFactory` を接続単位インスタンスにする**:

- `NativePeerChannelFactory` に `private let videoEncoderFactory: WrapperVideoEncoderFactory` を追加し、`init(bypassVoiceProcessing:audioDevice:)` 内で `WrapperVideoEncoderFactory()` をインスタンス化する。
- custom `RTCAudioDevice` と通常の `RTCAudioDeviceModule` の両方の初期化経路へ、同じ接続単位の `videoEncoderFactory` を渡す。
- `NativePeerChannelFactory.init(bypassVoiceProcessing:audioDevice:)` の codec log も `videoEncoderFactory.supportedCodecs()` を使用する。
- `NativePeerChannelFactory` に `var simulcastEnabled: Bool` を forwarding プロパティとして追加し、`videoEncoderFactory.simulcastEnabled` への委譲とする。
- `PeerChannel.connect(handler:)` と `PeerChannel.handleSignalingOverWebSocket(_:)` の shared 参照を `nativePeerChannelFactory.simulcastEnabled` への設定に変更する。
- `WrapperVideoEncoderFactory.shared` への参照がなくなった時点で `static let shared` 宣言を削除する。
- `WrapperVideoEncoderFactory` のクラスコメントを接続単位インスタンスの実態に合わせて更新する。

**スレッドセーフ性**:

`PeerChannel.connect(handler:)` と `PeerChannel.handleSignalingOverWebSocket(_:)` は、同じ接続専用 queue から呼ばれるとは限らない。さらに `WrapperVideoEncoderFactory.createEncoder(_:)` の read 側は libwebrtc から呼ばれる。接続単位化に加えて、初期化後に設定を不変にするか、read / write を同じ同期機構で保護するなどの不変条件を定める。

`@unchecked Sendable` を残す場合は、WebRTC の non-Sendable object を保持するという理由だけでなく、`simulcastEnabled` を含む全 mutable state の同期根拠を日本語コメントに記載する。

**接続開始時の TODO 調査**:

`type: offer` 受信時の設定だけで `simulcastEnabled` が正しく機能するかを確認し、接続開始時の設定が冗長であれば削除する。`NativePeerChannelFactory.createClientOfferSDP` による一時 PeerConnection の生成を含む初期化順序を確認し、判断根拠を `## 解決方法` に記載する。

**本 issue のスコープ外**:

- `CameraVideoCapturer` の共有状態は `0103` で扱う。
- `Logger.shared` は `0106`、`Sora.shared` は `0111` で扱う。
- 接続状態の owner は `0100`、接続設定の snapshot は `0102` で扱う。
- WebRTC C API への移行は `0070` で扱う。`0026` を先行する場合は接続単位の ownership を移行後も維持し、`0070` が先行する場合は C bridge に global mutable flag を再導入しない。

## テスト方針

モック・スタブは使用しない。

- `SoraTests/SimulcastE2ETests` で、サイマルキャスト設定の異なる 2 接続を同一プロセス内で並行して実行する。
- 現在の「全接続で `simulcastEnabled = true` に統一する」workaround を削除してもテストが成功することを確認する。
- 既存の全テストがパスすること（`swift test` または Xcode でテストを実行）。
- 単一接続での通常の映像送受信（サイマルキャストあり・なし両方）が引き続き正常に動作することを実機または Simulator で手動確認すること。

## 完了条件

- `WrapperVideoEncoderFactory` が `NativePeerChannelFactory` 内で接続単位インスタンスとして保持され、`static let shared` が削除されていること。
- `PeerChannel` から `WrapperVideoEncoderFactory.shared` への直接参照がなくなっていること。
- `PeerChannel.connect(handler:)` の TODO を調査し、判断根拠を `## 解決方法` に記載していること。不要であれば接続開始時の設定を削除していること。
- `simulcastEnabled` の read / write が初期化後不変または同じ同期機構で保護され、libwebrtc callback を含む安全性の根拠が記載されていること。
- `WrapperVideoEncoderFactory` のクラスコメントが接続単位インスタンスの実態を反映し、`@unchecked Sendable` を残す場合は全 mutable state の同期根拠が明記されていること。
- 異なる `simulcastEnabled` を持つ複数接続の E2E が成功し、全接続を同じ設定へ揃える workaround が削除されていること。
- 既存の全テストがパスすること。
- 単一接続での映像送受信の挙動が変わらないこと。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` セクションが存在しない場合は新設すること）:
  ```
  - [UPDATE] WrapperVideoEncoderFactory を接続単位インスタンスにして simulcastEnabled のグローバル状態を解消する
    - @voluntas
  ```

## 解決方法
