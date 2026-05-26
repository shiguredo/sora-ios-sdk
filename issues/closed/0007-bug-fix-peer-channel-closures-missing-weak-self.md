# PeerChannel の複数クロージャで [weak self] が欠如し解放遅延のリスクがある

- Priority: Low
- Created: 2026-05-25
- Completed: 2026-05-26
- Model: Opus 4.7
- Branch: feature/fix-peer-channel-closures-missing-weak-self

## 目的

`PeerChannel` の複数のクロージャで `[weak self]` を使わず `self` を強参照キャプチャしている。libwebrtc 側が非同期コールバックを完了まで保持するため、self -> closure -> self の明確な循環参照ではないが、ネットワーク遅延やエラー時に PeerChannel とその上流オブジェクト（MediaChannel 等）の解放が遅延する可能性がある。同クラスの `signalingChannel.connect` コールバック (L262) や `MediaChannel.getStats` (L601) では正しく `[weak self]` が使われているため、スタイルの統一も兼ねて防御的に `[weak self]` を追加する。

## 優先度根拠

- self -> closure -> self の明確な循環参照ではなく、libwebrtc 側が完了まで保持する一時的な非同期コールバックであるため、閉じた循環参照リークではない
- 通常の接続・切断フローでは非同期処理が速やかに完了するため問題になりにくい
- ネットワーク遅延やエラー発生時に解放が遅延する可能性はあるが、接続フローの途中で PeerChannel が破棄されるケースは稀であり、実害は限定的
- MediaChannel.getStats のコメント (L597-600) に「self を強参照すると deinit が遅れたり循環参照が発生する恐れがあります」と明記されており、同じ考え方で防御的に他箇所にも適用するのが望ましい

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

修正価値の高い箇所から優先度をつけて対応する。各クロージャに `[weak self]` を追加し、`guard let self` で nil チェックしてから処理を行う。

### 修正対象と優先度

1. **statistics コールバック (L1045-1060)**: 優先度高。ping 応答の statistics 収集は PeerChannel が切断済みであれば不要であり、`self` が nil なら単に return すればよい。接続フローや lock/unlock に影響しない。

2. **createClientOfferSDP コールバック (L327-342)**: 優先度中。`sendConnectMessage` 内部で lock/unlock が管理されており、`self` が nil で return した場合でも Lock は解放済み（PeerChannel が解放済みのため）。`[weak self]` の追加により早期解放を促進できる。

3. **createAnswer 内のネストクロージャ (L717-750)**: 優先度中〜低。`setRemoteDescription` / `answer(for:)` / `setLocalDescription` の 3 段ネストの最外に `[weak self]` を追加すれば、内側クロージャは暗黙的 self キャプチャで追随する。ただし createAnswer の呼び出し元 (createAndSendAnswer 等) の handler クロージャは lock/unlock や disconnect 処理を担っているため、一律の `[weak self]` 化は避ける。self が nil でこれらの処理がスキップされると、接続状態の遷移が中途半端になる。この箇所は単体でのリスクが低いため無理に対応しなくてもよい。

4. **session.initializeInput コールバック (L570-584)**: 優先度低。`self.isAudioInputInitialized = true` のみの利用で保持期間が短く、修正の価値が小さい。対応は任意。

### lock/unlock バランスへの影響分析

- **createClientOfferSDP コールバック**: `self` が nil でリターンすると `lock.unlock()` が呼ばれないが、PeerChannel 自体が解放済みであれば Lock も解放されるため実害なし
- **createAnswer 内のクロージャ**: `createAnswer` は lock/unlock を直接管理しない。lock/unlock は呼び出し元の `createAndSendAnswer` 等で管理されており、それらには `[weak self]` を追加しない方針のため lock/unlock バランスは崩れない
- **statistics / initializeInput コールバック**: lock/unlock を含まないため影響なし

## 完了条件

- statistics コールバック (L1045) に `[weak self]` + `guard let self` が追加されている
- createClientOfferSDP コールバック (L327) に `[weak self]` + `guard let self` が追加されている
- createAnswer 内 `setRemoteDescription` コールバック (L717) への対応は任意とし、必須の完了条件とはしない
- 呼び出し元の handler クロージャ（createAndSendAnswer 等）は修正対象外とし、lock/unlock の整合性を損なわない
- `self` が nil の場合（PeerChannel が先に解放された場合）にクラッシュせず安全にリターンする

## 後方互換

- `PeerChannel` は `internal` アクセスレベルであり、公開 API に変更はない
- CHANGES.md には `[FIX]` として記録する

## 解決方法

`PeerChannel.swift` の以下の 3 箇所のクロージャに `[weak self]` + `guard let self` を追加した:

1. **createClientOfferSDP コールバック (L331)**: 従来 `{ sdp, sdpError in` だったのを `{ [weak self] sdp, sdpError in` に変更し、`guard let self else { return }` を追加した。`self` が nil の場合は早期リターンするが、PeerChannel 解放済みであれば Lock も解放されているため lock/unlock バランスは崩れない
2. **createAnswer setRemoteDescription コールバック (L720)**: 従来 `{ error in` だったのを `{ [weak self] error in` に変更し、`guard let self else { return }` を追加した。内側の `answer(for:)` および `setLocalDescription` クロージャは暗黙的 self キャプチャで追随する。呼び出し元 handler クロージャには `[weak self]` を追加していないため、lock/unlock の整合性は維持される
3. **statistics コールバック (L1048)**: 従来 `{ report in` だったのを `{ [weak self] report in` に変更し、`guard let self else { return }` を追加した。PeerChannel が切断済みであれば ping 応答は不要であり、self が nil なら安全にリターンする

修正対象外とした箇所:
- `session.initializeInput` コールバック: `isAudioInputInitialized = true` のみで保持期間が短く、修正価値が小さいため対応しなかった
- `createAndSendAnswer` 等の呼び出し元 handler クロージャ: lock/unlock や disconnect 処理を担っており、接続状態遷移の整合性を維持するため修正しなかった

## 関連 issue

- issue 0001: `PeerChannel.Lock` に NSLock を導入する。`[weak self]` 化後に `self` が nil で lock/unlock が呼ばれないパスが生じるが、PeerChannel 解放済みのため Lock も解放されており問題ない。ただし issue 0001 の排他制御導入と本 issue の [weak self] 導入の適用順序によっては、テスト時に中間状態が生じる可能性がある
