# redirect 後に旧 PeerConnection の statistics が新接続へ送信される問題を修正する

- Created: 2026-09-01
- Completed:
- Priority: Low
- Branch:
- Polished: 2026-09-02

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

- 統計要求時に取得した `dataChannelGeneration` (transport epoch) と、コールバック発火時の現在の `dataChannelGeneration` を照合し、不一致の場合は送信しない。redirect 受理から新 offer 受信までの窓では `nativeChannel` が旧 PC のままのため、この窓の遮断は epoch 照合が担う。
- pong 送信時に、統計要求時に捕捉した RTCPeerConnection の identity と現在の `nativeChannel` を照合し、不一致の場合は送信しない。新 PC 生成後に遅延完了した旧 PC の統計はこの identity 照合が担う。
- 統計は送信経路 (signalingChannel.send) への露出を防ぎ、破棄する。
- 0095 の旧 transport 無効化と整合させる。本 issue は stats 送信経路の遮断のみを対象とする。

## テスト方針

モックやスタブは使用しない。

- redirect と ping (stats 付き) のイベントを `signalingChannel.internalHandlers.onReceive` 経由で入力し、統計コールバックの発火時に epoch 照合で破棄されることを検証する。統計コールバックは signaling イベントでは注入できないため、実 PeerConnection (`NativePeerChannelFactory.createNativePeerChannel` で生成して `PeerChannel.nativeChannel` へ設定) の実 statistics コールバックを利用する。
- epoch 照合と pong 送信の境界は単体テストで検証できるよう production のテスト可能な経路として実装し、世代不一致の入力で統計 pong が送信されないことを検証する。
- 実 Sora 環境での redirect 検証は、リダイレクトを発生させるサーバー構成が必要なためテスト対象外とし、実機での手動確認とする。

## 完了条件

- redirect 前に要求した統計が、redirect 完了後に新接続の signaling transport へ送信されないこと。
- 統計コールバック内で epoch 照合と PC identity 照合が行われ、不一致の場合に破棄されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
