# CallKit を利用したサンプルを作る

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-callkit-sample
- Polished: 2026-06-05

## 目的

CallKit を利用したサンプルを作成し、必要であれば iOS SDK 側を CallKit に対応させる。CallKit によりシステム標準の通話 UI やバックグラウンドでの音声処理が利用でき、通話アプリとしてのユーザー体験が向上する。

## 優先度根拠

- 他社 SDK が提供しており通話アプリとして重要なバックグラウンド処理に関わる機能追加のため、戦略的に対応したい。
- 緊急のバグ修正ではなく、まずサンプルでの検証段階のため High ではなく Medium とする。

## 現状

iOS SDK に CallKit 対応が存在しない。`Sora/` 配下に `CXProvider` / `CXCallController` / PushKit に関する実装は見当たらない。

サンプルは別リポジトリ `sora-ios-sdk-quickstart` （ `README.md` 参照）で管理されており、サンプルの実装作業は当該リポジトリで行う。

**SDK 側の制約:**

- `NativePeerChannelFactory.init(bypassVoiceProcessing:)`（`Sora/NativePeerChannelFactory.swift:43`）では `RTCAudioDeviceModule(bypassVoiceProcessing:)` を接続時に一度だけ生成する。この ADM は接続中に差し替えられない。切断後に再接続する場合は `Sora.connect()` によって `MediaChannel` および `NativePeerChannelFactory` が新たに生成されるため、再接続時に `bypassVoiceProcessing` の設定を変更できる。
- SDK の音声入力初期化（`Sora/PeerChannel.swift:570-571`）では、libwebrtc の内部設定オブジェクト（`RTCAudioSessionConfiguration.webRTC()`）に `AVAudioSession.Category.playAndRecord` を設定する。CallKit は `CXProviderDelegate.provider(_:didActivate:)` でシステムが `AVAudioSession` を有効化してから音声ユニットを起動することを要求する。
- `Sora` クラスには `usesManualAudio`（`Sora/Sora.swift:224`）と `audioEnabled`（`Sora/Sora.swift:243`）が公開されており、libwebrtc の音声ユニットの初期化を手動制御できる。`usesManualAudio = true` にすると音声ユニットは自動初期化されず、`audioEnabled = true` を代入した時点で初めて起動される。CallKit との統合ではこのパターンが推奨される。
- `Sora.connect()` の戻り値は `ConnectionTask` である（`Sora/Sora.swift:171-179`）。接続完了は `handler: (MediaChannel?, Error?) -> Void` コールバックで通知される。コールバックで受け取った `MediaChannel` は切断時（`mediaChannel.disconnect(error:)`）のために保持が必要である。
- `Sora.setAudioMode(_:)` は接続完了後にのみ呼び出せる（`Sora/Sora.swift:304` のコメント参照）。そのため `AudioMode.voiceChat(output:)` の設定は `Sora.connect()` の完了コールバック内で行う。
- `Sora/AudioMode.swift` に定義された `AudioMode.voiceChat(output: AudioOutput)` は `AVAudioSession.Mode.voiceChat` と `playAndRecord` を組み合わせた CallKit 通話向けの設定である。関連値 `output: AudioOutput` で音声出力先を指定する。`.default` は端末の状態に依存し（`Sora/AudioMode.swift` の `AudioOutput.default` ドキュメント参照）、通常はイヤーピースになるが保証はない。
- `Configuration.bypassVoiceProcessing` のデフォルト値は `false`（`Sora/Configuration.swift:155`）。

## 設計方針

- 初期スコープは**発信のみ**とし、着信（PushKit による VoIP プッシュ）は別 issue とする。iOS 13 以降、着信処理に PushKit を使う場合は CallKit との連携が必須かつ複雑になるため、初回は発信のみに絞る。
- `sora-ios-sdk-quickstart` リポジトリに CallKit を利用したサンプルを追加し、Sora iOS SDK と組み合わせて発信通話 UI が機能することを確認する。
- `Info.plist` の `UIBackgroundModes` に `voip` を追加する。これがないとバックグラウンドでの音声継続が動作しない。
- サンプルの設計フローは以下とする:
  1. アプリ起動時または接続前に `sora.usesManualAudio = true` を設定する。これにより libwebrtc は音声ユニットを自動初期化しなくなる。
  2. `CXStartCallAction` をリクエストして CallKit 通話 UI を表示する。
  3. `provider(_:perform:)` の `CXStartCallAction` ハンドラで `action.fulfill()` を呼ぶ（発信が受け付けられたことを CallKit に通知する）。
  4. `provider(_:didActivate:)` でシステムが `AVAudioSession` を有効化した後、`sora.audioEnabled = true` を設定してから `Sora.connect()` を呼ぶ。
  5. 接続完了コールバックで受け取った `MediaChannel` を保持し、`sora.setAudioMode(.voiceChat(output: .default))` を呼ぶ。
  6. 通話終了時は `CXEndCallAction` ハンドラで `mediaChannel.disconnect(error:)` を呼んで Sora から切断し、`action.fulfill()` を呼ぶ。
  7. `provider(_:didDeactivate:)` でシステムが `AVAudioSession` を非活性化した後、`sora.audioEnabled = false` を設定する。
- `bypassVoiceProcessing` は `false`（デフォルト）のまま使用する。`AudioMode.voiceChat(output: .default)` を使用することを前提とし、CallKit と整合しない場合は別 issue として登録する。
- サンプル作成の過程で SDK 側の `AVAudioSession` 管理が CallKit と衝突する場合は、SDK 側で対応するか別 issue として登録する。

## テスト方針

本 issue はサンプル作成と検証が主目的であり、SDK 側に変更が生じた場合のみユニットテストを追加する。サンプルの動作確認は実機での手動テストで行い、結果を本 issue の `## 解決方法` セクションに記載する:

- 発信ボタンを押すと CallKit の通話 UI が表示されること。
- 通話 UI から Sora に接続し、音声送受信が機能すること。
- アプリをバックグラウンドに移行しても音声が継続すること（CallKit の VoIP バックグラウンド実行により継続が保証される）。
- 通話を終了すると Sora から切断されること。

## 完了条件

- CallKit を利用したサンプルが `sora-ios-sdk-quickstart` に作成され、システム標準の通話 UI から Sora への発信・切断ができること。
- バックグラウンドでの音声送受信が実機で機能することを確認できていること（テスト方針の手動テスト結果を `## 解決方法` に記載すること）。
- 着信対応の issue を別途登録すること。
- サンプル作成の過程で判明した SDK 側の必要対応が洗い出され、対応が必要な場合は本リポジトリで対応するか別 issue 化されていること。

## 解決方法
