# CallKit を利用したサンプルを作る

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-callkit-sample
- Polished: 2026-11-26
- Refreshed: 2026-11-26

## 目的

CallKit を利用したサンプルを作成し、必要であれば iOS SDK 側を CallKit に対応させる。CallKit によりシステム標準の通話 UI を利用でき、通話アプリとしてのユーザー体験が向上する。バックグラウンドでの音声継続には `UIBackgroundModes` の `audio` と active な AudioSession が必要であり、CallKit は音声セッションのアクティベーションを管理する。

## 優先度根拠

- 他社 SDK が提供しており通話アプリとして重要なバックグラウンド処理に関わる機能追加のため、戦略的に対応したい。
- 緊急のバグ修正ではなく、まずサンプルでの検証段階のため High ではなく Medium とする。

## 現状

iOS SDK に CallKit 対応が存在しない。`Sora/` 配下に `CXProvider` / `CXCallController` / PushKit に関する実装は見当たらない。

この issue のサンプルは別リポジトリ `sora-ios-sdk-quickstart`（`README.md` 参照）に追加する。quickstart は `develop` を持たないため、作業時点の開発ブランチを base にする。samples は別のサンプル集であり、本 issue では quickstart を変更対象とする。

**SDK 側の制約:**

- `NativePeerChannelFactory` の `init(bypassVoiceProcessing:audioDevice:audioSessionUsage:audioSessionCoordinator:) throws`（`Sora/NativePeerChannelFactory.swift`）では `RTCAudioDeviceModule(bypassVoiceProcessing:stereoPlayoutEnabled:)` を生成する。この ADM は `MediaChannel` の `init(snapshot:configuration:audioDevice:...)` から一度だけ生成され、接続中に差し替えられない。切断後に再接続する場合は `Sora` の `connect(configuration:webRTCConfiguration:handler:)` によって `MediaChannel` および `NativePeerChannelFactory` が新たに生成されるため、再接続時に `bypassVoiceProcessing` の設定を変更できる。
- SDK は送信接続で `AudioSessionCoordinator` により `RTCAudioSessionConfiguration.webRTC()` の category を `AVAudioSession.Category.playAndRecord` に設定する（`Sora/AudioSessionCoordinator.swift` の `requirePlayAndRecord`）。`PeerChannel.initializeAudioInput` は `RTCAudioSession.initializeInput` による音声入力の初期化を行う。CallKit は `CXProviderDelegate.provider(_:didActivate:)` でシステムが `AVAudioSession` を有効化してから音声ユニットを起動することを要求する。
- `Sora` クラスには `usesManualAudio` と `audioEnabled`（ともに `Sora/Sora.swift`）が公開されており、libwebrtc の音声ユニットの初期化を手動制御できる。`usesManualAudio = true` にすると音声ユニットは自動初期化されず、`audioEnabled = true` は音声ユニットの初期化を許可し、WebRTC が音声接続の確立時（必要時）に初期化・起動する。CallKit との統合ではこのパターンが推奨される。
- `Sora` の `connect(configuration:webRTCConfiguration:handler:)` の戻り値は `ConnectionTask` である（`Sora/Sora.swift`）。接続完了は `handler: (MediaChannel?, Error?) -> Void` コールバックで通知される。コールバックで受け取った `MediaChannel` は切断時（`mediaChannel.disconnect(error:)`）のために保持が必要である。
- `Sora.setAudioMode(_:)` は接続完了後に呼ぶことが推奨されている（`Sora/Sora.swift` のコメント参照）。そのため `AudioMode.voiceChat(output:)` の設定は `sora.connect(...)` の完了コールバック内で行う。
- `Sora/AudioMode.swift` に定義された `AudioMode.voiceChat(output: AudioOutput)` は `AVAudioSession.Mode.voiceChat` と `playAndRecord` を組み合わせた CallKit 通話向けの設定である。関連値 `output: AudioOutput` で音声出力先を指定する。`.default` は端末の状態に依存し（`Sora/AudioMode.swift` の `AudioOutput.default` ドキュメント参照）、通常はイヤーピースになるが保証はない。
- `Configuration.bypassVoiceProcessing` のデフォルト値は `false`（`Sora/Configuration.swift`）。

## 設計方針

