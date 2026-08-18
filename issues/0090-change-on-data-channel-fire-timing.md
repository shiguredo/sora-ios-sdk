# onDataChannel の発火タイミングをクライアント側の DataChannel 準備完了時に修正する

- Priority: Medium
- Created: 2026-08-14
- Completed:
- Model: deepseek-v4-flash
- Branch: feature/change-on-data-channel-fire-timing
- Polished: 2026-08-17

## 目的

コールバック `MediaChannelHandlers.onDataChannel` を「クライアント側の DataChannel 準備が完了したタイミング」の通知として定義し直し、発火タイミングをクライアント側で DataChannel が OPEN になったタイミングに修正する。API シグネチャは変更しない。

現状は Sora サーバから `type: switched` を受信したタイミングで発火しているが、これはサーバ側のシグナリング切替完了の通知であり、クライアント側でメッセージング用 DataChannel が送受信可能になったタイミングとは厳密には一致しない。ユーザーが「DataChannel が利用可能になった」と判断する根拠として正確でない。

sora-android-sdk の issue 0051 で同様の修正が完了済みであり、本 issue は iOS SDK に同様の修正を適用する。

## 優先度根拠

- 発火タイミングをクライアント側の準備完了に合わせることで、コールバックの意味論が明確になり、ユーザーが DataChannel を安全に利用できるようになる
- API シグネチャは不変で後方互換があるが、発火タイミングの変更でユーザーの挙動が変わる可能性がある。緊急のバグではないため Medium とする

## 現状

`onDataChannel` はシグナリング `type: switched` を受信したタイミングで発火している。

```swift
// PeerChannel.swift handleSignalingOverWebSocket の .switched ケース
case .switched(let switched):
  switchedToDataChannel = true
  signalingChannel.ignoreDisconnectWebSocket = switched.ignoreDisconnectWebSocket ?? false

  if let mediaChannel, let onDataChannel = mediaChannel.handlers.onDataChannel {
    onDataChannel(mediaChannel)
  }
```

個々の DataChannel がクライアント側で OPEN になったことは `BasicDataChannelDelegate.dataChannelDidChangeState` で検知できるが、現状では CLOSED のみを処理しており、OPEN 遷移の検知も `onDataChannel` の発火も行っていない。

```swift
// DataChannel.swift dataChannelDidChangeState
if dataChannel.readyState == .closed {
  ...
}
```

つまり、`type: switched` を受信した時点で `onDataChannel` が発火しており、個々の DataChannel がクライアント側で OPEN になったタイミングとは一致していない。

## 他 SDK との比較

| SDK | 発火タイミング | 備考 |
|---|---|---|
| Android（修正済み） | メッセージング用ラベルがすべて OPEN になった時 | クライアント側で DataChannel の state を監視。`onDataChannelOpened` は全ラベル対象（C++ 踏襲） |
| iOS（現状） | `switched` 受信時 | サーバ仕様に依存 |
| JS | `switched` 受信時に全 datachannels 分 | サーバ仕様に依存 |
| Rust | `on_data_channel` = 作成時、`on_data_channel_open` = OPEN 遷移時 | クライアント側で DataChannel の state を監視して検知 |
| C++ | 全ラベル個別に OPEN 遷移時 `OnDataChannel(label)` | offer の `data_channels` の全ラベル（`signaling` / `stats` / `notify` / `#` 始まりを含む）が対象。`#` フィルタはない |

ラベル個別の OPEN 通知コールバックは C++ SDK の `OnDataChannel` が全ラベル対象であるため、本 issue では C++ SDK に合わせて全ラベル対象とする。Rust SDK の `on_data_channel_open` は当初の参考実装であり、対象ラベル範囲が異なる（`#` 始まりのみ）点に注意する。

## 設計方針

API の後方互換を維持しつつ（`onDataChannel` のシグネチャは不変）、発火タイミングをクライアント側の DataChannel 準備完了に合わせる。さらに C++ SDK 踏襲として、ラベル個別の OPEN 通知コールバックを追加する。

### 1. 一括通知（`onDataChannel`）の発火タイミング修正

- OPEN 検知の経路は `BasicDataChannelDelegate.dataChannelDidChangeState` の `RTCDataChannelState.open` 遷移を正とする。`RTCPeerConnectionDelegate.peerConnection(_:didOpen:)` は DataChannel オブジェクトの生成通知であり OPEN 遷移の通知ではないため、OPEN 遷移の検知の正としない（登録時点で既に OPEN の場合の防御的チェックは別途 `peerConnection(_:didOpen:)` 内で行う）
- `dataChannelDidChangeState` で `RTCDataChannelState.open` への遷移を検知する。現在は CLOSED のみを処理しているため、OPEN 遷移の検知を追加する
- 判定基準のラベル集合は offer の `data_channels`（`SignalingOffer.dataChannels`）から `MediaChannel.messagingLabels(from:)` で `#` 始まりのラベルを抽出したものとする
- 判定基準のラベル集合に含まれる DataChannel が**すべて** OPEN になったタイミングで `MediaChannelHandlers.onDataChannel` を発火する
- `type: switched` 受信時には `onDataChannel` を発火しない
- 既に OPEN 済みのメッセージング用ラベルがある場合は、その状態を保持し、最後の 1 つが OPEN になった時点で発火する
- 後方互換: API シグネチャは不変であり、発火タイミングのみの変更となる

