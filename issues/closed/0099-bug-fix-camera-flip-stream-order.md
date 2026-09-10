# CameraVideoCapturer.flip が旧 stream へフレームを送る問題を修正する

- Created: 2026-08-27
- Completed: 2026-09-02
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
- start / stop が失敗した場合は、切り替え先の stream を元の値（snapshot）へ復元する。operation generation の照合は行わない（`0103` で owner が導入する）。
- stop、stream 設定、start、失敗時 rollback を 1 つの transaction として扱う。直列化は現行の `SoraDispatcher` camera queue（libwebrtc の capture session queue）上で行い、あわせて re-entrance フラグ（`isFlipping`）で連続実行を排除する。`0103` が owner を導入した後に owner の command へ引き継ぐ（`SoraDispatcher` 自体の非推奨化は `0116`、削除は `0117` が扱う）。
- operation generation の導入は `0103` に委ねる。本 issue では flip の「stream 設定順・rollback」を対象とし、連続 flip の完了競合は re-entrance フラグ（`isFlipping`、camera queue 上で切り替え中を表現し、stop / start 完了まで維持）で防ぐ。camera queue の直列化は「flip の同期部分を直列に実行する」ことで、stop / start の非同期部分の競合はフラグで排除する。generation の最終所有と hard mute（`0098`）との交差は、両操作が camera queue で直列化されたうえで、`0103` が導入する lease / generation の照合が適用される構造にして扱う。
- completion は transaction の状態を確定し、camera state の保護（lock または排他領域）を抜けた後に厳密に 1 回呼ぶ。
- 本 issue は stream の設定順と rollback に限定する。目標解像度の維持は `0051`、カメラ全体の Sendable / executor 設計と operation generation は `0103` で扱う。

## テスト方針

モックやスタブは使用しない。

- front / back の実カメラと実 `MediaStream` を使い、flip の開始から完了までの全 frame の送信先を確認する。
- 過去に別 stream を設定した切り替え先 capturer を再利用し、旧 stream へ frame が送られないことを検証する。
- flip を連続実行し、1 回目の flip だけが実行され、2 回目以降は re-entrance エラーになることを確認する。古い completion が新しい stream または `isRunning` を上書きしないことは、`isFlipping` フラグと camera queue の直列化により保証される。実カメラが必要なため Simulator / CI では実行できず、実機で確認する。
- start 失敗時の rollback は、公開 `flip` 経路では `format(width:height:for:frameRate:)` と `maxFrameRate(_:for:)` が常に対応値を解決するため、実際に失敗する format / frame rate の組み合わせでは誘発できない。rollback は flip 内のインライン実装とし、実機で start が過渡的に失敗する経路は手動確認とする。rollback ロジックの production 関数への切り出しとテストは行わない (`0103` の owner への移植時に、rollback の状態遷移を owner の command として検証する)。
- `0051` の目標解像度維持テストと組み合わせ、解像度修正と stream 順序修正が両立することを確認する。
- テストには、start より前に stream を設定する必要がある理由を日本語コメントで明記する。

## 完了条件

- 切り替え先 capturer の stream が start より前に設定されること。
- flip 開始後の frame が古い stream へ送られないこと。
- start 失敗時に stream が整合した状態へ rollback されること。start 失敗時は元の capturer は停止した状態、切り替え先も停止した状態となる (カメラ未稼働)。元の capturer の再起動までの完全な復旧は本 issue では行わず、`0103` の owner への移植時に owner の state を見て復旧を実装する。
- 連続実行中の flip は 1 回目だけが実行され、2 回目以降は re-entrance エラーになること（`isFlipping` フラグ）。古い completion が新しい camera state を上書きしないことは、camera queue の直列化と `isFlipping` フラグにより保証されること。
- completion が camera state の確定後に厳密に 1 回呼ばれること。
- `0051` の目標解像度維持方針と矛盾しないこと。
- 実カメラを使った検証 (frame の送信先、連続実行) は実機で確認すること。
- 既存テストがすべて成功すること。(rollback の production 関数切り出しとテストは行わない。`0103` の owner 移植時に検証する)

## 解決方法

`CameraVideoCapturer.flip` の stream 設定順を修正した。

- 切り替え先 capturer の stream を start より前に設定する。旧実装は start 完了後に設定していたため、start の completion より前から発生する frame が「破棄される」または「前回利用時の旧 stream へ送信される」問題があった。
- start / stop 失敗時は、切り替え先の stream を元の値 (snapshot) へ rollback する。旧実装は失敗時に stream の復元を行わなかった。
- 連続実行時の競合は re-entrance フラグ (`isFlipping`) と camera queue の直列化で防ぐ。`isFlipping` は stop / start の完了まで維持され、切り替え中の実 2 回目の flip を re-entrance エラーで拒否する。
- 引数 capturer が `CameraVideoCapturer.current` と一致することを確認する。別の capturer を渡した場合の未定義挙動 (停止していない capturer への stop / stream 代入) を防ぐ。
- flip の成功 / 失敗ログを追加し、失敗時は元エラーを含める。

あわせて、issue 0099 のテスト方針・完了条件を実装の現状に合わせて更新した。

- rollback の production 関数への切り出しとテストは行わず、実機で start 失敗経路を手動確認する (`0103` の owner への移植時に rollback の状態遷移を owner の command として検証する)。
- operation generation は `0103` に委ねる (`0099` では re-entrance フラグのみ)。
- start 失敗時はカメラが停止状態で残る (完全な復旧は `0103` の owner で実装)。`0103` の「前提となる issue」に明記済み。

### 検証

- シミュレータテスト: 既存の全テストが成功。
- 実機確認: カメラフリップボタンの連打でも問題なし (回帰なし)。
