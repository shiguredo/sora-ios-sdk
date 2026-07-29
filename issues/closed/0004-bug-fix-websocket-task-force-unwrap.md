# URLSessionWebSocketChannel.send の webSocketTask force unwrap を修正する

- Priority: Medium
- Created: 2026-05-25
- Completed: 2026-05-26
- Model: Opus 4.7
- Branch: feature/fix-websocket-task-force-unwrap

## 目的

`URLSessionWebSocketChannel.send` メソッド内の `webSocketTask!` force unwrap を `guard let` に変更し、`nativeMessage` の IUO (`!`) も通常の変数に変更する。現状のコードフローでは通常クラッシュしないが、force unwrap は原則として避けるべきであり、防御的なコーディングにする。

## 優先度根拠

- 現状の呼び出しフローでは `SignalingChannel.send` (SignalingChannel.swift:276) が `guard let ws = webSocketChannel` で non-nil を確認してから呼び出すため、通常は `webSocketTask` が nil になる状況は起きにくい
- なお `disconnect()` (URLSessionWebSocketChannel.swift:93) は `webSocketTask = nil` を直接セットせず、`cancel` と `invalidateAndCancel` のみを呼ぶ。`webSocketTask` の nil 化は URLSession デリゲートコールバック経由で遅延するため、`disconnect()` 呼び出し直後の `send()` で force unwrap がクラッシュする可能性は低い。ただし `isClosing` フラグにスレッド安全性がないこと等により、タイミングによっては nil になる可能性を完全には排除できない
- 実用的なクラッシュリスクは低いが、同ファイルの `receive()` が `webSocketTask?.receive` とオプショナルチェイニングで安全に処理しているのに対し、`send()` のみ force unwrap を使用しているのは設計の一貫性に欠ける。`webSocketTask` は Optional 型で宣言されており、呼び出し側での nil チェックは防御的に行うべき
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

## 解決方法

`URLSessionWebSocketChannel.swift` の `send(message:)` メソッドに以下の修正を行った:

1. `var nativeMessage: URLSessionWebSocketTask.Message!` (IUO) を `let nativeMessage: URLSessionWebSocketTask.Message` に変更し、switch 文で直接代入するようにした
2. `webSocketTask!` の force unwrap を `guard let webSocketTask else { ... }` に変更し、nil の場合は `Logger.debug` でログ出力して return するようにした
3. `receive()` メソッドと同様に、nil の場合はクラッシュせず安全にリターンする設計に統一した
