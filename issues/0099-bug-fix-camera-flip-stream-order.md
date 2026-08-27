# CameraVideoCapturer.flip が旧 stream へフレームを送る問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-camera-flip-stream-order
- Polished: 2026-08-28

## 目的

`CameraVideoCapturer.flip` で切り替え先のカメラを開始してから新しい stream を設定しているため、開始直後の frame が破棄される、または切り替え先 capturer に残っていた旧 stream へ送られる問題を修正する。

カメラ開始前に送信先 stream を確定し、flip transaction の途中で古い stream へ frame が配送されないことを保証する。

## 現状

`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturer.flip(_:completionHandler:)` は、現在の capturer を停止した後、次の順で処理する。

1. 切り替え先 capturer の `start(format:frameRate:completionHandler:)` を呼ぶ。
2. start completion が成功した後に、`flip.stream = capturer.stream` を設定する。
3. 利用者 completion を呼ぶ。

`RTCCameraVideoCapturer` は start completion より前から frame callback を発生させる可能性がある。切り替え先の `front` / `back` は静的に再利用される `CameraVideoCapturer` なので、stream 設定までの frame は次のどちらかになる。

- `flip.stream == nil` の場合は破棄される。
- 前回利用時の `flip.stream` が残っている場合は、古い stream へ送られる。

open の `0051` は flip を繰り返したときの目標解像度を保持する問題を扱っている。本 issue は frame の送信先と start 順序だけを対象とする。

## 再現手順

1. 実カメラと実 `MediaStream` を使って映像送信を開始する。
2. front / back を複数回切り替え、各 capturer に異なる stream が設定された履歴を作る。
3. `CameraVideoCapturer.flip` を呼び、切り替え開始直後から frame の送信先を記録する。
4. completion 前の frame が破棄される、または以前の stream へ送られることを確認する。

## 設計方針

- `0051` は flip の目標解像度維持（`targetResolution`）を扱う。本 issue は `0051` の後に実施し、本 issue の flip 再構成後も `0051` が追加する解像度維持挙動を維持する。
- 現在の capturer から引き継ぐ stream を、切り替え処理開始時に snapshot として取得する。
- 切り替え先 capturer の stream を start より前に設定する。
- start が失敗した場合は、操作 generation を照合したうえで切り替え先の stream を解除または元の値へ復元する。
- stop、stream 設定、start、失敗時 rollback を 1 つの transaction として扱う。直列化は現行の `SoraDispatcher` camera queue（libwebrtc の capture session queue）上で行い、`0103` が owner を導入した後に owner の command へ引き継ぐ（`SoraDispatcher` 自体の非推奨化は `0116`、削除は `0117` が扱う）。
- operation generation は `CameraVideoCapturer` に持たせるローカルカウンタとし、flip、stop、change の開始時に進める。各非同期 callback の復帰時に開始世代と現在世代を照合し、世代不一致の古い操作は state を上書きしない。generation の最終所有と hard mute（`0098`）との交差は、両操作が `SoraDispatcher` camera queue で直列化されたうえで、`0098` が導入する lease / generation の照合が適用される構造にして扱う。
- completion は transaction の状態を確定し、camera state の保護（lock または排他領域）を抜けた後に厳密に 1 回呼ぶ。
- 本 issue は stream の設定順と rollback に限定する。目標解像度の維持は `0051`、カメラ全体の Sendable / executor 設計は `0103` で扱う。

## テスト方針

モックやスタブは使用しない。

- front / back の実カメラと実 `MediaStream` を使い、flip の開始から完了までの全 frame の送信先を確認する。
- 過去に別 stream を設定した切り替え先 capturer を再利用し、旧 stream へ frame が送られないことを検証する。
- flip を連続実行し、古い completion が新しい stream または `isRunning` を上書きしないことを確認する。
- start 失敗時の rollback は、公開 `flip` 経路では `format(width:height:for:frameRate:)` と `maxFrameRate(_:for:)` が常に対応値を解決するため、実際に失敗する format / frame rate の組み合わせでは誘発できない。rollback ロジックを production の関数へ切り出し、stop / stream 設定 / start 失敗 / rollback のイベント列を入力して検証する。実機で start が過渡的に失敗する経路は手動確認とする。
- `0051` の目標解像度維持テストと組み合わせ、解像度修正と stream 順序修正が両立することを確認する。
- テストには、start より前に stream を設定する必要がある理由を日本語コメントで明記する。

## 完了条件

- 切り替え先 capturer の stream が start より前に設定されること。
- flip 開始後の frame が古い stream へ送られないこと。
- start 失敗時に stream が整合した状態へ rollback されること。
- 同時または連続した flip の古い completion が新しい camera state を上書きしないこと。
- completion が camera state の確定後に厳密に 1 回呼ばれること。
- `0051` の目標解像度維持方針と矛盾しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
