# ConnectionTask の即時キャンセルが接続開始を止めない競合を修正する

- Created: 2026-08-27
- Completed: 2026-08-27
- Branch: feature/fix-connection-task-cancel-race
- Polished: 2026-08-27

## 目的

`Sora.connect()` が返した `ConnectionTask` を直ちにキャンセルしても、バックグラウンドに投入済みの接続処理がそのまま開始される問題を修正する。

キャンセル要求を `PeerChannel` の設定前後にかかわらず保持し、キャンセル済みの接続が開始または完了扱いにならない状態遷移を保証する。

## 現状

`Sora/MediaChannel.swift` の `MediaChannel.connect(webRTCConfiguration:timeout:handler:)` は、`ConnectionTask` を生成した後、`basicConnect(connectionTask:webRTCConfiguration:timeout:handler:)` を `DispatchQueue.global()` へ投入してから呼び出し元へ戻る。

`ConnectionTask.peerChannel` は、バックグラウンド側の `basicConnect` が開始してから設定される。一方、`Sora/Sora.swift` の `ConnectionTask.cancel()` は、`peerChannel` が存在する場合にだけ `disconnect` を呼び、その後 `state` を `.canceled` にする。

```swift
// Sora/Sora.swift 現行実装
public final class ConnectionTask {
  public enum State {
    case connecting
    case completed   // 接続試行が終端した。成功・接続失敗・切断を区別しない
    case canceled
  }

  weak var peerChannel: PeerChannel?
  public private(set) var state: State

  public func cancel() {
    if state == .connecting {
      peerChannel?.disconnect(error: SoraError.connectionCancelled, reason: .user)
      state = .canceled
    }
  }

  func complete() {
    if state != .completed {
      state = .completed
    }
  }
}
```

このため、次の実行順が成立する。

1. `MediaChannel.connect` が `ConnectionTask` を返す。
2. `basicConnect` が `ConnectionTask.peerChannel` を設定する前に、利用者が `cancel()` を呼ぶ。
3. `peerChannel` が `nil` のため、切断処理は実行されない。
4. バックグラウンド側の `basicConnect` がキャンセル状態を確認せず、接続を開始する。
5. 後続の接続または切断 callback が `ConnectionTask.complete()` を呼び、`.canceled` を `.completed` に上書きする。

なお、現行実装では `complete()` が接続失敗・切断経路でも呼ばれるため、接続試行が失敗しても利用者は `state == .completed` を観測する(この意味論は本 issue では維持する。詳細は設計方針参照)。

`ConnectionTask.state` と `peerChannel` は利用者のスレッドとバックグラウンド処理から同期なしで読み書きされるため、状態確認自体にもデータ競合がある。

## 再現手順

1. 実際の `Sora` インスタンスから `connect()` を呼ぶ。
2. 戻り値の `ConnectionTask` に対して、別の待機処理を挟まず直ちに `cancel()` を呼ぶ。
3. 接続 callback、切断 callback、`ConnectionTask.state` の遷移を記録する。
4. 接続処理が継続する、または最終状態が `.completed` になることを確認する。

実行タイミングに依存するため、単発確認ではなく反復して検証する。

## 設計方針

- `ConnectionTask` の状態と `PeerChannel` への紐付けを、1 つの lock または接続専用 executor の下で管理する。
- 状態遷移を少なくとも `connecting`、`cancelRequested`、`completed`、`canceled` に分け、終端状態から別の終端状態へ遷移させない。
  - `completed` の意味は現行実装を維持し、「接続試行が終端した(成功・接続失敗・切断を区別しない)」とする。接続失敗時に別状態を新設する場合は、`ConnectionTask.State` が公開 API であるため API 変更として別 issue で扱う。
- `PeerChannel` の設定前にキャンセルされた場合はキャンセル要求を保持し、接続開始前なら `basicConnect` を開始しない。
- 接続開始後にキャンセルされた場合は、`PeerChannel` の設定と同じ排他単位でキャンセル要求を確認し、確実に `disconnect` を呼ぶ。
- `complete()` は接続試行の終端として `.completed` へ遷移させるが、`.canceled` から `.completed` へは上書きしない。
- キャンセル成立時の接続 callback 通知は、`Sora.connect()` の handler へ `SoraError.connectionCancelled` を渡し、厳密に 1 回だけ発火させる。キャンセル後は接続成功 callback を発火させない。
- 利用者 callback は lock の外で呼び出し、callback から `cancel()` や `disconnect()` が再入しても deadlock しないようにする。
- 本 issue では公開 `Sora.connect()` のシグネチャを変更しない。async 接続 API の追加は `issues/0058-add-async-await.md` のスコープとする。

