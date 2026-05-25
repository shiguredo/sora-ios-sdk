# ZLibUtil.unzip の入力長チェック不足でクラッシュする

- Priority: High
- Created: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-zlib-unzip-input-length-check

## 目的

`ZLibUtil.unzip` に入力データの最小長チェックがなく、5 バイト以下のデータが渡された場合に `Array.removeFirst(_:)` または `Array.removeLast(_:)` の precondition failure でクラッシュする問題を修正する。また、`size == 0` 経路で `destinationBuffer` が解放されないメモリリークも合わせて修正する。

## 優先度根拠

- DataChannel 経由で受信した圧縮データが不正（切り詰められた、破損した等）の場合にアプリがクラッシュする
- ネットワーク経由の外部入力に対するバリデーション不足であり、不正なデータでクラッシュを引き起こせる
- 修正は入力長チェックの追加と `destinationBuffer` のメモリ管理修正のみで影響範囲が小さい

## 現状

```swift
// DataChannel.swift:53-91
static func unzip(_ input: Data) -> Data? {
    if input.isEmpty {
        return nil
    }

    let bufferSize = 262_144
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    // ※ defer による deallocate がない

    var sourceBuffer = [UInt8](input)

    sourceBuffer.removeFirst(2)       // 1 バイト入力でクラッシュ

    let checksum = Data(sourceBuffer.suffix(4))
    sourceBuffer.removeLast(4)        // 残り要素が 4 未満でクラッシュ

    let size = compression_decode_buffer(...)

    if size == 0 {
        return nil                    // destinationBuffer がリークする
    }

    let data = Data(bytesNoCopy: destinationBuffer, count: size, deallocator: .free)
    // ...
}
```

入力データの構造は ヘッダー (2 バイト) + 圧縮データ (1 バイト以上) + チェックサム (4 バイト) であるため、最低 7 バイト必要（`zip` 関数の L37 で `size + 6` のバッファを確保していることからも確認できる）。

### 入力バイト数ごとの挙動

| 入力バイト数 | 挙動 |
|---|---|
| 0 | `input.isEmpty` で `nil` 返却（正常） |
| 1 | `removeFirst(2)` で precondition failure クラッシュ |
| 2-5 | `removeFirst(2)` 成功、`removeLast(4)` で precondition failure クラッシュ |
| 6 | `removeFirst(2)` + `removeLast(4)` 成功、圧縮データ 0 バイト → `compression_decode_buffer` で `size == 0` → `nil` 返却（クラッシュしないが `destinationBuffer` がリーク） |
| 7+ | 正常な処理パス |

### メモリリークの問題

`zip` 関数（L22-25）では `defer { destinationBuffer.deallocate() }` でバッファを確実に解放しているが、`unzip` では `Data(bytesNoCopy:deallocator:.free)` で正常系の所有権を移譲する設計のため `defer` がない。しかし `size == 0` で `nil` を返す経路（L77-78）で `destinationBuffer` が解放されない。

### 呼び出し元

`unzip` の唯一の呼び出し元は `BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` (DataChannel.swift:159)。`nil` が返った場合は `guard let` で早期 return しエラーログを出力する。修正後に `nil` を返す入力範囲が拡大しても、呼び出し元の挙動に変更はない。

## 設計方針

1. `input.isEmpty` チェック（L54）を `input.count < 7` チェックに変更する。このチェックは `destinationBuffer` の `allocate`（L60）より前にあるため、メモリ管理に影響しない
2. `size == 0` 経路（L77-78）で `destinationBuffer.deallocate()` を追加する

## 完了条件

- 5 バイト以下の入力データで `unzip` がクラッシュせず `nil` を返す
- 6 バイトの入力データで `unzip` が `nil` を返し、`destinationBuffer` がリークしない
- 7 バイト以上の正常な入力データに対する既存の動作が変わらない
- `size == 0` の経路で `destinationBuffer` が確実に解放される

## 後方互換

- `ZLibUtil` は `private enum` であり公開 API に変更はない
- 変更後、1-6 バイトの入力に対してクラッシュする代わりに `nil` を返すようになる。呼び出し元（L159）では `nil` をエラーとしてログ出力するため、ユーザーへの影響はない
- CHANGES.md には `[FIX]` として記録する

## テスト戦略

`ZLibUtil` は `private enum` であり `@testable import` でもアクセスできない。テスト方法として以下の選択肢がある:

- `ZLibUtil` のアクセスレベルを `internal` に変更して直接テスト可能にする
- `DataChannel` 経由の結合テストで、不正な圧縮データを受信するケースを検証する

いずれの場合も、0 / 1 / 2 / 5 / 6 / 7 バイトの入力でクラッシュしないことを確認する。
