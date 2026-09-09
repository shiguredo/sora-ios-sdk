# setVideoHardMute(true) の失敗時に videoEnabled を復元する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-video-hard-mute-rollback
- Polished: {YYYY-MM-DD}

## 目的

`MediaChannel.setVideoHardMute(true)` が失敗した場合に、送信ストリームが黒塗り (ソフトミュート) 状態のまま固定されるのを防ぐ。

## 現状

- `MediaChannel.setVideoHardMute(true)` は `senderStream.videoEnabled = false` を設定した後に `VideoHardMuteActor.setMute(mute: true, ...)` を await する。
- `setMute` は別接続がカメラを所有している場合や操作が取り消された場合に throw する。
- throw した場合、`videoEnabled` を `false` に戻す処理がないため、映像が黒塗り状態のまま残る。利用者にはエラーだけが返る。
- `mute = false` の経路には `videoSourceCoordinator.cancelCamera` によるロールバックがあるが、`mute = true` の経路には同等の処理がない。

## 設計方針

- 呼び出し前の `videoEnabled` を退避し、`setMute` が throw した場合に復元する。
- 復元は `mute = true` の失敗経路だけを対象とし、成功時の挙動は変えない。
- 復元できない状態がある場合は、その条件をドキュメントに明記する。

## 完了条件

- `setVideoHardMute(true)` が失敗した場合、`senderStream.videoEnabled` が呼び出し前の値に戻る。
- `setVideoHardMute(true)` の成功時の挙動を変えない。
- 失敗経路を検証するテストを追加すること。モックやスタブは使用しない。実カメラが必要な検証は実機または実カメラが利用可能な環境で行い、Simulator では実行できない項目を未検証として区別する。

## 解決方法
