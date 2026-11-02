# redirect 後に旧 PeerConnection の statistics が新接続へ送信される問題を修正する

- Created: 2026-09-01
- Completed: 2026-11-02
- Priority: Low
- Branch:
- Polished: 2026-09-16

## 目的

redirect 受理後に旧 PeerConnection の statistics コールバックが遅れて完了した場合、現在の signaling transport (新 WebSocket 接続) を使って旧接続の統計が pong として送信される問題を修正する。

## 現状

`Sora/PeerChannel.swift` の `handleSignalingOverWebSocket` (`case .ping`) で、`ping.statisticsEnabled == true` の場合は `nativeChannel?.statistics` を呼び、コールバック内で `self.signalingChannel.send(text: message)` により pong (stats 付き) を送信している。

```swift
case .ping(let ping):
  let pong = SignalingPong()
  if ping.statisticsEnabled == true {
    nativeChannel?.statistics { [weak self] report in
      ...
      self.signalingChannel.send(text: message)
    }
  }
```

- `nativeChannel` (RTCPeerConnection) の `statistics` コールバックは libwebrtc 側のスレッドから遅れて呼ばれる
- `signalingChannel` は redirect しても同一インスタンスのまま `redirect(location:)` で接続先を切り替える
- そのため、redirect 受理前の ping 統計要求が遅れて完了した場合、`self.signalingChannel.send(text:)` は **新 WebSocket 接続** に旧 PC の統計を pong として送信する

## 再現手順

1. クラスター構成の Sora サーバーに接続する。
2. `rtc_stats` を有効にした構成で ping (stats 付き) を受信する。
3. ping の統計要求が完了する前に redirect を発生させる。
4. redirect 完了後に統計コールバックが発火し、新接続の WebSocket へ旧 PC の統計が pong として送信されることを確認する。

## 設計方針

- 統計要求時に取得した `dataChannelGeneration` (transport epoch) と、コールバック発火時の現在の `dataChannelGeneration` を照合し、不一致の場合は送信しない。これは redirect 受理前に要求した統計のうち、redirect 窓 (受理から新 offer 受信まで) で遅延完了するものを遮断する。
- pong 送信時に、統計要求時に捕捉した RTCPeerConnection の identity と現在の `nativeChannel` を照合し、不一致の場合は送信しない。新 PC 生成後に遅延完了した旧 PC の統計はこの identity 照合が担う。
- コールバック発火時に redirect 窓中 (`isRedirecting`) の場合は送信しない。これは redirect 窓内に受信した stats 付き ping の応答を遮断する。判定基準は `0095` で導入された PC delegate と同様 (`!isRedirecting && nativePeerConnection === nativeChannel`) である。
- 統計は送信経路 (signalingChannel.send) への露出を防ぎ、破棄する。
- 0095 の旧 transport 無効化と整合させる。本 issue は stats 送信経路の遮断のみを対象とする。

## テスト方針

モックやスタブは使用しない。

- redirect と ping (stats 付き) のイベントを `signalingChannel.internalHandlers.onReceive` 経由で入力し、統計コールバックの発火時に epoch 照合で破棄されることを検証する。統計コールバックは signaling イベントでは注入できないため、実 PeerConnection (`NativePeerChannelFactory.createNativePeerChannel` で生成して `PeerChannel.nativeChannel` へ設定) の実 statistics コールバックを利用する。
- epoch 照合と pong 送信の境界は単体テストで検証できるよう production のテスト可能な経路として実装し、世代不一致・PC identity 不一致・redirect 窓中 (`isRedirecting`) の入力で統計 pong が送信されないことを検証する。
- 実 Sora 環境での redirect 検証は、リダイレクトを発生させるサーバー構成が必要なためテスト対象外とし、実機での手動確認とする。

## 完了条件

- redirect 前に要求した統計、および redirect 窓中 (新 offer 受信前) に受信した stats 付き ping の統計が、新接続の signaling transport へ送信されないこと。
- 統計コールバック内で epoch 照合、PC identity 照合、redirect 窓中判定が行われ、不一致または窓中の場合は破棄されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

2026-11-02 に、本 issue が扱う事象が production では成立しないことを確認し、コード変更なしで closed にした。

### 前提が成立しないことの確認

- Sora の redirect は `type: connect` を送った際の応答として送られる (Sora 公式ドキュメントの CLUSTER)。`closed/0101` の実機ログでも、connect → redirect → 新 WebSocket → connect(redirect:true) → offer → switched の順で、redirect が offer より前に届くことを確認している
- `Sora/PeerChannel.swift` の `nativeChannel` は `.offer` の処理でしか生成されない (`.redirect` は旧 PC を close するだけで、新しい PC は生成しない)。そのため redirect の時点で `statistics` の要求は存在せず、redirect を跨いで遅延完了する統計コールバックも存在しない
- redirect 窓中も `transportStorage.native` は旧 PC のまま (`isCurrentPeerConnection` と `.redirect` の実装) だが、窓中に ping は届かず、`nativeChannel?.statistics` が呼ばれる経路もない
- `closed/0105`、`closed/0176`、open の `0164` も同じ前提を記録している

### 現行コードの状態

`.ping` の stats pong 経路 (`handleSignalingOverWebSocket` の `.ping`) は、要求時の transport epoch / PC identity / `isRedirecting` の照合を持たず、完了した pong を無条件に `signalingChannel.send(text:)` へ渡す。本 issue の設計方針にあった照合は実装していない。

上記のとおり前提が成立しないため、この経路に遮断を追加しても到達しない防御コードになる。実装しない判断とした。

### 残課題

- `CHANGES.md` の 2026.3.0 の `[FIX]`「以後の `sendMessage` / RPC / stats が旧 DataChannel / 旧 PeerConnection を参照しないようにする」は、0095 の解決方法に stats が含まれず、`.ping` の pong 経路も遮断していないため、記述が実装より広い。訂正は別作業とする
- 将来 redirect が接続確立後に届く仕様へ変わった場合は、`0164` の判断 (到達しない無効化コードを残すか削除するか) と整合させたうえで、照合と送信を同一排他区間で行う設計を含めて別 issue にする

### 検証

コード変更を伴わないため、ビルドとテストは実行していない。上記の判断は develop `fed5f508` 時点の現行コードの静的読解と、Sora 公式ドキュメントおよび関連 issue の記録に基づく。
