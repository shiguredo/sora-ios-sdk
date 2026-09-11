# Apple の非 Public API の使用を自動検出できるか調査する

- Created: 2026-09-11
- Completed: {YYYY-MM-DD}
- Branch: feature/investigate-non-public-api-detection
- Polished: {YYYY-MM-DD}

## 目的

App Store への提出時に非 Public API の使用が検出されるとリジェクトされる。SDK が依存する WebRTC フレームワークを含めて非 Public API の使用を自動検出できるかを調査し、判断内容を記録として残す。

## 現状

ビルドワークフローの `Check WebRTC Non-public API` ステップが、ビルドした `WebRTC.framework` のシンボルを `nm` で走査し、既知の非 Public API シンボル（`_kVTVideoEncoderSpecification_RequiredLowLatency`）が含まれていればビルドを失敗させている。

この検査は過去にリジェクトされた特定のパターンを検出するもので、未知の非 Public API の使用は検出できない。CI が通ったことだけでは App Store 審査の通過を保証できない。

## 調査結果

- `xcrun altool --validate-app` で App Store Connect にアプリを送信して検証する方法は、非 Public API の使用を検出できる可能性がある。ただし App Store Connect の認証情報が必要で、CI に組み込むには認証情報を安全に受け渡す仕組みが別途必要になる。
- バイナリのシンボル走査だけで未知の非 Public API を網羅的に検出する現実的な手段は見つからなかった。

## pending にした理由

非 Public API の検出を自動化するには App Store Connect の認証情報など外部依存が必要で、現状で CI に組み込める現実的な手段がない。既知パターンの検査は維持し、判断内容を記録として残すため pending とする。

## 解決方法

## Pending 解除条件

- App Store Connect の認証情報を CI に安全に渡せる仕組みが整った場合は、`xcrun altool --validate-app` による検証を検討する。
- 既知パターンの検査に加えて、非 Public API を検出できる現状より現実的な手段が見つかった場合は追加する。
