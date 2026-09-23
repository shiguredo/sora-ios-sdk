# Sora.connect の webRTCConfiguration 引数が接続に反映されない問題を修正する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-ignored-webrtc-configuration
- Polished: 2026-09-23

## 目的

`Sora.connect(configuration:webRTCConfiguration:handler:)` の `webRTCConfiguration` 引数が接続処理に反映されず、利用者が指定した ICE サーバーや ICE トランスポートポリシーが無視される問題を修正する。

ICE サーバーを設定したつもりで接続できず、TURN 経由の接続が必要な環境で接続に失敗する。

## 現状

WebRTC 設定の入力点は 2 つある。`Sora/Configuration.swift` の `Configuration.webRTCConfiguration`（既定値 `WebRTCConfiguration()`）と、`Sora/Sora.swift` の `Sora.connect` が受け取る `webRTCConfiguration` 引数（既定値 `WebRTCConfiguration()`）である。設定値の型は `Sora/WebRTCConfiguration.swift` の公開 struct `WebRTCConfiguration` で、`constraints` / `iceServerInfos` / `iceTransportPolicy` / `sdpSemantics` / `degradationPreference` を持つ。

実際に接続へ反映される入力点は 1 つだけである。

- `Sora.connect` は `MediaChannel` の生成より先に `ConnectionConfigurationSnapshot.init(configuration:)`（`Sora/ConnectionConfigurationSnapshot.swift`）を呼び、snapshot 生成が `Configuration.webRTCConfiguration` を `WebRTCConfigurationSnapshot` へ写し取る。写し取られるのは `constraints` / `iceServerInfos` / `iceTransportPolicy` / `sdpSemantics` / `degradationPreference` であり、`isInsecure` は offer 受信時に `Configuration.insecure` から設定される（後述）。
- `PeerChannel` は snapshot の値を接続所有インスタンス（`webRTCConfigurationLock` で保護）へコピーし（`Sora/PeerChannel.swift`）、offer 生成（`createClientOfferSDP`）と `RTCPeerConnection` 生成（`createNativePeerChannel` / `setConfiguration`）で使う。`RTCPeerConnection` の ICE サーバーと ICE トランスポートポリシーにはこの値がそのまま反映される（`WebRTCConfigurationSnapshot.nativeValue`）。

一方、`Sora.connect` の引数は `MediaChannel.connect(webRTCConfiguration:)`（`Sora/MediaChannel.swift`）へ渡されるが、そこでは参照されない。doc コメントに「接続処理はこの引数を使わず、接続開始時の snapshot から設定を読む」と明記されており、`0102` は `basicConnect` の未使用な引数自体を削除済みである。つまり引数は実効設定へ一切反映されない。

さらに、引数は非 optional の `WebRTCConfiguration = WebRTCConfiguration()` という既定値を持つため、「未指定」と「既定値を明示指定」を区別できない。`WebRTCConfiguration()` は `iceServerInfos` が空であるため、単純に「指定された値で `Configuration.webRTCConfiguration` を上書きする」実装にすると、この既定値が省略時にも渡ってしまい、`Configuration.webRTCConfiguration` に ICE サーバーを設定している利用者を空の値で壊す。既定値を `nil` へ変えない限り、引数が有効となる安全な実装は成立しない。

## 設計方針

- 正本は `Configuration.webRTCConfiguration` とする。snapshot 生成がこれを写し取っており、利用者向け文書（`skills/sora-ios-sdk/SKILL.md`）も ICE サーバー等はこの property で設定する形で、接続例は引数を省略している。
- `Sora.connect` の引数を `WebRTCConfiguration? = nil` に変更する。これはソース互換である（Swift は非 optional の値を optional の引数位置へ暗黙に昇格するため、既存の呼び出しは変更不要）。
  - 引数が `nil`（省略または明示的な `nil`）のとき: `Configuration.webRTCConfiguration` を使う。引数を省略している既存利用者の挙動は変わらない。
  - 引数が非 `nil` のとき: 指定値を正本へ上書きし、snapshot 生成の入力へ反映する。上書きは `MediaChannel.connect(webRTCConfiguration:)` 経由ではなく、`Sora.connect` 内の snapshot 生成前に行う（`0102` 以降、snapshot は `MediaChannel.init` より前に `Sora.connect` で生成されるため）。
