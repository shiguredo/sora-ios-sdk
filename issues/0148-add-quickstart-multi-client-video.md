# クイックスタートで複数クライアントから受信した映像を描画できるようにする

- Created: 2026-09-11
- Completed:
- Branch: feature/add-quickstart-multi-client-video
- Polished: 2026-11-13

## 目的

クイックスタートは単一の `ViewController` で構成された SDK の利用例だが、受信映像を表示する `VideoView` が 1 つしかなく、複数クライアントから受信した映像を同時に確認できない。クイックスタートで複数クライアントの映像を同時に描画できるようにし、最小構成で SDK の複数クライアント間の映像送受信を確認できるようにする。

sora-ios-sdk-samples の VideoChatSample は複数クライアントの映像を並べて表示できるが、接続設定 UI と多数の機能を持つアプリである。quickstart は単一の `ViewController` で構成された最小構成の利用例であり、複数クライアントの受信映像を同時に表示できるようにする。

## 前提

- 変更するのは sora-ios-sdk-quickstart リポジトリで、sora-ios-sdk 本体と sora-ios-sdk-samples は変更しない。`Branch:` は sora-ios-sdk-quickstart に切るブランチ名である
- sora-ios-sdk-quickstart は `develop` ブランチを持たない。実装時の base は、その時点の開発ブランチ (`feature/2026.5` など) とする
- quickstart は 0125 で受信ストリームの処理を `MediaChannel.subscribeEvents(bufferingPolicy:)` に移行済みである。`MediaChannelHandlers.onAddStream` は使っておらず、本 issue でも購読 API を使う
- quickstart の SDK 依存は 2026.5.0 (`SoraQuickStart.xcodeproj/project.pbxproj` の `exactVersion` と `Package.resolved`)。0160 の実施後は `project.xcproj` で同じ設定を確認する。SDK のバージョン更新は本 issue の対象外とする
- 受信映像は `SoraQuickStart/Base.lproj/Main.storyboard` の `receiverVideoView` に表示し、送信映像は同じ storyboard の `senderVideoView` に重ねて表示している
- 0122 (legacy `VideoRenderer` API の削除) が先行した場合は `MediaStream.videoRenderer` の利用方法が変わる。0122 は次期 major version の作業で、現時点では未着手である。0122 が先行する場合は、実装時に 0122 の新しい renderer API に合わせる
- 0160 (Xcode プロジェクト設定ファイル形式の更新) が先行した場合は project 設定ファイルの形式が変わる。本 issue は既存ファイルだけを変更し、新しいソースファイルを追加しない

## 変更対象

sora-ios-sdk-quickstart の次のファイル。

- `SoraQuickStart/ViewController.swift` (受信ストリームごとの `VideoView` の生成・破棄と `videoRenderer` の設定)
- `SoraQuickStart/Base.lproj/Main.storyboard` (受信映像用の `VideoView` を `UIStackView` を持つコンテナへ置き換える)
- `CHANGES.md` (ユーザーに見える変更の追記)

新しいソースファイルは追加しない。`SoraQuickStart.xcodeproj/project.pbxproj` (0160 の実施後は `project.xcproj`) は変更しない。

## 現状

`sora-ios-sdk-quickstart` の `SoraQuickStart/ViewController.swift` は、`Sora.shared.subscribeEvents(bufferingPolicy:)` で接続イベントを、`MediaChannel.subscribeEvents(bufferingPolicy:)` でストリームイベントを購読している。受信ストリームの追加は `.streamAdded` を `handleStreamAdded(_:streamId:)` で受け、`MediaChannel.streams` から `streamId` で `MediaStream` を解決し、`attachReceiverVideoView(to:)` で `receiverVideoView` を `videoRenderer` に設定している。接続完了時にも `attachVideoRenderers(_:)` が `receiverStreams` を走査して同じ設定を行う。

受信用の `VideoView` は `Main.storyboard` の `receiverVideoView` の 1 つだけで、`senderVideoView` は送信映像用である。複数の受信ストリームがあると、同じ `receiverVideoView` がすべてのストリームの `videoRenderer` に設定される。`MediaStream.videoRenderer` はストリームごとに独立しているため、各ストリームのフレームが同じ `VideoView` に到着順で描画され、複数の映像を同時に並べて確認することはできない。

`.streamRemoved` は `handleStreamRemoved(_:streamId:)` で受け、表示中のストリームが削除されたときだけ `displayedReceiverStream` を残りの受信ストリームへ付け替える。受信ストリームが 1 つのときは `receiverVideoView` が受信映像の表示領域全体を占め、送信映像が右下の 120x180 の領域に重なる。

## 設計方針

