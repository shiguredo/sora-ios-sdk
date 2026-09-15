# PeerChannel.onConnect が排他制御されておらずデータ競合が発生する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-peer-channel-on-connect-data-race
- Polished:

## 目的

`PeerChannel.onConnect` が排他制御なしで複数スレッドから読み書きされており、接続 callback の 1 回保証が壊れ得る。Thread Sanitizer が実際にデータ競合を検出したため、読み書きを単一の排他で保護する。

## 優先度根拠

- 影響: (a) ARC 競合 (Swift の closure は関数ポインタとコンテキストの 2 ワード) によるクラッシュ、(b) 接続 callback の二重呼び出し / 消失、(c) `state` の誤判定 (busy 判定、猶予タイマーのキャンセル判断)
- 発生確率は低い (数命令の窓で、特定の並行パターンが必要) が、Thread Sanitizer は通常のユニットテストで検出した
- CI に Thread Sanitizer がないため、通常のテストや E2E では検出できない
- 修正規模は小さく、公開 callback の保証に直結するため Medium とする (`0001` の PeerChannel.Lock のデータレースは確定的に壊れるため High だった)

## 現状

`PeerChannel.onConnect` は無保護の stored property である。

- 書き: `PeerChannel.connect` の `onConnect = handler`
- 書き: `PeerChannel.invokeConnectHandler` の take-and-clear (`let connectHandler = onConnect` の後に `onConnect = nil`)
- 読み: `PeerChannel.state` の `onConnect != nil`
- 読み: `PeerChannel.Lock.waitDisconnect` の `context?.onConnect != nil` (`Lock.nsLock` を保持しているが、書き側は `nsLock` を取らない)

`invokeConnectHandler` は `finishConnecting` / `sendConnectMessage(error:)` / `finishBasicDisconnect` から呼ばれる。`finishBasicDisconnect` は `basicDisconnect` が生成する camera cleanup の `Task` の継続から呼ばれるため、非同期 executor のスレッドで実行される。この `Task` は `003bb738` (ステレオ音声出力対応) で導入された。

`-enableThreadSanitizer YES` で `SoraTests/PeerChannelConnectCompletionTests` を実行したときの検出内容:

- 書き: `invokeConnectHandler` ← `finishBasicDisconnect` ← `basicDisconnect` の closure (GCD worker thread)
- 読み: `state` getter ← `PeerChannel.connect` (main thread)

`PeerChannel.connect` は `MediaChannel.basicConnect` から `DispatchQueue.global()` 上で呼ばれる。connect の直後に `MediaChannel.disconnect()` された場合 (onAddMediaChannel からの切断など) は camera cleanup の `Task` の書きと並行し得る。

## 設計方針

- `onConnect` の読み書きを 1 つの排他で保護し、take-and-clear をアトミックにして接続 callback の 1 回保証を構造的に成立させる。
- `state` が `onConnect` を読む経路に注意する。`state` は `Lock.shouldCancelDisconnectTimerBasedDisconnect` から `Lock.nsLock` 保持中に呼ばれるため、`Lock.nsLock` で `onConnect` を保護したうえで `state` がそれを取る形にすると非再帰ロックでデッドロックする。次のいずれかを選ぶ。
  - `onConnect` 専用の lock を設け、`Lock.nsLock` と入れ子にしない
  - 接続試行中の判定を `onConnect != nil` ではなく `0100` の `ConnectionStateOwner` が持つ接続状態から導き、`state` から `onConnect` の読み出しをなくす
  - `0100` の snapshot storage と同じく lock 保護の snapshot 方式に寄せる

## 完了条件

- `onConnect` の読み書きがすべて同一の排他で保護されていること
- `-enableThreadSanitizer YES` で `SoraTests/PeerChannelConnectCompletionTests` を実行してもデータ競合が報告されないこと
- 接続 callback の 1 回保証を検証する既存テスト (`PeerChannelConnectCompletionTests` / `PeerChannelConnectCompletionE2ETests`) が成功すること
- 既存テストがすべて成功すること

## テスト方針

- 通常のテストでは検出できないため、Thread Sanitizer を併用して回帰を確認する。
- 実 Sora / 実 WebRTC を使う既存 E2E で回帰しないことを確認する。モックやスタブは使用しない。

## スコープ外

- `PeerChannel.Lock` の統合 (`0129`) は refactor であり本 issue では扱わない。本 issue はデータ競合の修正に限定する。
- `MediaChannel` の接続ライフサイクル (`0010`) は変更しない。

## 解決方法
