# TURN-TLS の証明書エラーで接続失敗した後も libwebrtc のログが流れ続ける問題を修正する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-turn-tls-log-leak-after-cert-error
- Polished: 2026-06-06

## 目的

TURN-TLS（`turn_tls_only` 指定）で証明書エラーにより接続に失敗した後も、`RTCPeerConnection` が動き続け、libwebrtc の VERBOSE ログ（ネットワーク列挙など）が出力され続ける。接続失敗時に確実に終了処理（`RTCPeerConnection` のクローズ）を行い、ログが止まるようにする。

## 優先度根拠

- 接続失敗後もネイティブのピア接続が動き続けるリソースリーク相当のバグであり、不要な処理とログ出力が継続する。
- ユーザー操作で接続失敗には到達するため再現性が高い。一方で接続成功時の通信には影響しないため High ではなく Medium とする。

## 再現手順

1. システム CA で検証できない証明書（自己署名証明書など、`SecTrustEvaluateWithError` が失敗するもの）を持つ `turns:` サーバーを用意する
2. `Configuration.iceServerInfos` に `turns:` の URL（例: `turns:<hostname>:443?transport=tcp`）を設定し、`Configuration.tlsSecurityPolicy = .secure` を指定する
3. `Sora.connect()` を呼んで接続を試みる
4. 接続失敗（`onConnect` コールバックに error が渡される）した後、Xcode Console を観察する
5. 接続失敗後も以下のような libwebrtc の VERBOSE ログが流れ続けることを確認する:

```
libwebrtc VERBOSE: (network.cc:155): Ignore link local IP:fe80:...
```

## 現状

証明書検証は `IOSCertificateVerifier.verifyChain(_:)` で行われ、検証に失敗すると `false` を返す。

```swift
// Sora/IOSCertificateVerifier.swift:23-37
@objc func verifyChain(_ derCertificateChain: [Data]) -> Bool {
  let certificateChain = derCertificateChain.compactMap { derCertificate in
    SecCertificateCreateWithData(nil, derCertificate as CFData)
  }

  guard !certificateChain.isEmpty else {
    return false
  }

  guard certificateChain.count == derCertificateChain.count else {
    return false
  }

  return evaluator(certificateChain)
}
```

検証失敗は libwebrtc の TURN-TLS 経路の失敗としてエラーになり、最終的に接続失敗が `PeerChannel` へ伝搬する。再現時の画面には「接続に失敗しました WebSocket error ...」が表示されるが、その後も libwebrtc の VERBOSE ログが出力され続ける。

接続失敗時の終了処理は `basicDisconnect`（`Sora/PeerChannel.swift:1160`）であり、その中の `nativeChannel?.close()`（`Sora/PeerChannel.swift:1189`）で `RTCPeerConnection` をクローズする。ネイティブのピア接続が閉じられず ICE 収集などが継続していると、ログが流れ続ける。

## 失敗経路の分析

TURN-TLS 証明書エラーが `PeerChannel` に伝わる経路として 2 つが考えられる:

**経路 A （WebSocket エラー経路）**: 証明書エラーが TURN ソケット失敗 → ICE 失敗 → WebRTC 内部エラー → シグナリング WebSocket が切断 → `signalingChannel.internalHandlers.onDisconnect`（`PeerChannel.swift:230`）→ `disconnect`（行 302）→ `basicDisconnect`（行 1160）

**経路 B （PeerConnectionState.failed 経路）**: 証明書エラー → TURN-TLS ハンドシェイク失敗 → ICE 状態が failed → `RTCPeerConnectionState.failed` → `peerConnection(_:didChange:RTCPeerConnectionState)`（行 1391）→ `disconnect`（行 302）→ `basicDisconnect`（行 1160）

再現時のエラーメッセージ「WebSocket error」は経路 A を示唆しているが、どちらの経路でも最終的に `basicDisconnect` → `nativeChannel?.close()` に到達するはずである。ログが流れ続けるということは、`nativeChannel?.close()` 自体が呼ばれていないか、呼ばれても libwebrtc 側で ICE 収集が即時停止しない可能性がある。

## 設計方針

調査と修正の手順は以下のとおり:

**ステップ 1 (調査): `nativeChannel?.close()` への到達確認**

`basicDisconnect`（`Sora/PeerChannel.swift:1160`）と `nativeChannel?.close()`（行 1189）にデバッグログを追加して実行し、証明書エラー発生後にこれらが呼ばれているかを確認する。

- `nativeChannel?.close()` が呼ばれていない場合: `disconnect` → `basicDisconnect` の経路のどこかで処理が止まっている。`Lock.waitDisconnect` のカウンタ（`PeerChannel.swift:81` の `private var count`）が 0 でない（別の非同期処理が `lock()` を保持している）可能性がある。または `disconnect` が `state == .closed` のため早期リターンしている可能性もある（行 303-305）。`Lock` クラスの `lock()`/`unlock()` および `basicDisconnect` の冒頭にデバッグログを追加して呼び出しスタックを確認し、`basicDisconnect` が呼ばれない原因を特定してから修正する。
- `nativeChannel?.close()` が呼ばれている場合: `RTCPeerConnection.close()` を呼んでも libwebrtc の ICE 収集タスクが即時停止しない可能性がある。その場合は `nativeChannel = nil` を明示的に代入して参照を切るか、close() 後に nativeChannel を nil に設定することを検討する。

**ステップ 2 (修正)**: ステップ 1 の調査結果をもとに修正を実施し、`## 解決方法` に何がどう失敗していたか・何を修正したかを記載する。修正は接続失敗時のクリーンアップに限定し、接続成功時の挙動は変更しない。

## テスト方針

モック・スタブは使用しない。再現手順の操作を実機または Simulator で行い、以下を手動テストで確認して `## 解決方法` に結果を記載すること:

- 修正後、TURN-TLS 証明書エラーで接続失敗した後、libwebrtc の VERBOSE ログ（`network.cc` 等）が停止すること（Xcode Console で目視確認）。停止するまでの時間は RTCPeerConnection の close 完了次第なので秒数は問わず、継続して流れ続けないことを確認する。
- 接続失敗後に `basicDisconnect` が呼ばれ `nativeChannel?.close()` が実行されることをデバッグログで確認すること。
- 有効な証明書を使った通常の TURN-TLS 接続が引き続き成功することを確認すること（後方互換確認）。

## 完了条件

- TURN-TLS の証明書エラーで接続に失敗した後、libwebrtc の VERBOSE ログが流れ続けないこと。
- 接続失敗時に `RTCPeerConnection` がクローズされ、ICE 収集などのネイティブ処理が停止すること。
- 接続成功時の挙動が変わらないこと。
- 調査内容と修正内容を `## 解決方法` に記載すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [FIX] TURN-TLS の証明書エラーで接続失敗後も libwebrtc のログが流れ続ける問題を修正する
    - @voluntas
  ```

## 解決方法