- 受信映像を表示する領域を、受信ストリームごとの `VideoView` を縦に並べる `UIStackView` に置き換える。`Main.storyboard` の `receiverVideoView` は `UIView` のコンテナに変更し、その中に `UIStackView` を配置する。`ViewController.receiverVideoView` の outlet の型は `UIView` に変更する
- `UIStackView` は `axis = .vertical`、`distribution = .fillEqually`、`spacing = 4` とし、コンテナの四辺に制約する。コンテナの背景は黒にし、各 `VideoView` の `contentMode` は `.scaleAspectFit` とする。`UIStackView` は `ViewController` から参照できるように outlet またはプロパティで保持する
- `ViewController` は `streamId` をキーに `[String: VideoView]` を保持する。受信ストリームを登録する処理を 1 つにまとめ、`.streamAdded` と接続完了時の `attachVideoRenderers(_:)` の両方から呼ぶ。登録時は、まだ辞書にない `streamId` のときだけ `VideoView` を生成して `UIStackView` に追加し、`MediaStream.videoRenderer` に設定する
- `attachVideoRenderers(_:)` の送信ストリームの設定は残し、受信ストリームのループだけを新しい登録処理に置き換える。受信ストリームの判定には `MediaChannel.receiverStreams` を使い、送信ストリームを表示対象にしない
- `.streamRemoved` では、該当する `streamId` の `VideoView` を `UIStackView` から取り除き、辞書から削除する。`displayedReceiverStream` と「残っている受信ストリームへ描き替える」処理は不要になるため削除する
- `.disconnected`、接続失敗、接続タイムアウト、切断タイムアウトでは、辞書のすべての `VideoView` を `UIStackView` から取り除いて辞書を空にする。送信映像 (`senderVideoView`) の設定、重なり位置、接続・切断の状態機械は変更しない
- 受信映像が 1 つのときは、`UIStackView` の 1 つの `VideoView` が受信映像の表示領域全体を占める。2 つ以上のときは領域を縦に等分して並べる。受信ストリームがないときは受信映像の表示領域を黒画面のままにする
- `MediaChannelHandlers.onAddStream` は使わず、現在の購読 API の経路を維持する

## 確認方法

- sora-ios-sdk-quickstart を実機にインストールし、同じチャネル ID に `sendrecv` で接続する。quickstart 側で受信ストリームを 2 本以上にするため、quickstart とは別に 2 クライアント以上を同じチャネルへ接続する (sora-ios-sdk-samples の VideoChatSample や Sora JavaScript SDK を使う)
- quickstart 側で、2 クライアント以上の受信映像が受信映像の表示領域に並んで表示されることを確認する
- 1 クライアントを切断し、そのクライアントの映像だけが消えて、残りの映像が表示され続けることを確認する
- 受信ストリームが 1 本になるまで切断し、受信映像が現行と同じ位置・大きさで表示されることを確認する
- quickstart 以外のクライアントをすべて切断し、quickstart は接続したまま、受信映像の表示領域が黒画面に戻ることを確認する
- quickstart の接続ボタンで quickstart 自身を切断し、受信映像の表示領域が黒画面に戻ることと、再度接続できることを確認する
- 接続失敗は接続できない URL や存在しないチャネル ID、接続タイムアウトは到達できない URL を設定して発生させ、受信映像の `VideoView` が残らないことを確認する。実機で再現できない場合は `ViewController` の該当経路をコードレビューで確認する
- 切断タイムアウトは通常の操作では発生しないため、`ViewController` の該当経路をコードレビューで確認する
- 端末を縦向きと横向きに回転し、映像が表示領域からはみ出さずに並ぶことを確認する
- `xcodebuild` の Release ビルドと `make fmt-lint` を実行し、CI と同じ条件で成功することを確認する
- 変更を push した後に CI (`.github/workflows/build.yml`) が成功することを確認する

## 完了条件

- 受信ストリームが 2 つ以上あるとき、それぞれの映像が別々の `VideoView` に同時に表示されること
- 受信ストリームが追加されると表示が増え、削除されると該当する映像だけが消えること
- 受信ストリームが 1 つのとき、現行と同じ位置・大きさ (受信映像の表示領域全体) で表示されること
- 受信ストリームがないとき、受信映像の表示領域が黒画面であること
- 切断、接続失敗、接続タイムアウト、切断タイムアウトの後に、受信映像の `VideoView` と辞書の対応が残らないこと
- 送信映像 (`senderVideoView`) の表示と、接続・切断の操作が現行どおり動作すること
- 「確認方法」を実施し、結果を `## 解決方法` に記載すること
- `xcodebuild` による Release ビルドが成功し、`make fmt-lint` が成功すること
- CI (`.github/workflows/build.yml`) が成功すること
- `CHANGES.md` に変更を記載すること

## スコープ外

- sora-ios-sdk 本体と sora-ios-sdk-samples の変更
- SDK 依存のバージョン更新
- 受信映像の全画面表示、ピンチズーム、タップによる切り替え、通話ごとの音声の出し分け、ミュート操作などの追加 UI
- 受信映像の 2 列グリッド、スクロール、最大表示数の制限などの高度なレイアウト。本 issue は縦 1 列の等分割だけを対象とする
- 0122 の legacy `VideoRenderer` API 削除自体 (0122 側で扱う)
- 0160 の Xcode プロジェクト設定ファイル形式の更新 (0160 側で扱う)

## 参考

- `sora-ios-sdk-samples` の `SamplesApp/SamplesApp/Features/VideoChat/VideoChatRoomViewController.swift` の `downstreamVideoViews` と `layoutVideoViews(for:)` (受信ストリーム数に応じた `VideoView` の生成・配置・削除の実装例)
- `skills/sora-ios-sdk/SKILL.md` の「イベントの購読」と「描画」
- `issues/closed/0125-update-quickstart-swift6-native-support.md` (購読 API への移行)

## 解決方法
