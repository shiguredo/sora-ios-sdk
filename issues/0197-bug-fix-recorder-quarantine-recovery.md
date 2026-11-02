# 画面キャプチャの後始末に失敗した recorder が MediaChannel の解放後に回復できなくなる問題を修正する

- Created: 2026-10-30
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-recorder-quarantine-recovery
- Polished: {YYYY-MM-DD}

## 目的

画面キャプチャの停止に失敗すると、`ScreenCaptureRecorderCoordinator` は recorder の owner を保持したまま隔離状態になる。owner を保持する `MediaChannel` / `ScreenCaptureController` が解放されると、隔離を解除できる owner ID が失われ、プロセス再起動まで画面キャプチャを開始できなくなる。この回復不能状態を修正する。

## 現状

- `ScreenCaptureRecorderCoordinator.finishStop(ownerID:recorderStopped:)` は owner が一致する場合だけ隔離を解除し、停止に失敗した場合は owner を保持して `quarantined = true` にする (`Sora/ScreenCapture.swift`)
- `acquire(ownerID:)` は `ownerID == nil` かつ非隔離のときだけ成功するため、owner を保持したまま controller が解放されると、同じ recorder を以後取得できない
- `MediaChannel.deinit` は `prepareForDisconnect` 経由で `stopCaptureForDisconnect` を呼び、最後の停止を試みる。この停止も失敗した場合、`ScreenCaptureController` は解放され、`recorderOwnerID` の UUID を保持する主体がなくなる
- 別の `MediaChannel` から `stopScreenCapture()` を呼んでも、`currentScreenCaptureController()` が nil のため停止は実行されず、`beginScreenStop()` も owner entry がないため何もしない
- 結果として、1 回の停止失敗がプロセス全体の画面キャプチャを恒久的に使用不能にする

## 再現手順

- 画面キャプチャを開始し、停止を失敗させる
- その接続の `MediaChannel` を解放する (最後の停止試行も失敗させる)
- 別の接続を作成して `startScreenCapture` を呼ぶと、`acquire` が失敗し続ける
- 実 ReplayKit の停止失敗は自動テストで再現できないため、coordinator と controller のイベント列テストで確認する

## 設計方針

- 停止失敗時の隔離と owner 保持は、別接続がホストの録画を停止しないための現行の安全策であり維持する
- controller の解放時に `ScreenCaptureRecorderCoordinator` の owner を放棄する (`ownerID` を解放し、`quarantined` は維持する)。これにより隔離の解除に必要な owner ID が失われないようにする
- 別接続の `startCapture` は `quarantined` かつ `ownerID == nil` を検出したら、共有 recorder の停止を 1 回試みる。`isRecording == false` を確認できた場合だけ `quarantined = false` にして開始を続け、確認できない場合は隔離を維持して開始を失敗させる
- 停止の再試行は coordinator の直列 queue 上で行い、複数の接続が同時に再試行しないようにする
- `finishStop` の owner 一致ガードは維持し、owner 保持中の通常停止経路の意味を変えない

## 変更対象

- `Sora/ScreenCapture.swift`: `ScreenCaptureRecorderCoordinator` の owner 放棄と隔離解除の扱い、`ScreenCaptureController` の解放時の通知、隔離中の停止再試行経路
- `Sora/MediaChannel.swift`: 必要に応じて停止再試行経路
- `SoraTests/`: owner の controller 解放後に別 owner が停止を再試行して隔離を解除できることを検証するイベント列テスト

## 完了条件

- 停止失敗で隔離された recorder の owner controller が解放された後でも、別の接続が停止を再試行し、停止確認後に画面キャプチャを開始できる
- 停止を確認できない録画を別接続が再利用しない (隔離は停止確認後だけ解除する)
- 上記の状態遷移を検証するテストが追加されている。モックやスタブは使用しない
- `make build` / `make fmt-lint` / `make lint` / 既存テストが成功する

## 関連 issue

- `0137`: start 失敗時に recorder を停止できるようにした。本 issue はその停止失敗時の隔離が controller 解放後に回復できない問題を扱う
- `0010`: `ScreenCaptureRecorderCoordinator` の隔離機構を導入した
- `0126`: 切断時の後始末のセマンティクス

## 解決方法
