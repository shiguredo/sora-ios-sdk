# SwiftUI サポートを完成させる

- Priority: Medium
- Created: 2026-06-06
- Completed: 2026-09-24
- Model: Sonnet 4.6
- Branch: feature/add-swiftui-support
- Polished:

## 概要

SDK の SwiftUI サポートを完成させる。`SwiftUIVideoView` の追加は済んでいるが、`VideoView` の deprecated 化と `UIKitVideoView` への移行案内が未完了。SDK 側で SwiftUI との統合を適切にサポートする。

## 現状

`feature/swiftui` ブランチで以下の作業が進んでいる。

- `SwiftUIVideoView` の追加: 完了
- `VideoView` のエイリアスとして `UIKitVideoView` を定義: 完了
- `VideoView` を deprecated に指定し `UIKitVideoView` への変更を促す: **未完了**

## 対応内容

### SDK 側

- `VideoView` を `@available(*, deprecated, renamed: "UIKitVideoView")` として deprecated にマークする
- `UIKitVideoView` を正式な公開 API として整備する
- `SwiftUIVideoView` の API を安定させる（`VideoRenderer` プロトコルとの統合を確認する）
- `MainActor` との整合性を確認する（`0027` の VideoRenderer MainActor 移行との整合性）

## 設計上の注意

- UIKit による既存の実装は維持する。`UIKitVideoView` は `VideoView` の後継として同等の機能を保つ
- SwiftUI 対応は新規 API の追加であり、既存の UIKit ベースのコードに影響を与えない

## 根拠

SwiftUI は iOS 開発の主流になりつつあり、SDK が適切なサポートを提供しないと利用者が独自に対応策を講じる必要が生じる。`VideoView` の deprecated 化を明示することで将来の API 整理への移行をスムーズにする。

## 解決方法

「現状」の前提が現行リポジトリと一致しておらず、このまま実装すると存在しない API を対象にした誤った変更が入るため、陳腐化とした上で closed にする。

### 照合結果（実ファイル・git 履歴）

- `Sora/SwiftUIVideoView.swift` は、develop にも origin/master にも origin/release/2026.3.0 にも存在しない。`git log develop -- Sora/SwiftUIVideoView.swift` は空であり、develop へのマージ履歴が無い。全リモートブランチに対する `git grep` でも `Sora/SwiftUIVideoView.swift` は origin/feature/swiftui-view と origin/feature/poc-swift-ui-video-view にしか存在しない
- `UIKitVideoView` が `VideoView` のエイリアスとして定義された事実は、全ブランチ・全履歴を対象にした `git log --all -S UIKitVideoView` で確認できない。この文字列の該当コミットは `643a010`（Video を SwiftUIVideoView に名称変更）、`f1776d9`（rename 漏れの対応）、`0308873`（コードミス修正）で、いずれも feature/swiftui-view の WIP 中の SwiftUI ラッパー内部型としての一時的な名称であり、`VideoView` のエイリアスではない
- `feature/swiftui` ブランチの最終更新は 2022-05-19 の古いブランチであり、`Sora/SwiftUIVideoView.swift` も `UIKitVideoView` も含まない。現行アーキテクチャ（Swift 6 言語モード、StreamFrameOwner、MainActor 前提の renderer 設計）より大幅に古いため、「このブランチで作業が進んでいる」という記述も事実ではない
- CHANGES.md と README.md には SwiftUI 関連のエントリが存在せず、公開リリースに SwiftUI サポートが含まれたことがない
- 現行の映像描画 API は `VideoView`（`UIView`）が唯一の標準描画ビューである（`skills/sora-ios-sdk/SKILL.md` も `stream.videoRenderer = VideoView()` を前提にしている）。`UIKitVideoView` への移行を促す対象が存在しない

### 依存関係の確認

`0027`（VideoRenderer の MainActor 移行）は現在も open であり、`MainActorVideoRenderer` は develop に未実装である。本 issue は 0027 との整合性を「確認する」とだけ述べており、どちらを先行すべきかの依存関係が定義されていない。

### 残る実作業について

本 issue が指す作業（deprecated 化と `UIKitVideoView` への移行案内）は、上記のとおり対象が存在しないため実施できない。SwiftUI サポートを新たに追加する場合は、過去の POC 実装を前提とせず、`0027` や `0122`（legacy VideoRenderer の削除）をはじめとする現行の renderer API 方針と整合させた新規 issue として起票し直す必要がある。