- 既定値を `WebRTCConfiguration()` から `nil` へ変えるのは、省略時の上書き事故（空の `WebRTCConfiguration()` で正本を潰す）を防ぎ、「未指定」と「明示指定」を区別できるようにするためである。`nil` のままにすると引数が有効になる実装が成立しないことを「現状」に記した。
- 引数単位の非推奨化は Swift では表現できない。`@available(*, deprecated)` は関数全体に付与されるため、引数を使わない利用者にも非推奨警告が出る。関数全体の非推奨化・引数の削除は後方互換のない変更であり、本 issue では行わない（必要になった場合は別 issue で扱う）。
- 利用者が `Configuration.webRTCConfiguration` と引数の両方を設定している場合、引数が優先されることを利用者向け文書と `CHANGES.md` に明記する。従来は引数が無視されており、この優先順位は本 issue が新たに定める仕様である。
- ICE サーバーは offer 受信時にサーバー値で上書きされる既存挙動を変えない。`isInsecure` は `Configuration.insecure` から設定する既存挙動も変えない（`PeerChannel.createAndSendAnswer`）。
- `0102` の完了を前提とする。`0102` は snapshot を `Configuration.webRTCConfiguration` から生成する（完了 2026-09-16）。

## 前提となる issue

- `0102`（完了 2026-09-16）: 接続設定の snapshot 化。本 issue の修正対象と同じ引数（の実体）を扱い、snapshot 生成が `Configuration.webRTCConfiguration` を写し取る。本 issue は `0102` の完了後に着手する（`0102` の完了条件「`0152` / `0153` / `0154` は本 issue の完了後に着手する」に従う）。
- `0152`（open）: 公開 Sendable 設定型と新 overload の追加。本 issue は既存 overload の引数だけを扱い、新 overload と公開設定型は変更しない（`0152` のスコープ外に同旨あり）。両 issue とも `Sora.swift` を変更するため、順序は問わないが実装時の共存に注意する。
- `0107`（open）: 公開 API baseline。本 issue は公開シグネチャ（引数の型と既定値）を変えるため、`0107` の baseline が有効な場合は差分の更新が必要になる。

## スコープ外

- `webRTCConfiguration` 引数の削除（後方互換のない変更）。Swift は引数単位の非推奨化を提供しないため、必要になった場合は別 issue として非推奨化と削除の手順を設計する。
- `MediaChannel.connect(webRTCConfiguration:)` の internal 引数の削除。既存テストの呼び出し互換のために `0102` が残したものであり、本 issue では変更しない。
- `0058`（open）: async 版 `Sora.connect`。実装時は本 issue と同じ引数の扱い（optional・`nil` 既定値・正本の上書き）に揃える。
- `0152`: 公開 Sendable 設定型の設計と実装。

## 変更対象

- `Sora/Sora.swift`: `webRTCConfiguration` 引数の型（`WebRTCConfiguration?`）と既定値（`nil`）の変更、指定値の正本への上書きと snapshot 生成への反映
- `Sora/ConnectionConfigurationSnapshot.swift`（または `Sora.connect` 内の反映点）: 上書きした値を snapshot 生成へ渡す経路
- `skills/sora-ios-sdk/SKILL.md`: `Sora.connect` の `webRTCConfiguration` 引数と `Configuration.webRTCConfiguration` の優先順位（引数が指定された場合に引数が優先）と、`Configuration.webRTCConfiguration` を使う推奨の記載
- `SoraTests`: 引数指定時の反映と引数省略時の既存挙動を検証するテスト
- `CHANGES.md`

## 完了条件

- `Sora.connect` の `webRTCConfiguration` に値を指定したとき、その値（ICE サーバー・ICE トランスポートポリシーを含む）が snapshot（`WebRTCConfigurationSnapshot`）へ反映され、接続プロセスが参照すること。offer 受信時にサーバー値で上書きされ得る点は、下記の既存挙動の維持に従う。
- 引数を省略したとき（`nil` 既定値）、`Configuration.webRTCConfiguration` を使う経路の挙動が変わらないこと（既存利用者の非退行）。
- 引数と `Configuration.webRTCConfiguration` の両方を設定した場合に、引数が優先されること。
- offer 受信時の ICE サーバー上書きと `Configuration.insecure` の反映（`isInsecure`）が維持されること。
- `skills/sora-ios-sdk/SKILL.md` に、`webRTCConfiguration` 引数と `Configuration.webRTCConfiguration` の優先順位が記載されていること。
- `CHANGES.md` に修正内容を追記していること。
- 追加したテストと既存テストがすべて成功すること。

## テスト方針

モックやスタブは使用しない。

- `Sora.connect` に `webRTCConfiguration` を指定したとき、snapshot の WebRTC 設定が指定値になることを検証する。
- 引数を省略したとき、`Configuration.webRTCConfiguration` の値が維持されることを検証する（既存利用者の非退行）。
- `Configuration.webRTCConfiguration` を設定した状態で引数を指定した場合に、引数が優先されることを検証する。

## 解決方法
