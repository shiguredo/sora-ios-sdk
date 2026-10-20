# Sora target の module 由来 add '@preconcurrency' 警告を解消する

- Created: 2026-09-28
- Completed: 2026-09-28
- Branch: feature/refactor-remove-sora-sendable-closure-captures (0173 に統合)

## 目的

Sora target に出る `add '@preconcurrency' to treat 'Sendable'-related errors from module ...' as warnings` 警告 4 件を解消し、`0108` の Sora target warnings-as-errors ゲートを有効化できる状態にする。

## 現状

2026-09-28 の Xcode 26.6 / Swift 6.3.3 で `Sora/` を Swift 6 言語モードで型検査すると、次の 4 件が出る。`-warnings-as-errors` では error になり、`#DeprecatedDeclaration` の除外設定では消えない。

- `Sora/PeerChannel.swift` の `import WebRTC` (module 'WebRTC')
- `Sora/MediaChannel.swift` の `import WebRTC` (module 'WebRTC')
- `Sora/NativePeerChannelFactory.swift` の `import WebRTC` (module 'WebRTC')
- `Sora/CameraVideoCapturer.swift` の `import WebRTC` (module 'AVFoundation'。AVFoundation は WebRTC 経由で取り込まれるため、診断は `import WebRTC` の行に出る)

`0108` の設計方針は「未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠してはならない」としており、`@preconcurrency import` を採る場合は境界注釈として正当化できる根拠が必要である。`0118` は E2E テストで `@preconcurrency import Accelerate` を境界注釈として許容した前例がある (外部 module の `Sendable` annotation が無いことによる境界)。

## 前提となる issue

- `0108` (open): Sora target の warnings-as-errors 化。本 issue の完了が前提になる。`0108` の残存警告の担当記述を本 issue へ更新する。
- `0118` (完了 2026-09-25): 外部 module の境界注釈を許容した前例。

## 設計方針

- まず、この警告が指す「module 由来の Sendable 診断」の実体を特定する (`@preconcurrency` を外した状態で `-warnings-as-errors` を付けたときの診断から、どの型をどこからどこへ渡すことで出ているかを確認する)。
- 次のいずれかを選び、判断と根拠を issue と PR に書く。
  - 外部 binary module (WebRTC / AVFoundation) が Swift 6 の `Sendable` annotation を持たないことによる境界であると確認できる場合は、該当する import に `@preconcurrency` を付けて境界注釈として明示する。この場合、隠している診断が他に無いことを `@preconcurrency` を外した一時ビルドで確認する
  - SDK 側の実装で解消できる場合は、`Sendable` な値型への写しや box で直し、`@preconcurrency` を付けない
- `@unchecked Sendable` の追加では解消しない (診断の出所は import 先の module)。
- 公開 API のシグネチャと baseline を変更しない (`Sora.connect` の handler 引数の executor 契約を doc に書く作業は `0110` の担当)。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` を追加する。

## スコープ外

- `#SendableClosureCaptures` 警告 25 件 (0173 完了前の実測 (2026-09-28)。うち 14 件は `0173` で解消済みで、完了時点の残件は 11 件。`0173` が 14 件 / SDK 内部インスタンスの capture 10 件 / `Sora/Utilities.swift` の 1 件)。
- `#DeprecatedDeclaration` 警告 (`0108` の除外設定と `0138`)。
- test target の warnings-as-errors ゲート (`0171`)。
- `sora-ios-sdk-samples` / `sora-ios-sdk-quickstart` の `@preconcurrency import Sora` の撤去 (`0124` / `0125`)。

## 変更対象

- `Sora/PeerChannel.swift` / `Sora/MediaChannel.swift` / `Sora/NativePeerChannelFactory.swift` / `Sora/CameraVideoCapturer.swift`: 該当 import の扱い (または診断の出所に応じた capture 側の修正)
- `CHANGES.md`: `## develop` の `### misc` の `[UPDATE]` (`0173` へ統合したため取り下げ)
- `issues/0108-update-swiftpm-language-mode.md`: 残存警告の担当を本 issue へ更新する (`0173` へ統合したため取り下げ)

## テスト方針

モックやスタブは使用しない。

- `Sora/` を Swift 6 言語モードで型検査し、`add '@preconcurrency'` 警告が 0 件になり、他の警告が増えていないこと (変更前後の log を比較する)。`-swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration` を付けた型検査でも error が出ないこと。
- `@preconcurrency` を付けた場合は、外した一時ビルドで「隠している Sendable 診断が他に無い」ことを確認する。
- `make build` が成功すること (SwiftPM の cache に書き込めない環境では `Sora/` の型検査で代替し、その旨を「解決方法」に記録する)。
- `SoraTests` が失敗 0 件であること。
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `add '@preconcurrency'` 警告が 0 件になり、`-warnings-as-errors` を付けても error が出ないこと。
- 選んだ対処の根拠 (境界注釈として許容できる理由、または code 側で解消した内容) が issue と PR に書かれ、`0108` の方針に反しないことが確認されていること。
- `SoraTests` と consumer package の build が成功すること。
- `issues/0108-update-swiftpm-language-mode.md` の残存警告の担当記述が本 issue へ更新されていること (`0173` へ統合したため取り下げ)。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` が追加されていること (`0173` へ統合したため取り下げ)。

## 解決方法

`0173` の (B) 群 (WebRTC / AVFoundation の型を capture していた 6 件を `Sendable` な値の capture へ置き換える作業) の完了に伴い、本 issue が対象としていた `add '@preconcurrency'` 警告 4 件は 0 件になった。本 issue では対応せず、`0173` へ統合して完了する。

- 実測 (2026-09-28、Xcode 26.6 / Swift 6.3.3): `Sora/` を Swift 6 言語モードで型検査すると `add '@preconcurrency'` の警告は 0 件 (`build/0173-typecheck-after.log`)。`grep -rn "@preconcurrency import" Sora/` も 0 件で、境界注釈としての `@preconcurrency` は追加していない
- 対象 4 件は `Sora/CameraVideoCapturer.swift` (AVFoundation 1) と `Sora/PeerChannel.swift` / `Sora/MediaChannel.swift` / `Sora/NativePeerChannelFactory.swift` (WebRTC 3) の import 行に出ていた。(B) 群の capture を `Sendable` な値へ置き換えたことで解消した
- `0173` の完了時点で残る `#SendableClosureCaptures` は 11 件 (`PeerChannel` 6 / `MediaChannel` 3 / `DataChannel` 1 / `Sora/Utilities.swift` 1)。`0108` の Sora target warnings-as-errors ゲートの有効化には、`0173` の `## スコープ外` が挙げた C 群 (SDK 内部インスタンスの capture) を扱う別 issue と `0115` (`Sora/Utilities.swift` の `Stopwatch` 削除) が引き続き必要である