### 2. ラベル個別の OPEN 通知コールバック追加（C++ 踏襲）

- `MediaChannelHandlers` に `onDataChannelOpened((MediaChannel, String) -> Void)?` を追加する。これは C++ SDK の `OnDataChannel`（OPEN 遷移時・ラベル個別・全ラベル対象・引数はラベル文字列）とタイミング・粒度を一致させる
- 発火条件: 受け取った各 DataChannel がクライアント側で OPEN へ遷移した時点で、そのラベルについて 1 回発火する。`#` 始まりのラベルに限定しない
- 当初は Rust SDK の `on_data_channel_open` に合わせて `#` ラベルのみ対象とする方針だったが、Android issue 0051 の実装で C++ / Python SDK が全ラベル対象であることが確認されたため、全ラベル対象に変更する
- 重複通知は OPEN 済みラベルの集合で防止する
- 既存の `onDataChannel`（一括通知）は維持し、後方互換を保つ

### 3. 実装上の注意点（Android issue 0051 の実装知見）

- libwebrtc の `RTCDataChannelDelegate` は登録時に現在の state を即時通知しない実装であるため、登録時点で既に OPEN の場合の防御的チェックを追加する
- リセットは `data_channels` の有無に関わらず offer 受信時に行う（`data_channels` なしの offer で前接続の追跡状態が残留すると、新接続の `onDataChannelOpened` / `onDataChannel` が抑止されるため）。切断時は MediaChannel が再利用不可のためリセットを必要としない
- メッセージング用ラベルが存在しない場合は一括通知（`onDataChannel`）を発火しない
- ラベル個別通知は受信基準（offer の `data_channels` との突合は行わない）を採用する。Sora サーバは offer に含めた DataChannel しか作成しないため実用上は一致するが、予期しないラベルが届いた場合もユーザーに通知される受信基準を採用する
- `MediaChannel.sendMessage` は `type: switched` 受信時に true になる `switchedToDataChannel` をゲートにしている。メッセージング用ラベルの OPEN は `switched` 受信より先に成立し得るため、`onDataChannel` 発火直後に `sendMessage` を呼ぶと "DataChannel is not open yet" エラーになり得る。Android 0051 と同一の挙動を保つためゲートは変更せず、`switched` 受信前は送信できない旨を `onDataChannel` の doc comment に明記する
- PeerChannel の内部フック `PeerChannelInternalHandlers.onOpenDataChannel` を利用する。`dataChannelDidChangeState` で検知した OPEN 遷移をこのフック経由で MediaChannel に通知して `onDataChannelOpened` を発火する（OPEN 遷移の検知の正は `dataChannelDidChangeState` であり、`peerConnection(_:didOpen:)` 内の防御的チェックも同じフックを通す）。防御的チェックは `rpcChannel` の設定より後に行い、`onDataChannelOpened` の発火時点で rpc 呼び出しが可能であることを保証する。同様に未使用だった `PeerChannelInternalHandlers.onCloseDataChannel` は削除する
- リダイレクト時の旧接続からの遅延通知を遮断するため、次のガードを実装する:
  - リダイレクト時に旧 RTCPeerConnection を明示的にクローズする。世代（`PeerChannel.dataChannelGeneration`）を先に進めてから close() し、close に伴う旧 DataChannel の `.closed` / `.open` 通知が切断として誤認されたり、OPEN 追跡状態を汚染したりするのを防ぐ
  - 旧 DataChannel の delegate は生成時点の世代を記録し、`dataChannelDidChangeState` / `dataChannel(_:didReceiveMessageWith:)` で現在の世代と照合して、旧接続の状態通知・遅延メッセージを無視する。answer の非同期処理（`createAndSendAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel`）は受信時点の世代を記録し、完了時に再照合して旧接続の answer が新接続に適用されるのを防ぐ
  - リダイレクトから新 PC 生成までの窓は `isRedirecting` フラグで、新 PC 生成後は PC アイデンティティ（`isCurrentPeerConnection`）で、`peerConnection(_:didOpen:)` / `peerConnection(_:didChange:)` の旧 PC からの通知を無視する
  - リダイレクト窓では旧 PC の close() により `PeerChannel.state` が `.closed` を返すため、切断要求（ユーザー切断・リダイレクト先への接続失敗）が握り潰されないよう、`isRedirecting` 中は切断処理を続行し、`basicDisconnect` でフラグを解除する（`Lock.unlock()` の遅延切断パスも同様に `isRedirecting` を考慮する）
  - リダイレクトで開始した WebSocket の接続試行が切断後に遅れて成功した場合に備え、SignalingChannel の接続成功ハンドラで `state == .disconnected` なら受け入れずに切断する。あわせて、切断後にリダイレクト先の WebSocket が接続成功しても connect メッセージを再送しないガードを入れる
  - `ignoreDisconnectWebSocket` は接続確立後の WebSocket 切断に対する扱いであり、接続確立前（`webSocketChannel == nil`）の候補枯渇による接続失敗には適用しない（適用するとリダイレクト先への接続失敗が検出不能になる）
  - リダイレクト窓で切断が実行された後に新 offer が届いた場合、`createAndSendAnswer` の `lock.lock()` が失敗（切断済み）するため、生成済みの RTCPeerConnection を close() してリークを防ぐ。新 PC 生成時には `isRedirecting` と `webSocketDisconnectScheduled` をリセットし、リダイレクト窓で発火をスキップした WebSocket 切断タイマーを新接続でもスケジュールできるようにする
