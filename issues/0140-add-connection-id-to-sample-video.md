# sora-ios-sdk-samples のリモート映像に connection id を表示する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/add-connection-id-to-sample-video
- Polished: {YYYY-MM-DD}

## 目的

`sora-ios-sdk-samples` の SamplesApp のリモート映像に、受信元の Sora の connection id を表示する。`connection.created` 通知と受信ストリーム/トラックの紐付けが正しく行われているかを目視で確認できるようにする。

## 現状

- `VideoChatRoomViewController.handleUpdateStreams` は `MediaChannel.receiverStreams` を列挙し、各 `MediaStream` に `videoRenderer` を設定してリモート映像を表示している。connection id は表示していない。
- `MediaStream` は受信 video track を内包し、`streamId` を持つ。Sora のリモートストリームでは `streamId` がリモート接続の connection id (`connection_id`) と一致する。
- リモート映像を表示する `VideoView` に connection id を重ねる仕組みが無く、映像と connection id の対応を UI 上で確認できない。

## 設計方針

- リモート映像の `VideoView` に connection id のラベルを重ねて表示する。
- connection id は `MediaStream.streamId` から取得する。リモート映像 1 つにつき 1 つの connection id を対応付ける。
- iOS SDK は track 単位の公開 API を持たないため、リモート映像は `MediaStream` 単位で扱う。
- 対象は `VideoChat` のリモート映像とする。RPC / Spotlight / Simulcast のリモート映像も同じ経路で対応できる場合は合わせて対応する。

## テスト方針

- 実機で sendrecv 接続し、リモート映像に connection id が表示されることを確認する。
- マルチストリームで複数のリモート映像を受信したとき、各映像に正しい connection id が表示されることを確認する。

## 完了条件

- `VideoChat` のリモート映像に connection id が表示されること。
- 複数のリモート映像を受信したときに、各映像へ正しい connection id が表示されること。
- 既存の映像表示、レイアウト、映像の追加と削除の挙動が変わらないこと。
- `sora-ios-sdk-samples/CHANGES.md` に変更を記載すること。

## 変更対象ファイル

- `sora-ios-sdk-samples/SamplesApp/SamplesApp/Features/VideoChat/VideoChatRoomViewController.swift`
- `sora-ios-sdk-samples/SamplesApp/SamplesApp/Shared/` 配下 (複数機能で共通化する場合)

## 解決方法