## テスト方針

モックやスタブは使用しない。

- 実際の `ConnectionTask` と接続状態管理実装を使い、返却直後、`PeerChannel` 設定中、接続完了直前の各タイミングで cancel を競合させる。
- production code の状態遷移部分を値とイベントで検証できる場合は、実際の状態遷移実装へイベント列を直接入力し、すべての順序で終端状態が一意になることを検証する。
- 実 Sora への E2E で即時 cancel を反復し、接続成功 callback が発火しないこと、切断後に接続が残らないことを確認する。
- Thread Sanitizer を有効にした Simulator テストを補助的に実行する。
- テストには、なぜ各タイミングを競合させる必要があるかを日本語コメントで明記する。

## 完了条件

- `ConnectionTask.state` と `peerChannel` の読み書きが同じ排他機構で保護されていること。
- `connect()` の戻り値を直ちに cancel しても接続処理が開始されないこと。
- `PeerChannel` 設定と cancel が競合しても、接続が確実に停止すること。
- `.canceled` が `.completed` に上書きされないこと。
- キャンセル成立時に `SoraError.connectionCancelled` の接続失敗 callback が厳密に 1 回だけ発火し、接続成功 callback が発火しないこと。
- cancel、接続成功、接続失敗、切断 callback が競合しても終端処理が厳密に 1 回であること。
- callback から `cancel()` または `disconnect()` を呼んでも deadlock しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

### ConnectionTask の状態管理 (Sora/Sora.swift)

- `ConnectionTask` に `NSLock` (stateLock) を導入し、`state` と `peerChannel` の読み書きを排他する。
- 内部状態として `InternalState` (connecting / cancelRequested / completed / canceled) を持つ。公開 `State` は従来の 3 ケース (connecting / completed / canceled) のまま維持し、公開 enum のケース追加による利用者側の exhaustive switch の破壊を避ける。`cancelRequested` は外部からは `.canceled` として観測される。
- 状態遷移:
  - attach による紐付け (connecting の場合のみ成功、キャンセル要求済みなら false)
  - cancel による cancelRequested へ遷移
  - markCanceled による cancelRequested → canceled へ確定
  - complete による connecting → completed へ遷移 (cancelRequested / canceled / completed からは遷移しない)
- `cancel()` はロック下で状態遷移と peerChannel の取得を行い、`disconnect` はロック外で実行する (切断時の callback から complete / cancel が再入しても deadlock しないようにするため)。disconnect の有無にかかわらず markCanceled で確定させる。

### 接続開始前後のキャンセル確認 (Sora/MediaChannel.swift)

- `basicConnect` の開始時に `connectionTask.attach(peerChannel:)` で peerChannel の設定とキャンセル要求の確認を同一排他領域で行う。
- attach が false の場合 (キャンセル要求済み) は接続を開始せず、markCanceled + `internalDisconnect(connectionCancelled)` で終端する (通常の接続失敗と同じ後始末経路を通る)。
- attach 成功後、`peerChannel.connect` の直前に再接続前確認を行う。attach 成功後に cancel() が割り込んだ場合も、接続開始を防ぎ markCanceled + internalDisconnect で終端する。
- `peerChannel.connect` の完了ハンドラ冒頭で state を確認し、キャンセル済みなら接続成功通知 (handler(nil)) を発火せず終端する。

### テスト (SoraTests)

- `ConnectionTaskTests`: 状態遷移のユニットテスト 7 件 (公開 state の観測、cancel 要求保持と attach 拒否、complete の遷移、complete による上書き防止、completed 後の cancel、attach と cancel の競合終端)。
- `ConnectionTaskCancelE2ETests`: 実 Sora 接続での即時キャンセル反復テスト 2 件 (接続しないこと、canceled が保持されること)。シグナリング URL 未設定時はスキップする。