- リダイレクト関連のガード（世代カウンタ（re-answer の完了時再照合を含む）・`isRedirecting`・`isCurrentPeerConnection`・旧 PC の明示クローズ・切断ガード・`webSocketDisconnectScheduled` のリセット・`resetDataChannelNotificationState`（offer 再送による追跡状態リセット）・SignalingChannel の WS 接続成功ガード・`ignoreDisconnectWebSocket` の接続確立前非適用）は、リダイレクトを発生させる Sora サーバ構成が必要なためテスト対象外とし、実機での手動確認とする。なお、`ignoreDisconnectWebSocket` の接続確立前非適用のみ、`ignoreDisconnectWebSocket = true` で存在しない URL への接続 E2E（connect がエラーで終端すること）で検証可能

### 4. 影響範囲

- `MediaChannelHandlers.onDataChannel` の doc comment（「シグナリングが DataChannel 経由に切り替わったタイミングで呼ばれるクロージャー」）を新仕様に合わせて更新する
- `SendonlyE2ETests` の `testSendonlySwitched` は onDataChannel が `switched` 受信時に発火する前提（`onDataChannel` の expectation を `switched` 受信後に fulfill している）で書かれているため、新仕様に合わせて検証内容とコメントを更新する。メッセージング用ラベルは `Configuration.dataChannels`（`SignalingChannel.send(message:)` による connect メッセージへの `data_channels` 注入）またはサーバ側（認証ウェブフック等）で払い出す。`#` ラベルが存在しない接続では `onDataChannel` は発火しないため、テストはこの前提を考慮する
- ドキュメントサイト（sora-ios-sdk-doc リポジトリ）の `onDataChannel` の説明も新仕様に合わせて更新する（別リポジトリのため対応は別途）

## 完了条件

- メッセージング用ラベル（offer の `data_channels` から `#` 始まりを抽出した集合）の DataChannel がすべてクライアント側で OPEN になった時点で `onDataChannel` が発火すること
- `type: switched` 受信時には `onDataChannel` が発火しないこと
- 受け取った各 DataChannel が OPEN へ遷移した時点で `onDataChannelOpened` がラベルごとに一度だけ発火すること（`#` 始まりのラベルに限定しない）
- 発火タイミングの変更と `onDataChannelOpened` の追加を、`CHANGES.md` の `develop` セクションにエントリとして追記すること（`onDataChannel` のタイミング変更は `[UPDATE]`、`onDataChannelOpened` の追加は `[ADD]`）
- `MediaChannelHandlers.onDataChannel` の doc comment と `SendonlyE2ETests` の `testSendonlySwitched` を新仕様に合わせて更新すること
- `testSendonlySwitched` の更新では、`Configuration.dataChannels` でメッセージング用ラベル（`#` 始まり）を明示的に払い出して検証すること。ラベルを払い出さない「発火するかもしれない」前提のテストにしないこと（スキップ依存・非決定的なテストを防ぐ）
- 単体テストまたは E2E テストで上記の発火タイミングを検証すること。検証項目は「`switched` 受信時には `onDataChannel` が発火しないこと」「全メッセージング用ラベルが OPEN になった後に `onDataChannel` が発火すること」「`onDataChannelOpened` がラベルごとに 1 回のみ発火すること（重複なし）」
- リダイレクト時のガード機構（旧 PC の明示クローズ・世代カウンタ（re-answer の完了時再照合を含む）・`isRedirecting`・`isCurrentPeerConnection`・切断ガード・`webSocketDisconnectScheduled` のリセット・SignalingChannel の WS 接続成功ガード・`ignoreDisconnectWebSocket` の接続確立前非適用）が正しく機能すること。リダイレクトを発生させる Sora サーバ構成が必要なためテスト対象外とし、実機での手動確認による

## 解決方法
