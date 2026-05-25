# PeerChannel の複数クロージャで [weak self] が欠如しメモリリークのリスクがある

- Priority: Medium
- Created: 2026-05-25
- Model: Opus 4.7
- Branch: feature/fix-peer-channel-closures-missing-weak-self

## 目的

`PeerChannel` の複数のクロージャで `[weak self]` を使わず `self` を強参照キャプチャしており、libwebrtc の非同期処理が完了するまで PeerChannel とその上流オブジェクト（MediaChannel 等）が解放されない問題を修正する。同クラスの `signalingChannel.connect` コールバック (L230) や `MediaChannel.getStats` (L601) では正しく `[weak self]` が使われている。

## 優先度根拠

- 通常の接続・切断フローでは非同期処理が速やかに完了するため問題になりにくいが、ネットワーク遅延やエラー発生時に PeerChannel とオブジェクトグラフ全体の解放が遅延する
- MediaChannel.getStats のコメント (L597-600) に「self を強参照すると deinit が遅れたり循環参照が発生する恐れがあります」と明記されており、同じ対策が他箇所に適用されていない

## 現状

以下の 4 箇所のクロージャで `[weak self]` が欠如している。

### 1. sendConnectMessage の createClientOfferSDP コールバック (L295-311)

```swift
nativePeerChannelFactory
    .createClientOfferSDP(...) { sdp, sdpError in
        // ...
        self.sdp = sdp                                    // self 強参照
        self.sendConnectMessage(with: sdp, error: error)  // self 強参照
    }
```

### 2. createAnswer 内のネスト 3 段クロージャ (L685-748)

```swift
nativeChannel.setRemoteDescription(offer) { error in
    guard let nativeChannel = self.nativeChannel else { ... }  // self 強参照
    self.initializeSenderStream(mid: mid)                      // self 強参照
    self.updateSenderOfferEncodings()                          // self 強参照
    nativeChannel.answer(for: constraints) { answer, error in
        guard let nativeChannel = self.nativeChannel else { ... }  // self 強参照
        nativeChannel.setLocalDescription(answer!) { error in
            handler(answer!.sdp, nil)
        }
    }
}
```

### 3. handleSignalingOverWebSocket の ping 応答 statistics コールバック (L1000-1015)

```swift
nativeChannel?.statistics { report in
    // ...
    self.signalingChannel.send(text: message)     // self 強参照
    self.signalingChannel.send(message: .pong(pong))  // self 強参照 (エラー時)
}
```

### 4. initializeAudioInput の session.initializeInput コールバック (L538-552)

```swift
session.initializeInput { error in
    // ...
    self.isAudioInputInitialized = true  // self 強参照
}
```

## 設計方針

各クロージャに `[weak self]` を追加し、`guard let self` で nil チェックしてから処理を行う。

### 箇所ごとの修正方針

1. **createClientOfferSDP コールバック (L295-311)**: `[weak self]` を追加し、`guard let self` 後に既存のロジックを実行する。`self` が nil の場合は早期リターンする。この場合 `connect()` の L222 で取得した `lock.lock()` に対応する `unlock()` が呼ばれないが、PeerChannel 自体が解放済みであれば Lock オブジェクトも解放されているため問題ない
2. **createAnswer 内のネストクロージャ (L685-748)**: 最外側の `setRemoteDescription` コールバックに `[weak self]` を追加し、`guard let self` 後に内側のクロージャでは暗黙的 self キャプチャを使用する。ただし `createAnswer` の handler パラメータを通じて渡されるクロージャ（`createAndSendAnswer` L807-823、`createAndSendUpdateAnswer` L829-856、`createAndSendReAnswer` L862-893、`createAndSendReAnswerOverDataChannel` L909-963）も `self` を強参照しているため、これらの呼び出し元クロージャにも `[weak self]` を追加する必要がある。呼び出し元クロージャが `self` を強参照している限り、`createAnswer` 内部のみに `[weak self]` を付けても効果が限定的であるため、両方を修正する
3. **statistics コールバック (L1000-1015)**: `[weak self]` を追加し、`guard let self` 後に既存ロジックを実行する。`self` が nil の場合は pong を送信できないが、PeerChannel が解放済みの時点で pong の送信は不要
4. **session.initializeInput コールバック (L538-552)**: `[weak self]` を追加し、`guard let self` 後に `self.isAudioInputInitialized = true` を実行する。`self` が nil の場合は PeerChannel が解放済みであり、`isAudioInputInitialized` の設定は不要

### lock/unlock バランスへの影響分析

`[weak self]` 導入で `self` が nil になった場合に lock/unlock バランスが崩れないかを分析する。

- **createClientOfferSDP コールバック**: `self` が nil でリターンすると `lock.unlock()` が呼ばれない（`sendConnectMessage(error:)` の L284 か `finishConnecting` の L1103 で解放される予定だった）。しかし PeerChannel 自体が解放済みであれば Lock も解放されるため実害なし
- **createAnswer 内のクロージャ + 呼び出し元のハンドラクロージャ**: `createAnswer` 内部と呼び出し元の handler クロージャの両方に `[weak self]` を付ける。`createAndSendAnswer` (L800) と `createAndSendUpdateAnswer` (L828) では handler の **外** で `lock.lock()` を呼び、handler **内** で `lock.unlock()` している。`self` が nil で handler が呼ばれなくなると `lock.unlock()` が呼ばれないが、PeerChannel 解放済みであれば Lock も解放されるため実害なし。`createAndSendReAnswer` (L871) と `createAndSendReAnswerOverDataChannel` (L911) では handler **内** で `lock.lock()` を呼ぶため、`self` が nil で early return すれば lock/unlock のペア自体がスキップされ、バランスは崩れない
- **statistics コールバック / session.initializeInput コールバック**: lock/unlock を含まないため影響なし

## 完了条件

- 上記 4 箇所のクロージャで `[weak self]` が使われている
- `self` が nil の場合（PeerChannel が先に解放された場合）にクラッシュせず安全にリターンする
- 既存の接続・切断フローの動作が変わらない
- lock/unlock のバランスが崩れないことが確認されている

## 後方互換

- `PeerChannel` は `internal` アクセスレベルであり、公開 API に変更はない
- CHANGES.md には `[FIX]` として記録する

## 関連 issue

- issue 0001: `PeerChannel.Lock` に NSLock を導入する。`[weak self]` 化後に `self` が nil で lock/unlock が呼ばれないパスが生じるが、PeerChannel 解放済みのため Lock も解放されており問題ない。ただし issue 0001 の排他制御導入と本 issue の [weak self] 導入の適用順序によっては、テスト時に中間状態が生じる可能性がある
