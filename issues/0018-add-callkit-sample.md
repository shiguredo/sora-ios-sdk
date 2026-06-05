# CallKit を利用したサンプルを作る

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-callkit-sample

## 目的

CallKit を利用したサンプルを作成し、必要であれば iOS SDK 側を CallKit に対応させる。CallKit によりシステム標準の通話 UI やバックグラウンドでの音声処理が利用でき、通話アプリとしてのユーザー体験が向上する。バックグラウンド処理は通話アプリとして重要であり、他社 SDK が提供している機能を Sora iOS SDK でも提供できるようにする。

## 優先度根拠

- 他社 SDK が提供しておりユーザー体験上重要なバックグラウンド処理に関わるため、戦略的に対応したい。
- 緊急のバグ修正ではなく、まずサンプルでの検証段階のため High ではなく Medium とする。

## 現状

iOS SDK およびサンプルに CallKit 対応が存在しない。

- コードベースを検索しても CallKit (`CXProvider` / `CXCallController` 等) や VoIP プッシュ (PushKit) に関する実装は見当たらない (`Sora/` 配下に該当コードなし)。
- 本リポジトリにはサンプルアプリが含まれておらず、サンプルは別リポジトリで管理されている。そのためサンプルの実装作業自体は別リポジトリで行う。
- 音声トラックは libwebrtc のマイク入力に強く結びついており、CallKit / `AVAudioSession` との連携で SDK 側の調整が必要になる可能性がある。

```swift
// Sora/NativePeerChannelFactory.swift:134-144
func createNativeAudioSource(constraints: MediaConstraints?) -> RTCAudioSource {
  nativeFactory.audioSource(with: constraints?.nativeValue)
}

func createNativeAudioTrack(
  trackId: String,
  constraints: RTCMediaConstraints
) -> RTCAudioTrack {
  let audioSource = nativeFactory.audioSource(with: constraints)
  return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
}
```

なお SDK には音声モード制御として `Sora/AudioMode.swift` が存在し、`AVAudioSession` のカテゴリ / モード設定を扱っている。CallKit がオーディオセッションを有効化するタイミングとの整合を確認する必要がある。

## 設計方針

- まず CallKit を利用したサンプルを別リポジトリ (サンプル用リポジトリ) に作成し、Sora iOS SDK と組み合わせて通話 UI / バックグラウンド音声が機能することを確認する。
- `CXProviderDelegate` の `provider(_:didActivate:)` / `provider(_:didDeactivate:)` で `AVAudioSession` の有効化・無効化と Sora の接続ライフサイクルを連携させる。着信を扱う場合は VoIP プッシュ (PushKit) との連携も検討する。
- SDK 側で CallKit と共存するために必要な `AVAudioSession` 設定 (カテゴリ / モード) を確認し、`Sora/AudioMode.swift` 等の既存の音声モード制御と矛盾しないか検証する。
- サンプル作成の過程で SDK 側の対応が必要な箇所が判明した場合は、本リポジトリ側で対応するか別 issue として登録する。

## 完了条件

- CallKit を利用したサンプルが作成され、システム標準の通話 UI から Sora への接続・切断ができること。
- バックグラウンドでの音声送受信が機能することを確認できていること。
- サンプル作成の過程で判明した SDK 側の必要対応が洗い出され、対応が必要な場合は本リポジトリで対応するか別 issue 化されていること。
- SDK 側に変更が入る場合は、`CHANGES.md` の `develop` セクションに該当エントリを追記すること。

## 解決方法
