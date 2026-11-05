# 画面キャプチャの後始末に失敗した recorder が MediaChannel の解放後に回復できなくなる問題を修正する

- Created: 2026-10-30
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-recorder-quarantine-recovery
- Polished: 2026-11-02

## 目的

画面キャプチャの停止に失敗すると、`ScreenCaptureRecorderCoordinator` は recorder の owner を保持したまま隔離状態になる。owner を保持する `MediaChannel` / `ScreenCaptureController` が解放されると、隔離の解除に必要な owner ID を提示できる主体がなくなり、プロセス再起動まで画面キャプチャを開始できなくなる。この回復不能状態を修正する。

## 現状

- `ScreenCaptureRecorderCoordinator.finishStop(ownerID:recorderStopped:)` は owner が一致する場合だけ隔離を解除し、停止に失敗した場合は owner を保持して `quarantined = true` にする (`Sora/ScreenCapture.swift`)
- `acquire(ownerID:)` は `ownerID == nil` かつ非隔離のときだけ成功するため、owner を保持したまま controller が解放されると、同じ recorder を以後取得できない
- `MediaChannel.deinit` は `prepareForDisconnect` 経由で `stopCaptureForDisconnect` を呼び、最後の停止を試みる。この停止も失敗した場合、`ScreenCaptureController` は解放され、`recorderOwnerID` の UUID を保持する主体がなくなる
- 別の `MediaChannel` から `stopScreenCapture()` を呼んでも停止は実行されない。画面キャプチャを一度も開始していない接続では `currentScreenCaptureController()` が nil であり、開始に失敗した接続でも `captureState` が `.stopped` のため `scheduleStopCapture()` が nil を返す。`beginScreenStop()` も、自身の `VideoSourceCoordinator` に画面キャプチャの状態がないため nil を返す
- 結果として、owner を保持したまま停止に失敗した接続が解放されると、プロセス全体の画面キャプチャが以後使用不能になる

## 再現手順

- 画面キャプチャを開始し、停止を失敗させる
- その接続の `MediaChannel` を解放する (最後の停止試行も失敗させる)
- 別の接続を作成して `startScreenCapture` を呼ぶと、`acquire` が失敗し続ける
- 実 ReplayKit の停止失敗は自動テストで再現できないため、coordinator と controller のイベント列テストで確認する

## 設計方針

- 隔離中に別接続が recorder を取得できない状態と、`finishStop` の owner 一致ガードは維持する。owner を保持している間の通常停止経路の意味も変えない
- 隔離を起こす録画は、SDK が `startCapture` を発行して停止に失敗した録画に限られる (`finishStop` を呼ぶのは owner 経路だけで、ホストが開始済みの録画は `startRecorderCaptureIfIdle` が `.alreadyRecording` として開始しない)。このため、owner を失った隔離は、後続の接続が停止確認付きで解除できるようにする
- controller の解放時に `ScreenCaptureRecorderCoordinator` の owner を放棄する (`release(ownerID:)` と同じく owner が一致する場合だけ `ownerID` を nil にし、`quarantined` は維持する)。これにより、隔離を解除できる主体がプロセス内から消えることを防ぎ、後続の接続による解除へ引き継ぐ
- 別接続の `startCapture` は `quarantined` かつ `ownerID == nil` を検出したら、共有 recorder の停止を 1 回試みる。`isRecording == false` を確認できた場合だけ `quarantined = false` にして開始を続け、確認できない場合は隔離を維持して開始を失敗させる
- owner を失った隔離の解除は owner 一致を要求する `finishStop` では行えないため、`quarantined` かつ `ownerID == nil` を確認して解除する coordinator の API を追加する。owner 一致が成立する停止成功時の `finishStop` による解除は現行どおり維持し、そのガードは変えない
- ReplayKit は録画の所有者を照会できないため、SDK の録画が終了した後にホストが開始した録画を、この解除経路で停止する可能性は排除できない。この制約を doc コメントと `skills/sora-ios-sdk/SKILL.md` に明記し、既存の「SDK がホストの録画を停止することがあります」という記述に統合する
- 停止の再試行は coordinator の直列 queue 上で行い、複数の接続が同時に再試行しないようにする
- 停止結果の反映は実 ReplayKit を呼ばない internal なメソッドに切り出し、隔離の解除と維持をイベント列で検証できるようにする

## 変更対象

- `Sora/ScreenCapture.swift`: `ScreenCaptureRecorderCoordinator` の owner 放棄と隔離解除の扱い、`ScreenCaptureController` の解放時の通知、隔離中の停止再試行経路、`ScreenCaptureRecorderCoordinator` の class doc
- `Sora/MediaChannel.swift`: `startScreenCapture` / `stopScreenCapture` / `isScreenCaptureActive` の doc コメント (owner を失った隔離の回復経路と、解除経路でホストの録画を停止し得る制約)
- `skills/sora-ios-sdk/SKILL.md`: 画面キャプチャ節の停止失敗時の記述と、解除経路でホストの録画を停止し得る制約
- `CHANGES.md`: `## develop` の画面キャプチャの `[FIX]` エントリを最終差分に合わせて更新する
- `SoraTests/`: owner の controller 解放後に別 owner が停止を再試行して隔離を解除できることを検証するイベント列テスト

## 完了条件

- 停止失敗で隔離された recorder の owner controller が解放された後でも、別の接続が停止を再試行し、停止確認後に画面キャプチャを開始できる
- 停止を確認できない録画を別接続が再利用しない (隔離は停止確認後だけ解除する)
- owner を失った隔離の解除は `finishStop` とは別の coordinator の API で行う。owner 一致が成立する停止成功時は現行どおり `finishStop` が `quarantined` を解除し、owner 一致ガードと owner 保持中の通常停止経路が変わっていない
- `ScreenCaptureRecorderCoordinator` の class doc、`MediaChannel` の doc コメント、`skills/sora-ios-sdk/SKILL.md` に、owner を失った隔離の回復経路が書かれている。あわせて、解除経路では「開始要求の時点でホストアプリが既に開始していた録画は停止しません。」という既存の記述が成立せず、ホストの録画を停止し得ることが書かれている
- `CHANGES.md` の `## develop` の画面キャプチャの `[FIX]` が、本修正後の挙動と一致している
- 上記の状態遷移を検証するテストが追加されている。モックやスタブは使用しない
- `make build` / `make fmt-lint` / `make lint` / 既存テストが成功する

## 関連 issue

- `0137`: start 失敗時に recorder を停止できるようにした。本 issue はその停止失敗時の隔離が controller 解放後に回復できない問題を扱う
- `0010`: `ScreenCaptureRecorderCoordinator` の隔離機構を導入した
- `0126`: 切断時の後始末のセマンティクス

## 解決方法
