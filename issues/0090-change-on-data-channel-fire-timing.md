# onDataChannel の発火タイミングをクライアント側の DataChannel 準備完了時に修正する

- Priority: Medium
- Created: 2026-08-14
- Completed:
- Model: deepseek-v4-flash
- Branch: feature/change-on-data-channel-fire-timing
- Polished:

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

個々の DataChannel がクライアント側で OPEN になったことは `BasicDataChannelDelegate.dataChannelDidChangeState`（DataChannel.swift:130-144）で検知できるが、現状では CLOSED のみを処理しており、OPEN 遷移の検知も `onDataChannel` の発火も行っていない。

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

- `BasicDataChannelDelegate.dataChannelDidChangeState` で `RTCDataChannelState.open` への遷移を検知する。現在は CLOSED のみを処理しているため、OPEN 遷移の検知を追加する
- メッセージング用ラベル（`#` で始まるラベル。`MediaChannel.sendMessage` と同じ判定）の DataChannel が**すべて** OPEN になったタイミングで `MediaChannelHandlers.onDataChannel` を発火する
- `type: switched` 受信時には `onDataChannel` を発火しない
- 既に OPEN 済みのメッセージング用ラベルがある場合は、その状態を保持し、最後の 1 つが OPEN になった時点で発火する
- 後方互換: API シグネチャは不変であり、発火タイミングのみの変更となる

### 2. ラベル個別の OPEN 通知コールバック追加（C++ 踏襲）

- `MediaChannelHandlers` に `onDataChannelOpened((MediaChannel, String) -> Void)?` を追加する。これは C++ SDK の `OnDataChannel`（OPEN 遷移時・ラベル個別・全ラベル対象・引数はラベル文字列）とタイミング・粒度を一致させる
- 発火条件: 受け取った**すべての** DataChannel がクライアント側で OPEN になった時点で、ラベルごとに 1 回発火する。`#` 始まりのラベルに限定しない
- 当初は Rust SDK の `on_data_channel_open` に合わせて `#` ラベルのみ対象とする方針だったが、Android issue 0051 の実装で C++ / Python SDK が全ラベル対象であることが確認されたため、全ラベル対象に変更する
- 重複通知は OPEN 済みラベルの集合で防止する
- 既存の `onDataChannel`（一括通知）は維持し、後方互換を保つ

### 3. 実装上の注意点（Android issue 0051 の実装知見）

- libwebrtc の `RTCDataChannelDelegate` は登録時に現在の state を即時通知しない実装であるため、登録時点で既に OPEN の場合の防御的チェックを追加する
- offer 再送（リダイレクト等）・切断時に OPEN 追跡集合と一括通知済みフラグをリセットする
- メッセージング用ラベルが存在しない場合は一括通知（`onDataChannel`）を発火しない
- ラベル個別通知は受信基準（offer の `data_channels` との突合は行わない）を採用する。Sora サーバは offer に含めた DataChannel しか作成しないため実用上は一致するが、予期しないラベルが届いた場合もユーザーに通知される受信基準を採用する

## 完了条件

- メッセージング用ラベルの DataChannel がすべてクライアント側で OPEN になった時点で `onDataChannel` が発火すること
- `type: switched` 受信時には `onDataChannel` が発火しないこと
- 受け取ったすべての DataChannel（`#` 始まりのラベルに限定しない）が OPEN になった時点で `onDataChannelOpened` がラベルごとに一度だけ発火すること
- 発火タイミングの変更と `onDataChannelOpened` の追加を、`CHANGES.md` の `develop` セクションにエントリとして追記すること（`onDataChannel` のタイミング変更は `[UPDATE]`、`onDataChannelOpened` の追加は `[ADD]`）
- 単体テストまたは E2E テストで上記の発火タイミングを検証すること

## 解決方法
