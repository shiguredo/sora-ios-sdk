# TURN-TLS の証明書エラーで接続失敗した後も libwebrtc のログが流れ続ける問題を修正する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-turn-tls-log-leak-after-cert-error

## 目的

TURN-TLS（`turn_tls_only` 指定）で証明書エラーにより接続に失敗した後も、`RTCPeerConnection` が動き続け、libwebrtc の VERBOSE ログ（ネットワーク列挙など）が出力され続ける。接続失敗時に確実に終了処理（`RTCPeerConnection` のクローズ）を行い、ログが止まるようにする。

## 優先度根拠

- 接続失敗後もネイティブのピア接続が動き続けるリソースリーク相当のバグであり、不要な処理とログ出力が継続する。
- ユーザー操作で接続失敗には到達するため再現性が高い。一方で接続成功時の通信には影響しないため High ではなく Medium とする。

## 現状

証明書検証は `IOSCertificateVerifier.verifyChain(_:)` で行われ、検証に失敗すると `false` を返す。

```swift
// Sora/IOSCertificateVerifier.swift:23
@objc func verifyChain(_ derCertificateChain: [Data]) -> Bool {
  let certificateChain = derCertificateChain.compactMap { derCertificate in
    SecCertificateCreateWithData(nil, derCertificate as CFData)
  }

  guard !certificateChain.isEmpty else {
    return false
  }
  // ...
  return evaluator(certificateChain)
}
```

検証失敗は libwebrtc の TURN-TLS 経路の失敗としてエラーになり、WebSocket エラーとして上位に伝搬する。再現時、quickstart の画面には「接続に失敗しました WebSocket error ...」が表示されるが、その後も次のような libwebrtc の VERBOSE ログが出力され続ける。

```
libwebrtc VERBOSE: (network.cc:155): Ignore link local IP:fe80:...
```

接続に失敗しているのでログは出力されないはずであり、終了処理に失敗している可能性がある。接続失敗時の終了処理は `basicDisconnect`（`Sora/PeerChannel.swift:1160`）であり、その中の `nativeChannel?.close()`（`Sora/PeerChannel.swift:1189`）で `RTCPeerConnection` をクローズする。証明書検証失敗の経路でここまで到達しているか、`RTCPeerConnection` がクローズされているかが疑わしい。ネイティブのピア接続が閉じられず ICE 収集などが継続していると、ログが流れ続ける。

## 設計方針

- 証明書検証失敗による接続失敗時に終了処理がどこまで到達しているかを切り分ける。`disconnect`（`Sora/PeerChannel.swift:302`）から `basicDisconnect`（`Sora/PeerChannel.swift:1160`）の `nativeChannel?.close()`（`Sora/PeerChannel.swift:1189`）まで到達し、`RTCPeerConnection` がクローズされているかを確認する。
- 到達していない場合は、証明書検証失敗を含む接続失敗時に確実に `disconnect` が呼ばれ、ネイティブのピア接続がクローズされるよう修正する。
- WebSocket エラーとして上位に伝搬する経路と、ネイティブのピア接続を閉じる経路の双方が実行されることを保証する。
- 修正は接続失敗時のクリーンアップに限定し、接続成功時の挙動は変更しない。後方互換性を維持する。

## 完了条件

- TURN-TLS の証明書エラーで接続に失敗した後、libwebrtc の VERBOSE ログが流れ続けないこと。
- 接続失敗時に `RTCPeerConnection` がクローズされ、ICE 収集などのネイティブ処理が停止すること。
- 接続成功時の挙動が変わらないこと。
- `CHANGES.md` の `## develop` セクションに `[FIX]` エントリと担当者行を追記すること。

## 解決方法
