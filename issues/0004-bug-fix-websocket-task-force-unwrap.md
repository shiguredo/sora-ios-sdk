# URLSessionWebSocketChannel.send の webSocketTask force unwrap を修正する

- Priority: Medium
- Created: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-websocket-task-force-unwrap

## 目的

`URLSessionWebSocketChannel.send` メソッド内の `webSocketTask!` force unwrap を `guard let` に変更し、`nativeMessage` の IUO (`!`) も通常の変数に変更する。現状のコードフローでは通常クラッシュしないが、force unwrap は原則として避けるべきであり、防御的なコーディングにする。

## 優先度根拠

- 現状の呼び出しフローでは `SignalingChannel.send` (SignalingChannel.swift:276) が `guard let ws = webSocketChannel` で non-nil を確認してから呼び出すため、通常は `webSocketTask` が nil になる状況は起きにくい
- ただし `disconnect()` と `send()` が異なるスレッドから同時に呼ばれた場合、`isClosing` フラグにスレッド安全性がないため、`disconnect()` で `webSocketTask` が nil にされた後に `send()` が実行される理論的可能性がある
- `isClosing` のスレッド安全性自体は本 issue のスコープ外とする。本 issue は force unwrap によるクラッシュの防止のみを対象とする

## 現状

```swift
// URLSessionWebSocketChannel.swift:102-129
func send(message: WebSocketMessage) {
    var nativeMessage: URLSessionWebSocketTask.Message!  // IUO
    switch message {
    case .text(let text):
        nativeMessage = .string(text)
    case .binary(let data):
        nativeMessage = .data(data)
    }
    webSocketTask!.send(nativeMessage) { [weak self] error in  // force unwrap
        // ...
    }
}
```

同ファイルの `receive()` メソッド (L132) では `webSocketTask?.receive` とオプショナルチェイニングで nil を安全に処理しており、`send()` との設計の一貫性がない。

## 設計方針

1. `webSocketTask!` を `guard let webSocketTask` に変更する。nil の場合は `Logger.debug` でログ出力して return する（`receive()` メソッドと同様にサイレントに処理するが、デバッグ用にログを残す）
2. `var nativeMessage: URLSessionWebSocketTask.Message!` を `let nativeMessage: URLSessionWebSocketTask.Message` に変更し、switch の結果を直接代入する

## 完了条件

- `send` メソッド内に `webSocketTask` の nil チェック（`guard let`）が追加されている
- `webSocketTask` が nil の場合にクラッシュせず、ログ出力して安全にリターンする
- `nativeMessage` が IUO ではなく通常の `let` 変数で宣言されている

## 後方互換

- `URLSessionWebSocketChannel` は `internal` アクセスレベルであり、公開 API に変更はない
- CHANGES.md には `[FIX]` として記録する
