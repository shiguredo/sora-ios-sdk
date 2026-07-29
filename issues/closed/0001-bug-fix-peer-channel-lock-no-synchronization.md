# PeerChannel.Lock の count / shouldDisconnect にスレッド間の排他制御がなくデータレースが発生する

- Priority: High
- Created: 2026-05-25
- Completed: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-peer-channel-lock-synchronization

## 目的

`PeerChannel.Lock` クラスの `count` と `shouldDisconnect` が複数スレッドから無保護でアクセスされるデータレースを修正する。`count` の read-modify-write が非アトミックであり、カウンタ値の破壊で `fatalError("count is already 0")` に到達する可能性がある。

## 優先度根拠

- `count` の read-modify-write が非アトミックであり、同時にインクリメントとデクリメントが実行されると値が破壊される
- カウンタ値が破壊された場合、`count` が 0 に戻らず `shouldDisconnect` で保留された切断が永久に実行されない状態に陥る可能性がある
- `waitDisconnect()` 内の `count == 0` チェックと `shouldDisconnect` への代入の間に他スレッドの操作が割り込むと、切断が実行されない

## 現状

`PeerChannel.Lock`（PeerChannel.swift:77-117）の `count` と `shouldDisconnect` は排他制御されていない。

```swift
// PeerChannel.swift:77-117
final class Lock {
    weak var context: PeerChannel?
    var count: Int = 0
    var shouldDisconnect: (Bool, Error?, DisconnectReason) = (false, nil, .unknown)

    func waitDisconnect(error: Error?, reason: DisconnectReason) {
        if count == 0 {
            context?.basicDisconnect(error: error, reason: reason)
        } else {
            shouldDisconnect = (true, error, reason)
        }
    }

    func lock() {
        count += 1  // 非アトミックな read-modify-write
    }

    func unlock() {
        if count <= 0 {
            fatalError("count is already 0")
        }
        count -= 1  // 非アトミックな read-modify-write
        if count == 0 {
            disconnect()
        }
    }

    func disconnect() {
        switch shouldDisconnect {
        case (true, let error, let reason):
            shouldDisconnect = (false, nil, .unknown)
            if let context {
                if context.state != .closed {
                    context.basicDisconnect(error: error, reason: reason)
                }
            }
        default:
            break
        }
    }
}
```

### lock/unlock/waitDisconnect の全呼び出し箇所

| メソッド | Lock メソッド | 行 | 実行スレッド |
|---|---|---|---|
| `connect()` | `lock()` | 222 | 外部呼び出しスレッド |
| `sendConnectMessage(error:)` | `unlock()` | 284 | 外部呼び出しスレッド |
| `createAndSendAnswer` | `lock()` | 800 | WebSocket コールバックスレッド |
| `createAndSendAnswer` | `unlock()` | 792 | WebSocket コールバックスレッド (nativeChannel 生成失敗時) |
| `createAndSendAnswer` | `unlock()` | 812, 821 | libwebrtc シグナリングスレッド (createAnswer コールバック内) |
| `createAndSendUpdateAnswer` | `lock()` | 828 | WebSocket コールバックスレッド |
| `createAndSendUpdateAnswer` | `unlock()` | 838, 855 | libwebrtc シグナリングスレッド |
| `createAndSendReAnswer` | `lock()` | 871 | libwebrtc シグナリングスレッド (createAnswer コールバック内) |
| `createAndSendReAnswer` | `unlock()` | 876, 893 | libwebrtc シグナリングスレッド |
| `createAndSendReAnswerOverDataChannel` | `lock()` | 911 | libwebrtc シグナリングスレッド (createAnswer コールバック内) |
| `createAndSendReAnswerOverDataChannel` | `unlock()` | 916, 932, 946, 962 | libwebrtc シグナリングスレッド |
| `finishConnecting` | `unlock()` | 1103 | libwebrtc シグナリングスレッド |
| `PeerChannel.disconnect()` | `waitDisconnect()` | 276 | WebSocket / RTCPeerConnectionDelegate スレッド |

### 具体的な競合シナリオ

1. **lock() と unlock() の同時実行**: `connect()` の `lock.lock()` (外部スレッド) と `createAndSendAnswer` の `lock.unlock()` (libwebrtc スレッド) が同時に実行される場合、`count` の read-modify-write が競合し、インクリメントまたはデクリメントが失われる
2. **waitDisconnect() と lock() の競合**: `PeerChannel.disconnect()` が `lock.waitDisconnect()` を呼び `count == 0` を確認した直後に、別スレッドで `lock.lock()` が実行されて `count` が 1 になった場合、`basicDisconnect` と新たな操作が並行して走る
3. **shouldDisconnect の競合**: `waitDisconnect()` が `shouldDisconnect = (true, ...)` を書き込むのと同時に、`Lock.disconnect()` が `shouldDisconnect` を読み取ると、部分的に書き込まれた値を読む可能性がある

## 設計方針

`Lock` クラスに NSLock を導入して `count` と `shouldDisconnect` へのアクセスを保護する。

### ロックスコープの設計

`count` と `shouldDisconnect` の読み書きのみをクリティカルセクションとし、`basicDisconnect()` の呼び出しはロック外で行う。具体的には:

- `unlock()`: NSLock 内で `count` のデクリメントと `shouldDisconnect` の読み取りを行い、ロック解放後に `basicDisconnect()` を呼ぶ
- `waitDisconnect()`: NSLock 内で `count == 0` のチェックと `shouldDisconnect` の設定を行い、ロック解放後に `basicDisconnect()` を呼ぶ
- `Lock.disconnect()`: NSLock 内で `shouldDisconnect` の読み取りとリセットを行い、ロック解放後に `basicDisconnect()` を呼ぶ

### 再入パスの分析

`Lock.disconnect()` → `basicDisconnect()` → `signalingChannel.disconnect()` → `PeerChannel.disconnect()` → `lock.waitDisconnect()` という再入パスが存在する。ただし:

- `basicDisconnect()` の L1135 で `nativeChannel?.close()` が呼ばれた後に `signalingChannel.disconnect()` (L1150) が呼ばれるため、再入時の `PeerChannel.state` は通常 `.closed` となり、`PeerChannel.disconnect()` の L272 `case .closed: break` で即座にリターンし、`lock.waitDisconnect()` には到達しない。ただし `RTCPeerConnection.close()` が同期的に `connectionState` を `.closed` に遷移させることは libwebrtc の実装上の挙動であり、仕様上の保証ではない
- **例外**: `nativeChannel` が nil の場合（`createAndSendAnswer` で `nativeChannel` 生成に失敗したケース等）、`state` が `.closed` にならず再入が成立する可能性がある

上記のロックスコープ設計（`basicDisconnect()` の呼び出しをロック外で行う）により、`state` ガードに依存せずとも、NSLock 保持中に `lock.waitDisconnect()` が再入することはない。`nativeChannel` が nil のケースでも安全に動作する。

なお、`PeerChannel.disconnect()` の `state` チェック (L271) と `lock.waitDisconnect()` (L276) の間にも TOCTOU が存在するが、これは `state` が `Lock` 外部の状態に依存するため本 issue のスコープ外とする。`waitDisconnect()` 内部の NSLock による排他制御で安全性は担保される。

### NSLock を選択する理由

- `os_unfair_lock`: Swift 5.x でクラスプロパティとして保持するとアドレスが固定されないため未定義動作になる。`OSAllocatedUnfairLock` は iOS 16+ のため、iOS 14 をデプロイメントターゲットとする本プロジェクトでは使用不可
- `NSRecursiveLock`: 上記ロックスコープ設計により再帰ロックは不要
- Serial DispatchQueue: 既存の lock/unlock のセマンティクス（参照カウント + 遅延切断）とはパターンが異なり、大規模なリファクタリングが必要になる

## 完了条件

- `Lock` の `count` / `shouldDisconnect` へのアクセスが NSLock で排他制御されている
- `basicDisconnect()` の呼び出しがロック外で行われている
- 全ての lock/unlock/waitDisconnect 呼び出し箇所（上表の全メソッド）で既存のバランスが維持されている
- Thread Sanitizer (TSan) を有効にしたビルドで `Lock` 関連のデータレース警告が出ない
- `nativeChannel` が nil の状態での `basicDisconnect` 再入パスでデッドロックしないことを確認する

## 後方互換

- `Lock` クラスは `internal` アクセスレベルであり、公開 API に変更はない
- lock/unlock のセマンティクス（参照カウント + 遅延切断）は変更しない

## 関連 issue

- issue 0007: `PeerChannel` の複数クロージャで `[weak self]` が欠如している問題。`[weak self]` 化後のクロージャから `self?.lock.lock()` を呼ぶ設計との整合性に注意が必要。issue 0007 の修正を先に適用した場合、`self` が nil になって `lock()` が呼ばれず `unlock()` だけが呼ばれるバランス崩壊が起きないか確認すること

## 解決方法

`PeerChannel.Lock` クラスに以下の修正を適用した。

### 1. NSLock による排他制御の導入

`count`, `shouldDisconnect`, および新規追加の `isDisconnecting` フラグへの全アクセスを単一の NSLock で保護した。`basicDisconnect()` の呼び出しは全てロック解放後に行い、再入パスでのデッドロックを防止する。

### 2. `isDisconnecting` フラグによる切断と新規処理開始の直列化

`waitDisconnect()` で `count == 0` の即時切断パス、および `unlock()` で `count` が 0 に戻り遅延切断を実行するパスで `isDisconnecting = true` を設定する。`lock()` は `isDisconnecting == true` の場合 `false` を返し、呼び出し側で早期リターンする。

不変条件: `isDisconnecting == true` ならば `count == 0`

### 3. `lock()` 呼び出し箇所の guard 化

以下の 4 箇所で `guard lock.lock() else { return }` に変更し、切断中の新規処理開始を拒否する:

- `createAndSendAnswer` 内（nativeChannel 生成後の createAnswer 開始時）
- `createAndSendUpdateAnswer` 内
- `createAndSendReAnswer` の createAnswer コールバック内
- `createAndSendReAnswerOverDataChannel` の createAnswer コールバック内

### 4. デッドコード `Lock.disconnect()` の削除

旧実装では `unlock()` → `disconnect()` と呼んでいたが、新実装では `unlock()` 内で直接 `shouldDisconnect` を処理するため、`Lock.disconnect()` は呼び出し元が存在しなくなった。このメソッドだけが `count > 0` のまま `isDisconnecting = true` を設定できる不整合な入口であったため削除した。
