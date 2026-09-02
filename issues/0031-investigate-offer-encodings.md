# type: offer の encodings 設定処理がリファクタ可能か調査する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-offer-encodings
- Polished: 2026-09-02

## 目的

Sora から `type: offer` で受け取った `encodings` を sender の `RtpParameters` に反映する処理に、過去のワークアラウンドと思われるコードがある。`active`（`is_active`）が素直に反映されなかった経緯で `parameters` を毎回コピーして丸ごとセットし直す実装になっている。WebRTC の `RtpSender::SetParameters` には制約があり、現在のワークアラウンドが今も必要かを調査し、不要であればリファクタリングする。

## 依存関係

本 issue と `0008-add-network-priority-to-rtp-encoding` は、いずれも `updateOfferEncodings(_:)` を変更するため実装が衝突する。0008（Medium）は先に実装・マージ済みであり、`networkPriority` の反映は `updateOfferEncodings(_:)` に既に含まれている。本 issue（Low）はその差分に追従して調査・リファクタリングを行う。

## 優先度根拠

- ユーザー影響のある不具合ではなく、調査とリファクタリングが主目的のため Low とする。

## 現状

`updateOfferEncodings(_:)` は `Sora/PeerChannel.swift` の `extension RTCRtpSender` に実装されており、`parameters` を都度コピー（`let newParameters = parameters`）して各エンコーディングフィールドを書き換えてから `parameters = newParameters` で書き戻す実装になっている。コメントには「parameters はアクセスのたびにコピーされてしまうので、すべての parameters をセットし直す」と記載されており、`active` が素直に反映されなかった経緯での対応と推測される。

`updateSenderOfferEncodings()`（`Sora/PeerChannel.swift`）は以下の 4 箇所から呼ばれる。

- `createAnswer` 内、`setRemoteDescription` 完了コールバックの中（`isSender == true` の場合。`initialOffer` の値に関わらず呼ばれる。`initialOffer` の条件は直前の `initializeSenderStream` にのみかかる）
- `createAndSendUpdateAnswer` 内、update-answer 送信後
- `createAndSendReAnswer` 内、re-answer 送信後
- `createAndSendReAnswerOverDataChannel` 内、DataChannel 経由の re-answer 送信後

`offerEncodings` は `Sora/PeerChannel.swift` で宣言されており、`createAndSendAnswer(offer:)` での代入が唯一の代入箇所。re-offer フロー（`createAndSendUpdateAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel` の呼び出し元）では `offerEncodings` が更新されないため、常に初回 offer の `encodings` が参照される。この挙動が意図的な仕様かどうかの確認が必要。

`updateOfferEncodings(_:)` 内の rid マッチング（`guard oldEncoding.rid == encoding.rid`）では、`oldEncoding.rid == nil` かつ `encoding.rid == nil` の場合も条件を通過する。サイマルキャスト非使用時（rid なし）に複数の `encodings` が存在すると、最初にマッチした `encoding` の値が全 sender に適用されてしまう可能性がある。

`RtpSender::SetParameters`（`pc/rtp_sender.cc`）には transaction_id の一致を含む複数の制約がある。どの制約が当時の問題の原因であったかは調査が必要。

## 設計方針

以下の順序で調査し、結果に基づいてリファクタリングの可否を判断する。

### 調査手順

1. **当時の事象の特定**: `git log -S "parameters はアクセスのたびにコピー" -- Sora/PeerChannel.swift` などでワークアラウンドを導入したコミットを特定し、コミットメッセージ・PR 説明から当時の原因を確認する。追跡できない場合はその旨を `## 解決方法` に記録し、以降の調査に基づいて判断する。
2. **libwebrtc m150 の制約確認**: `Package.swift` の `libwebrtcVersion`（現行 m150 系）で使用バージョンを確認した上で、`WebRTC.xcframework` 内の `RTCRtpSender` ヘッダーで `parameters` setter の制約を確認する。ヘッダーで判断できない場合は webrtc.googlesource.com の m150 タグ付近の `pc/rtp_sender.cc::SetParameters` を参照する。
3. **rid=nil マッチングの挙動確認**: サイマルキャスト非使用時の `updateOfferEncodings(_:)` の動作を確認し、rid=nil 同士のマッチングが正しいかを検証する。問題がある場合は修正または別 issue として起票する。
4. **re-offer 時の offerEncodings 未更新の確認**: re-offer フロー（`createAndSendUpdateAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel` の呼び出し元）で `offerEncodings` が更新されない挙動が仕様かどうかを `Sora/PeerChannel.swift` の処理フローで確認し、`## 解決方法` に記録する。
5. **rid 再代入の意図確認**: `updateOfferEncodings(_:)` 内の `oldEncoding.rid = rid`（`encoding.rid` が非 nil の場合の再代入）はマッチング後に同じ rid を再代入しており冗長に見える。ワークアラウンドの一部かどうかを確認する。

### リファクタリング方針（ワークアラウンドが不要と判明した場合）

- `updateOfferEncodings(_:)` の copy-all-parameters を廃止し、個別フィールドのみを更新する実装に簡潔化する。
- 反映される RtpParameters の最終結果（各エンコーディングの値）が変更前後で同一であることを担保する。挙動が変わるリファクタリングは行わない。

### ワークアラウンドが必要と判明した場合

- 調査結果をコメントとして `updateOfferEncodings(_:)` の冒頭に明記する（なぜ必要か・制約のどれに該当するか）。

## テスト方針

モック・スタブは使用しない。

- リファクタリングを行った場合は、既存の全テストが通ること。
- `updateOfferEncodings(_:)` に対応する専用テストが現時点で存在しないため（`grep -r updateOfferEncodings SoraTests/` で確認）、リファクタリングを行った場合は `SoraTests/` にテストを追加すること。`active` / `maxFramerate` / `maxBitrate` / `scaleResolutionDownBy` / `scaleResolutionDownTo` / `scalabilityMode` / `networkPriority` / `rid` マッチングの各フィールドが正しく反映されることを確認するテストを書くこと。

## 完了条件

- 当時の事象の原因が `SetParameters` の制約のどれに該当するか特定（または追跡不能として記録）され、`## 解決方法` に記録されていること。
- 現行 libwebrtc m150 での `SetParameters` 制約を踏まえ、現在のワークアラウンドが必要か不要かが結論付けられていること。
- rid=nil 同士のマッチング挙動が正しいか確認され、問題がある場合は修正または別 issue として起票されていること（別 issue として起票した場合、本 issue での追加対応は不要）。
- re-offer フロー（`createAndSendUpdateAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel`）での `offerEncodings` 未更新が仕様か問題かを確認し、`## 解決方法` に記録されていること。
- rid 再代入（`updateOfferEncodings(_:)` 内の `oldEncoding.rid = rid`）の意図を確認し、`## 解決方法` に記録されていること。
- ワークアラウンドが不要と判明した場合は `updateOfferEncodings(_:)` がリファクタリングされ、テスト方針に記載した全フィールドのテストを追加して反映結果が変更前後で同一であることが確認されていること。ワークアラウンドが必要と判明した場合は、なぜ必要かをコメントとして該当箇所に明記されていること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` セクションが存在しない場合は新設すること）:
  - リファクタリングを行った場合:
    ```
    - [UPDATE] updateOfferEncodings の copy-all-parameters ワークアラウンドを除去しリファクタリングする
      - @voluntas
    ```
  - コメント追記のみの場合:
    ```
    - [UPDATE] updateOfferEncodings のワークアラウンドが必要な理由をコメントとして明記する
      - @voluntas
    ```

## 解決方法
