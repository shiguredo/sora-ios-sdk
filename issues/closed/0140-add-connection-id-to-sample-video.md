# sora-ios-sdk-samples のリモート映像に connection id を表示する

- Created: 2026-09-10
- Completed: 2026-09-24
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

closed にする（2026-09-24）。検証用途の機能を sora-ios-sdk-samples に追加しない方針（`issues/0054-add-devtools.md`）により、本 issue の対応は不要と判断した。

### 根拠

1. `issues/0054-add-devtools.md`（open、Polished: 2026-09-23）は、背景で「`sora-ios-sdk-samples` に検証用の機能を足し続けるのは望ましくない。samples は機能を軽く試したり実装の参考にするためのサンプルであり、検証のためにあるものではない」、実装方針で「SDK 本体には検証用途のコードを入れない。samples にも検証機能を足さない」、完了条件で「sora-ios-sdk-samples に新規の検証機能が追加されていないこと」を明記している。本 issue の目的「`connection.created` 通知と受信ストリーム/トラックの紐付けが正しく行われているかを目視で確認できるようにする」はまさに検証用途であり、samples への実装はこの方針と相反する。
2. 0054 は「接続情報を表示できるようにする - connection_id」を DevTools の提供候補機能に含めており、本 issue が実現しようとする機能（リモート映像と connection id の対応表示）は DevTools（0054）側で扱う内容に相当する。0054 の完了条件「sora-ios-sdk-samples に新規の検証機能が追加されていないこと」を、samples への実装では満たせない。
3. `issues/0167-remove-simplify-samples.md`（open、2026-09-23）は、検証用途機能の移設を 0054 で扱い、samples をビデオチャットアプリ 1 種類（VideoChatSample）に集約すると明記している。本 issue の設計方針が言及する「RPC / Spotlight / Simulcast のリモート映像」は削除対象であり、将来的に対応対象が存在しない。
4. 補足: 本 issue の前提「Sora のリモートストリームでは streamId がリモート接続の connection id（`connection_id`）と一致する」は、`issues/0014-add-mediastream-connection-id.md`（open）の結論「Sora サーバーが受信側ストリームの msid として `connectionId` を設定するかどうかはサーバー実装に依存するため、`streamId` を `connectionId` のエイリアスとして扱うことはできない」および `issues/closed/0013-investigate-local-stream-id-connection-id.md` と矛盾し、本 issue 内に根拠が示されていない。なお、sora-js-sdk の `src/publisher.ts` の `multiStream` は `stream.id` をリモート接続 id として扱っており（`stream.id == connectionId` を除外し `remoteConnectionIds` に追加）、現行 Sora では成立し得るが、本 issue 側にその根拠となる記述は無い。
