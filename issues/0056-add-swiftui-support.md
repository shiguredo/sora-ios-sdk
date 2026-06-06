# SwiftUI サポートを完成させる

- Priority: Medium
- Created: 2026-06-06
- Completed:
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
