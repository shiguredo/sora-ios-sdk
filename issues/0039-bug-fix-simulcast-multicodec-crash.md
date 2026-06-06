# サイマルキャストマルチコーデック時に異なるコーデックを設定して r0 を active:false にするとクラッシュする

- Priority: High
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-simulcast-multicodec-crash
- Polished:

## 概要

サイマルキャストマルチコーデック時に r0 と r1 で異なるコーデックを指定した状態で r0 を `active: false` に設定すると、iOS SDK で接続時にクラッシュする。

## 再現条件

- サーバー側で `simulcast_multicodec = true` を設定する
- r0 と r1 に異なるコーデックを指定する（例: r0 に VP9、r1 に H.264）
- r0 を `active: false` に設定して接続する
- r0 と r1 が同一コーデックの場合は再現しない

## 確認済み環境

- iPhone 12 Pro Max / iOS 17.4.1

## 根拠

クラッシュはユーザーが接続できなくなる致命的な不具合であり、サイマルキャストマルチコーデック機能を利用している環境で発生する。r0/r1 に異なるコーデックを指定するケースは本機能の典型的な使い方であるため早期対応が必要。

## 調査方針

- クラッシュ箇所のスタックトレースを確認する
- `RTCRtpEncodingParameters` の `active` フラグとマルチコーデック設定の組み合わせ処理を調べる
- `PeerChannel.swift` の SDP 生成・設定処理を確認する
