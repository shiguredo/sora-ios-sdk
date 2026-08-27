# redirect 中に旧 DataChannel と RPC を利用できる問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-redirect-stale-transport
- Polished:

## 目的

シグナリングの redirect を受理して旧 PeerConnection を閉じた後も、公開 API から旧 DataChannel と RPC を利用できる時間窓をなくす。

redirect の開始と同時に旧 transport を論理的に無効化し、旧接続の frame、stats、DataChannel callback、RPC 結果を新しい接続へ持ち込まないことを保証する。

## 現状

`Sora/PeerChannel.swift` の redirect 処理は、`dataChannelGeneration` を進め、`isRedirecting` を設定してから旧 `nativeChannel` を閉じる。

この世代番号は DataChannel delegate や一部の PeerConnection callback で旧通知を無視するために使われている。一方、redirect を受理した時点では次の状態が残る。

- `switchedToDataChannel == true`
- 旧 DataChannel を保持する `dataChannels`
- 旧 DataChannel に紐付く `rpcChannel`
- 旧 PeerConnection へ要求済みの stats callback
- 旧 offer から構築された DataChannel の定義と通知状態

`Sora/MediaChannel.swift` の `sendMessage(label:data:)` は `switchedToDataChannel` と `dataChannels` を参照するため、redirect 中にも旧 DataChannel へ送信できる。

RPC も `rpcChannel` が invalidate されるまで旧 DataChannel を利用できる。旧 PeerConnection の stats callback が遅れて完了すると、現在の `SignalingChannel` を使って旧接続の統計を新セッションへ送信する可能性がある。

closed の `0090` では、旧 PeerConnection callback を世代と identity で拒否する処理が追加されている。本 issue は、その後も残っている公開送信経路と transport 所有状態の無効化を対象とする。

## 再現手順

1. DataChannel signaling と RPC が利用可能な実接続を開始する。
2. redirect が開始される構成で、redirect の受理と同時に `sendMessage`、RPC、stats 取得を反復する。
3. 新しい接続が確立するまでの間に、旧 DataChannel の `send` が呼ばれるか記録する。
4. redirect 前に開始した RPC と stats が、新接続の transport から送信または通知されないか確認する。

## 設計方針

- 1 回の `Sora.connect()` を表す論理接続 ID と、redirect ごとに変わる transport epoch を分離する。
- redirect を受理した同じ排他領域で、旧 transport の論理的な無効化と epoch 更新を不可分に実行する。
- 無効化では少なくとも次を行う。
  - `switchedToDataChannel` を false にする。
  - 旧 DataChannel の delegate を切り離す。
  - `dataChannels` を take-and-clear する。
  - `rpcChannel` を invalidate してから nil にする。
  - DataChannel の通知追跡状態と旧 offer 情報を破棄する。
- DataChannel 送信、RPC、stats callback は、処理開始時に取得した transport epoch と identity を送信直前にも照合する。
- 旧 transport の cleanup と利用者 callback は分離し、内部 lock を保持したまま callback を呼ばない。
- 本 issue は既存 redirect 処理のバグ修正に限定する。接続状態全体を actor または serial executor へ移す作業は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- redirect が発生する実 Sora 環境で DataChannel 送信、RPC、stats を継続し、旧 transport へ送信されないことを確認する。
- production code の transport epoch 管理へ redirect、送信、callback のイベント列を入力し、epoch 不一致の操作が必ず拒否されることを検証する。
- redirect 前に開始した RPC が、成功または redirect に対応するエラーのどちらかで厳密に 1 回終端することを確認する。
- redirect 前の stats callback が新しい signaling transport へ送信されないことを確認する。
- 既存の redirect、reconnect、DataChannel E2E テストを継続して実行する。
- テストには、論理接続 ID と transport epoch を分ける理由を日本語コメントで明記する。

## 完了条件

- redirect 受理と旧 transport の論理的無効化が同じ排他領域で行われること。
- redirect 中の `sendMessage` が旧 DataChannel へ送信しないこと。
- 旧 `rpcChannel` が redirect 時に invalidate され、すべての pending が終端すること。
- 旧 PeerConnection の stats、DataChannel callback、frame が新しい接続へ持ち込まれないこと。
- 論理接続 ID と transport epoch が別の状態として管理されていること。
- redirect 後の新しい DataChannel と RPC が正常に利用できること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
