# iPad で UITextField にフォーカスした際に出力されるレイアウト制約の警告を調査する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/investigate-ipad-textfield-layout-warning
- Polished: {YYYY-MM-DD}
- Reporter: @miosakuma

## 目的

iPad でサンプルのチャンネル ID 入力欄にフォーカスすると Auto Layout の警告がログに出力される。原因を特定し、SDK またはサンプルで対応すべきかを判断する。

## 現状

サンプル集 `sora-ios-sdk-samples` の `VideoChatConfigViewController` が持つ `channelIdTextField` に iPad でフォーカスすると、次の警告がログに出力される。`h264ProfileLevelIdTextField` など他の `UITextField` でも同様に出力される。

```
[LayoutConstraints] Unable to simultaneously satisfy constraints.
...
(
    "<NSAutoresizingMaskLayoutConstraint:... _UIButtonBarButton:... height == 0   (active)>",
    "<NSLayoutConstraint:... _UIUCBKBSelectionBackground:... bottom == _UIButtonBarButton:... bottom - 6   (active)>",
    "<NSLayoutConstraint:... V:|-(6)-[_UIUCBKBSelectionBackground:...]   (active, names: '|':_UIButtonBarButton:... )>"
)

Will attempt to recover by breaking constraint
<NSLayoutConstraint:... _UIUCBKBSelectionBackground:... bottom == _UIButtonBarButton:... bottom - 6   (active)>
```

再現条件:

- iPad（報告時は iOS 14.2 以降）。iPhone SE (2nd) では発生しない。
- `UITextField` が first responder になるタイミング。

警告が出力されるだけで、文字入力や接続などの動作には影響しない。

## 調査結果

- 制約の衝突は `UITextInputAssistantItem`（iPad でキーボード上に表示されるショートカットバー）内部の `_UIButtonBarButton` と `_UIUCBKBSelectionBackground` の間で起きている。`_` で始まるクラスは UIKit の非公開ビューであり、アプリ側が設定した制約は関与しない。
- `UITextField` を 1 つだけ置いた最小のアプリでも同じ警告が出力されることが知られている。サンプルの storyboard の制約は原因ではない。
- iPhone では入力補助バーの構成が異なるため発生しない。
- 根本原因は Apple の UIKit 側にあり、SDK とサンプルのコードだけでは解消できない。

参考:

- Qiita「【バグ】iOS 14.2 以降の iPad で UITextField をフォーカスすると LayoutConstraints の警告が出る」: https://qiita.com/ryo_qiita/items/1b37bf3f035fe155b215
- Apple Developer Forums「Strange UIButtonBarButton layout errors on all textView, fields and searchbars on iPad only」: https://developer.apple.com/forums/thread/667441

## 回避策

次で発生を抑えられることが知られているが、いずれも Apple 側の不具合に対する回避であり、副作用がある。

- 対象の `UITextField` で `inputAssistantItem.leadingBarButtonGroups` と `inputAssistantItem.trailingBarButtonGroups` を空配列にする。
- `autocorrectionType` を `.no` にする。
- iPad のハードウェアキーボード接続を切り替える。

## pending にした理由

Apple の UIKit 内部の不具合であり、SDK 側で根本解決できない。回避策をサンプルへ適用するかは副作用を含めた方針判断が必要である。また、現行 iOS の iPad で再現するか、Apple 側で修正済みかが未確認である。対応の要否と方法を決められないため pending とする。

## 解決方法

## Pending 解除条件

- 現行 iOS の iPad で再現するかを確認する。
- 再現する場合は、回避策をサンプルへ適用するか、警告を許容して記録のみとするかを決定する。
- Apple 側で修正済みと確認できた場合は、確認結果を記録して closed にする。
