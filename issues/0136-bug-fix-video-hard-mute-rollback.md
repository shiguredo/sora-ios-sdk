# setVideoHardMute(true) の失敗時に videoEnabled を復元する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-video-hard-mute-rollback
- Polished: 2026-09-10

## 目的

`MediaChannel.setVideoHardMute(true)` が失敗した場合に、呼び出し前に有効だった映像が黒塗り (ソフトミュート) 状態のまま残るのを防ぐ。

## 現状

- `MediaChannel.setVideoHardMute(true)` は `senderStream.videoEnabled = false` を設定した後に `VideoHardMuteActor.setMute(mute: true, ...)` を await する。
- `setMute` は別接続がカメラを所有している場合、操作が取り消された場合、同じ接続で別の操作が実行中の場合に throw する。
- throw した場合、`videoEnabled` を呼び出し前の値に戻す処理がないため、呼び出し前に有効だった映像が黒塗りのまま残る。利用者にはエラーだけが返る。
- `mute = false` の経路には `videoSourceCoordinator.cancelCamera` による予約取消のロールバックがあるが、`mute = true` の経路には `videoEnabled` の復元がない。
- 既存の `SoraTests/VideoHardMuteActorLeaseTests.swift` は `VideoHardMuteActor` を直接検証しており、`MediaChannel.setVideoHardMute` の `videoEnabled` 復元は対象外である。

## 設計方針

- `videoEnabled = false` の設定と復元を `VideoHardMuteActor` の直列化区間（所有権取得後）へ移す。これにより、同じ接続への同時呼び出しで「operation is in progress」により拒否された呼び出しが、進行中の成功操作の `videoEnabled` を上書きしない。
- 所有権を取得した後に `setMute` が throw した場合は、呼び出し前の `videoEnabled` を復元する。
- 復元対象は `videoEnabled` フラグに限定する。`VideoHardMuteActor` がカメラ停止後に取消を検知して throw した場合 (`Sora/VideoMute.swift` の `checkNotRevoked` 経路) は、フラグを復元してもカメラは停止したままである。この非対称状態の条件を `setVideoHardMute` の doc コメントに明記する。
- 公開 API の戻り値と成功時の挙動は変えない。

## 再現手順

- 接続済みの sender role、映像有効、`cameraSettings.isEnabled == true`、sender stream と video track が存在する状態で、テスト所有の `VideoHardMuteLease` を `MediaChannel` へ注入して接続する。
- `lease.revoke()` を呼んだ後に `setVideoHardMute(true)` を呼ぶと、`VideoHardMuteActor` の `operationTracker.begin` が取消により throw する。
- このとき `senderStream.videoEnabled` が呼び出し前の値に戻ることを確認する。

## 変更対象

- `Sora/MediaChannel.swift`: `setVideoHardMute` の `videoEnabled` の設定・復元
- `Sora/VideoMute.swift`: 必要に応じて所有権取得と `videoEnabled` の扱いを調整
- `SoraTests/`: lease revocation を注入するテスト

## 完了条件

- 所有権を取得した後に `setVideoHardMute(true)` が失敗した場合、`senderStream.videoEnabled` が呼び出し前の値に戻る。
- 同じ接続への同時呼び出しで「operation is in progress」により拒否された呼び出しが、進行中の成功操作の `videoEnabled` を上書きしない。
- `setVideoHardMute(true)` の成功時の挙動を変えない。
- カメラ停止後に取消を検知して throw した場合の非対称状態の条件が `setVideoHardMute` の doc コメントに書かれている。
- lease revocation を注入して失敗経路を検証するテストを追加すること。モックやスタブは使用しない。実カメラが必要な所有権競合の検証は実機または実カメラが利用可能な環境で行い、Simulator では実行できない項目を未検証として区別する。

## 関連 issue

- `0098`: `"camera is owned by another connection"` / `"video hard mute operation was cancelled"` の throw 経路を導入した。
- `0028`: 同じ `VideoHardMuteActor.setMute` の `mute = false` 成功経路を扱う。本 issue は `mute = true` 失敗経路であり、対象が分かれている。

## 解決方法
