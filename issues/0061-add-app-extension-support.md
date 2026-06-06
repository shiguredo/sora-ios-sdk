# App Extension に対応する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-app-extension-support
- Polished: 2026-06-06

## 目的

SDK を `APPLICATION_EXTENSION_API_ONLY = YES` の設定でビルドできるようにし、App Extension 内での SDK 利用を可能にする。

## 優先度根拠

App Extension 内で WebRTC 接続を行うユースケース（例: CallKit Extension、Notification Service Extension など）の需要が現状確認されていない。また現在の ScreenCapture 実装（`RPScreenRecorder` ベースのアプリ内画面キャプチャ）は Broadcast Upload Extension とは別のアーキテクチャであり、Extension 対応を追加しても ScreenCapture 機能が Extension 内で動作するようになるわけではない。これらの理由から Low とする。

## 現状

`APPLICATION_EXTENSION_API_ONLY = YES` でのビルドが通らない箇所として以下が特定できている。

### 調査が必要な問題箇所（ビルドエラーになる可能性があるもの）

- **`DeviceInfo.swift:29-38`**: `UIDevice.current.systemName` / `systemVersion` を参照している。`UIKit` API の一部は `APPLICATION_EXTENSION_API_ONLY = YES` 環境でエラーになる可能性があり、`UIDevice` もその対象となり得る
- **`ScreenCapture.swift:62`**: `RPScreenRecorder.shared()` を使用している。`RPScreenRecorder` は Broadcast Upload Extension 内では `RPBroadcastSampleHandler` を使う別アーキテクチャが前提となり、現在の実装はそのまま Extension 内では動作しない
- **`VideoView.swift`・`AspectRatio.swift`**: `import UIKit` および `UIView` サブクラスを使用しているため、Extension での UI 描画制約と合わせて確認が必要
- 上記以外にも問題箇所が存在する可能性がある。`APPLICATION_EXTENSION_API_ONLY = YES` を設定してビルドし、全エラーを列挙してから対応方針を確定すること

### Swift PM での設定確認方法

`Package.swift` は `APPLICATION_EXTENSION_API_ONLY` を直接設定できない。ライブラリ利用側（アプリの Xcode プロジェクト）で Extension ターゲットに SDK を組み込んでビルドすることで確認できる。

## 設計方針

問題箇所ごとに以下のアプローチを採用する。

まず `APPLICATION_EXTENSION_API_ONLY = YES` でビルドして全エラーを列挙し、各エラーに対して以下のアプローチを適用する。

### `DeviceInfo.swift` の `UIDevice.current`

現在の実装（`DeviceInfo.swift:29-38`）は `UIDevice.current.systemName` / `systemVersion` を `MainActor.assumeIsolated` 経由で参照している。`UIDevice` は `APPLICATION_EXTENSION_API_ONLY = YES` 環境で利用不可になる可能性があり、その場合は以下の方針で置き換えること。

- `systemName`: `#if os(iOS)` 等のコンパイル条件で `"iOS"` を静的に決定するか、`UIKit` なしで取得可能な代替方法を検討する
- `systemVersion`: `ProcessInfo.processInfo.operatingSystemVersion`（`major`・`minor`・`patch` を持つ `OperatingSystemVersion` 型）で代替する

`DeviceInfo.systemName` / `systemVersion` はシグナリング送信情報（端末識別）として使用されており、フォールバック値が許容されるかを確認した上で実装すること。

### `ScreenCapture.swift` の `RPScreenRecorder`

現状は `private let recorder = RPScreenRecorder.shared()`（`ScreenCapture.swift:62`）としてプロパティ初期化時に呼んでいる。`APPLICATION_EXTENSION_API_ONLY = YES` で実際にビルドエラーになるかを先に確認し、エラーになる場合は `private lazy var recorder = RPScreenRecorder.shared()` への変更や条件分岐での回避を検討する。Broadcast Upload Extension 向けの `RPBroadcastSampleHandler` ベースの本格対応は本 issue のスコープ外とする。

## 完了条件

- `APPLICATION_EXTENSION_API_ONLY = YES` を設定した Extension ターゲット（検証用の Xcode プロジェクトに Extension ターゲットを作成し SDK を組み込む方法で確認する。`Package.swift` には直接設定できない）でビルドエラーが 0 件になること
- `DeviceInfo.swift` の `UIDevice.current` 依存が App Extension 対応 API に置き換えられているか、または Extension ビルドでエラーにならないことが確認されていること
- `ScreenCapture.swift` の `RPScreenRecorder.shared()` が Extension 環境でもビルドエラーにならないよう対処されていること
- `VideoView.swift` / `AspectRatio.swift` についてビルドエラーが確認された場合は対処されていること
- 既存の非 Extension 環境での動作が変わらないこと（カメラキャプチャ・画面共有・音声の各機能が引き続き動作すること）
- `CHANGES.md` の `## develop` セクションに以下を追記すること

```
- [UPDATE] App Extension 環境での SDK ビルドに対応する
  - @voluntas
```
