# CameraVideoCapturer.flip が旧 stream へフレームを送る問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-camera-flip-stream-order
- Polished:

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

- 現在の capturer から引き継ぐ stream を、切り替え処理開始時に snapshot として取得する。
- 切り替え先 capturer の stream を start より前に設定する。
- start が失敗した場合は、操作 generation を照合したうえで切り替え先の stream を解除または元の値へ復元する。
- stop、stream 設定、start、失敗時 rollback を 1 つの camera executor 上の transaction として扱う。
- 同時に複数の flip、stop、change、hard mute が開始された場合は generation を照合し、古い操作の completion が新しい状態を上書きしないようにする。
- completion は transaction の状態を確定した後に camera state の保護領域外で呼ぶ。
- 本 issue は stream の設定順と rollback に限定する。目標解像度の維持は `0051`、カメラ全体の Sendable / executor 設計は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- front / back の実カメラと実 `MediaStream` を使い、flip の開始から完了までの全 frame の送信先を確認する。
- 過去に別 stream を設定した切り替え先 capturer を再利用し、旧 stream へ frame が送られないことを検証する。
- flip を連続実行し、古い completion が新しい stream または `isRunning` を上書きしないことを確認する。
- start 失敗時に切り替え先の stream が不正な状態で残らないことを、実際に利用できない format / frame rate の組み合わせで確認する。
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
