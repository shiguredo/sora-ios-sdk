# Sora.add/remove の DispatchQueue.global().sync が排他制御として機能していない

- Priority: High
- Created: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-sora-add-remove-dispatch-queue

## 目的

`Sora.add(mediaChannel:)` と `Sora.remove(mediaChannel:)` が `DispatchQueue.global().sync` を使用しているが、`DispatchQueue.global()` は concurrent queue であるため排他制御として機能しない問題を修正する。`mediaChannels` 配列の同時変更により EXC_BAD_ACCESS でクラッシュする可能性がある。

## 優先度根拠

- concurrent queue に `.sync` で投入されたブロックは、同一キューに他のブロックが投入されていても並行してディスパッチされるため、`mediaChannels` 配列の同時変更（append / remove）が発生するとメモリ破壊・クラッシュにつながる
- `Sora` クラスは `@unchecked Sendable` (Sora.swift:38) と宣言されており、スレッド安全性を開発者が手動で保証する契約になっているが、この契約が満たされていない
- 複数の MediaChannel を同時に接続・切断する利用パターンで顕在化する

## 現状

```swift
// Sora.swift:117-135
func add(mediaChannel: MediaChannel) {
    DispatchQueue.global().sync {
        if !mediaChannels.contains(mediaChannel) {
            Logger.debug(type: .sora, message: "add media channel")
            mediaChannels.append(mediaChannel)
            handlers.onAddMediaChannel?(mediaChannel)
        }
    }
}

func remove(mediaChannel: MediaChannel) {
    DispatchQueue.global().sync {
        if mediaChannels.contains(mediaChannel) {
            Logger.debug(type: .sora, message: "remove media channel")
            mediaChannels.remove(mediaChannel)
            handlers.onRemoveMediaChannel?(mediaChannel)
        }
    }
}
```

`DispatchQueue.global()` は共有の concurrent queue を返す。concurrent queue は複数のブロックを別々のワーカースレッドで同時にディスパッチするため、`.sync` で投入しても `add` と `remove` が異なるスレッドから同時に呼ばれると `mediaChannels` への同時アクセスが発生する。

### add/remove の呼び出し箇所

| メソッド | 行 | 実行スレッド |
|---|---|---|
| `add(mediaChannel:)` | `Sora.connect()` 内 171 | ユーザーの任意のスレッド（`connect()` は public メソッド） |
| `remove(mediaChannel:)` | `onDisconnectLegacy` ハンドラ 164 | `MediaChannel` 内部の切断処理スレッド（WebRTC コールバック経由） |

### 具体的な競合シナリオ

1. **add と remove の同時実行**: ユーザーが `Sora.connect()` を呼んで `add` が実行されるのと同時に、既存の接続が切断されて `onDisconnectLegacy` から `remove` が呼ばれる場合、`mediaChannels` 配列の `append` と `remove` が並行して走る
2. **複数の connect の同時実行**: ユーザーが複数の `Sora.connect()` を異なるスレッドから呼んだ場合、2 つの `add` が並行して走り、`contains` チェックと `append` の間に他のスレッドの操作が割り込む

## 設計方針

NSLock を使用して `mediaChannels` への読み書きを排他制御する。

### NSLock を選択する理由

- issue 0001 で `PeerChannel.Lock` にも NSLock を導入するため、プロジェクト内で排他制御の手法を統一する
- Serial DispatchQueue + `.sync` は、コールバック内から再度 `.sync` すると同一スレッドでデッドロックするリスクがある。NSLock は異なるスレッドからのロック/アンロックが明確であり、ロックスコープの制御が容易
- `os_unfair_lock` / `OSAllocatedUnfairLock` は iOS 14 デプロイメントターゲットでは使用不可

### ロックスコープの設計

- `mediaChannels` への読み書き（`contains`、`append`、`remove`）のみをクリティカルセクションとする
- `handlers.onAddMediaChannel` / `handlers.onRemoveMediaChannel` コールバックの呼び出しはロック外で行う。ロック内で呼ぶとユーザーのハンドラ内から `Sora.connect()` を呼んだ場合にデッドロックする

### mediaChannels の外部読み取り保護

`public private(set) var mediaChannels` は外部から直接読み取り可能であり、同期保護されていない。NSLock 導入後、`mediaChannels` を `private` に変更し、スレッドセーフな computed property として公開する。

```swift
private var _mediaChannels: [MediaChannel] = []
public var mediaChannels: [MediaChannel] {
    mediaChannelLock.lock()
    defer { mediaChannelLock.unlock() }
    return _mediaChannels
}
```

Swift の Array は値型（struct）のため、getter でコピーが返される。COW (Copy-on-Write) により、呼び出し元で変更しなければコピーコストは発生しない。

## 完了条件

- `mediaChannels` への読み書きが NSLock で排他制御されている
- `handlers.onAddMediaChannel` / `handlers.onRemoveMediaChannel` コールバックがロック外で呼ばれている
- `public var mediaChannels` がスレッドセーフな computed property に変更されている
- 複数スレッドからの同時 add/remove でクラッシュしない
- Thread Sanitizer (TSan) を有効にしたビルドで `mediaChannels` 関連のデータレース警告が出ない

## 後方互換

- `mediaChannels` のアクセスが stored property から computed property に変わるが、外部からの読み取り API (`sora.mediaChannels`) は変更なし。Swift の値型セマンティクスにより、既存の利用コード（`for channel in sora.mediaChannels`、`sora.mediaChannels.count` 等）はそのまま動作する
- `private(set)` が削除されるが、元々 `set` は `internal` アクセスのため外部からの書き込みはできず、実質的な変更はない
- CHANGES.md には `[FIX]` として記録する

## スコープ外の関連問題

- **接続失敗時の mediaChannels リーク**: `connect()` で `add` した後に接続が失敗した場合、`onDisconnectLegacy` が呼ばれなければ `mediaChannels` から remove されない可能性がある。本 issue の排他制御とは別の問題だが、修正時に確認すべきパスとして認識しておくこと
- **SoraHandlers のクロージャプロパティのスレッド安全性**: `handlers.onAddMediaChannel` 等のクロージャは `public var` であり、ユーザーが任意のスレッドからハンドラを書き換えると Optional クロージャの読み書き自体がデータレースになる。これは `SoraHandlers` 全体の問題であり本 issue のスコープ外とする

## 関連 issue

- issue 0001: `PeerChannel.Lock` にも NSLock を導入する。排他制御の手法を統一する