- 初期スコープは**発信のみ**とし、着信（PushKit による VoIP プッシュ）は別 issue とする。iOS 13 以降、着信処理に PushKit を使う場合は CallKit との連携が必須かつ複雑になるため、初回は発信のみに絞る。
- `sora-ios-sdk-quickstart` リポジトリに CallKit を利用したサンプルを追加し、Sora iOS SDK と組み合わせて発信通話 UI が機能することを確認する。
- 変更対象は `sora-ios-sdk-quickstart` の `SoraQuickStart/Info.plist`、`SoraQuickStart` の Swift 実装、`CHANGES.md` とする。`Branch:` は `sora-ios-sdk-quickstart` に切るブランチ名である。`sora-ios-sdk` 側の変更が必要な場合は SDK 側の別ブランチで扱う。
- `sora-ios-sdk-quickstart` の `SoraQuickStart/Info.plist` の `UIBackgroundModes` に `audio` と `voip` を追加する。`audio` がないとバックグラウンドでの音声継続が動作しない。`voip` は CallKit のトランザクションで必要であり、欠落している場合、`CXErrorCodeRequestTransactionError.unentitled` の主な原因になる。`voip` は PushKit による着信を扱う別 issue でも使う。
- サンプルの設計フローは以下とする:
  0. `CXProviderConfiguration` から `CXProvider` を生成して delegate を設定し、`CXProvider` と `CXCallController` を保持する。
  1. `let sora = Sora.shared` を使い、`sora.usesManualAudio = true` を設定する。これにより libwebrtc は音声ユニットを自動初期化しなくなる。
  2. 通話ごとに UUID を生成し、`CXStartCallAction` を `CXTransaction` に追加して `CXCallController.request` でリクエストする。リクエストのエラーは `CXStartCallAction` の失敗として扱う。
  3. `provider(_:perform:)` の `CXStartCallAction` ハンドラで `sora.configureAudioSession` により `playAndRecord` と `voiceChat` を設定し、`action.fulfill()` を呼び、`provider.reportOutgoingCall(with:startedConnectingAt:)` を呼ぶ。開始処理に失敗した場合は `action.fail()` を呼ぶ。
  4. `provider(_:didActivate:)` でシステムが `AVAudioSession` を有効化した後、`sora.audioEnabled = true` を設定してから `sora.connect(...)` を呼ぶ。`didActivate` は保留・再開などで複数回呼ばれ得るため、`sora.connect` は通話開始時の 1 回だけ呼び、2 回目以降は `audioEnabled = true` の設定だけを行う。
  5. 接続完了コールバックで受け取った `MediaChannel` を保持し、`sora.setAudioMode(.voiceChat(output: .default))` の `Result` を確認する。成功時に `provider.reportOutgoingCall(with:connectedAt:)` を呼ぶ。失敗時はログに記録し、通話を終了する。
  6. 通話終了時は `CXEndCallAction` ハンドラで `mediaChannel.disconnect(error:)` を呼んで Sora から切断し、`action.fulfill()` を呼ぶ。Sora 側からの切断や接続失敗では `provider.reportCall(with:endedAt:reason:)` を呼び、通話 UI を終了する。
  7. `provider(_:didDeactivate:)` でシステムが `AVAudioSession` を非活性化した後、`sora.audioEnabled = false` を設定する。
- `bypassVoiceProcessing` は `false`（デフォルト）のまま使用する。`AudioMode.voiceChat(output: .default)` を使用することを前提とし、CallKit と整合しない場合は別 issue として登録する。
- サンプル作成の過程で SDK 側の `AVAudioSession` 管理が CallKit と衝突する場合は、SDK 側で対応するか別 issue として登録する。

## テスト方針

本 issue はサンプル作成と検証が主目的であり、SDK 側に変更が生じた場合のみユニットテストを追加する。サンプルの動作確認は実機での手動テストで行い、結果を本 issue の `## 解決方法` セクションに記載する:

- 発信ボタンを押すと CallKit の通話 UI が表示されること。
- `audio` と `voip` を設定した状態で `CXStartCallAction` が成功し、通話 UI が表示されること。
- 通話 UI から Sora に接続し、音声送受信が機能すること。
- アプリをバックグラウンドに移行しても音声が継続すること（`audio` バックグラウンドモードと active な AudioSession により継続する。CallKit は音声セッションのアクティベーションを管理する）。
- 通話を終了すると Sora から切断されること。
- Sora の接続開始・完了・失敗、Sora 側からの切断で `reportOutgoingCall` / `reportCall` が呼ばれ、通話 UI が終了すること。
- `didActivate` が複数回呼ばれても Sora の接続が 1 本であること。
- `setAudioMode` の `Result` を確認し、失敗時に通話を終了できること。
- `AudioSessionCoordinator` のカテゴリ設定と CallKit の音声セッションのアクティベーション順が実機で問題ないこと。

## 完了条件

- CallKit を利用したサンプルが `sora-ios-sdk-quickstart` に作成され、`CHANGES.md` が更新され、システム標準の通話 UI から Sora への発信・切断ができること。
- バックグラウンドでの音声送受信が実機で機能することを確認できていること（テスト方針の手動テスト結果を `## 解決方法` に記載すること）。
- 着信対応は本 issue のスコープ外とし、本 issue の完了時に別 issue を起票してリンクすること。
- サンプル作成の過程で判明した SDK 側の必要対応が洗い出され、対応が必要な場合は本リポジトリで対応するか別 issue 化されていること。

## 解決方法
