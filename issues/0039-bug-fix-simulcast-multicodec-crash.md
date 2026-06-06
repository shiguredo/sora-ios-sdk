# サイマルキャストマルチコーデック時に異なるコーデックを設定して r0 を active:false にするとクラッシュする

- Priority: High
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-simulcast-multicodec-crash
- Polished: 2026-06-06

## 目的

サイマルキャストマルチコーデック時に r0 と r1 で異なるコーデックを指定した状態で r0 を `active: false` に設定すると、iOS SDK で接続時にクラッシュする。クラッシュはユーザーが接続できなくなる致命的な不具合であるため修正する。

## 優先度根拠

サイマルキャストマルチコーデック機能を利用している環境で r0/r1 に異なるコーデックを指定するケースは本機能の典型的な使い方である。クラッシュにより当該環境のユーザーが一切接続できなくなるため High とする。

## 現状

### 再現条件

- サーバー側で `simulcast_multicodec = true` を設定する
- r0 と r1 に異なるコーデックを指定する（例: r0 に VP9、r1 に H.264）
- r0 を `active: false` に設定して接続する（Sora サーバーが `SignalingOffer.encodings` の `active: false` を通知する）

### 確認済み環境

- iPhone 12 Pro Max / iOS 17.4.1
- libwebrtc m148.7778.7.0

### コードの実態

`Signaling.swift` の `SignalingOffer` には `simulcastMulticodec: Bool?` と `videoCodecType: String?` フィールドが存在し、サーバーからの offer をデコードしている。しかし `PeerChannel.swift` の `handleSignalingOverWebSocket` では `offer.simulcast` のみを参照し、**`offer.simulcastMulticodec` と `offer.videoCodecType` は受信後に一切使われていない**。このためマルチコーデック固有の処理が SDK に存在しない。

`updateOfferEncodings`（`PeerChannel.swift`）では `oldEncoding.rid == encoding.rid` で照合して `isActive = encoding.active` を設定するが、マルチコーデック時に Sora が送る `encodings` の rid の値・構造（通常サイマルキャストと異なる可能性）が未確認のまま使用されている。

`WrapperVideoEncoderFactory` はシングルトンであり `simulcastEnabled` フラグしか持たない。マルチコーデック向けのファクトリー切り替えロジック（per-encoding でコーデックを変える仕組み）が存在しない。

### クラッシュ種別

未特定。スタックトレースの取得が最初の作業となる。

## 設計方針

1. 実機でクラッシュを再現し、スタックトレースを取得してクラッシュ箇所を特定する。同一コーデック時の再現有無もこの段階で確認する
2. `simulcast_multicodec: true` 時に Sora が送る `SignalingOffer.encodings` の JSON 構造（特に `rid` フィールドの値と `video_codec_type` の有無）を Sora ドキュメントまたは実際の通信ログで確認する
3. `offer.simulcastMulticodec` および `offer.videoCodecType` の値を受信後に処理するコードパスを実装する。 `handleSignalingOverWebSocket` の `.offer` 分岐で `WrapperVideoEncoderFactory` に対してマルチコーデック情報を渡す処理が必要になる可能性がある
4. `updateOfferEncodings` での rid マッチングがマルチコーデック時の `encodings` 構造に対して正しく機能するかを確認し、必要に応じて修正する
5. `WrapperVideoEncoderFactory` がマルチコーデックをサポートするために必要な変更範囲を評価する（大規模変更が必要な場合は別 issue に分離する）

なお、`0031-investigate-offer-encodings.md` は `updateOfferEncodings` の `active` フラグ反映・rid マッチング挙動・SetParameters ワークアラウンドの是非など、本 issue と重複する調査対象を持つ。0031 の調査結果（`updateOfferEncodings` の修正方針）が本 issue の修正方針に影響する可能性があるため、0031 の進捗を確認してから同関数に手を加えることを推奨する。

## 完了条件

- 上記再現条件で接続時にクラッシュが発生しなくなること
- `simulcast_multicodec: false` の通常サイマルキャスト接続に影響がないこと
- `offer.simulcastMulticodec` と `offer.videoCodecType` が `handleSignalingOverWebSocket` の `.offer` 分岐で適切に処理されること（またはクラッシュの根本原因がこれら未処理に起因しないと調査で確認されること）
- マルチコーデック時の `updateOfferEncodings` の rid マッチングが正しく動作すること（または問題なしと調査で確認されること）
- `simulcast_multicodec: true` 時に Sora が送る `SignalingOffer.encodings` の JSON 構造（`rid` フィールドの値・`video_codec_type` の有無）が本 issue に記録されること
- `WrapperVideoEncoderFactory` の変更が必要かどうかの評価結果が本 issue に明記されること（大規模変更が必要な場合は別 issue に分離されること）
- 調査の結果クラッシュを再現できない場合は、再現環境の詳細を issue に追記して close する
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] サイマルキャストマルチコーデック時に r0 を active:false にするとクラッシュする問題を修正する
  - @voluntas
```
