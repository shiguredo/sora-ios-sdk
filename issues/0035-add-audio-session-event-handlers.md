# 音声セッションのイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-audio-session-event-handlers

## 目的

libwebrtc の `RTCAudioSessionDelegate` が提供する各種通知（音声セッションの有効化・無効化、割り込みの開始・終了、メディアサーバーリセットなど）を SDK 利用者が受け取れるようにし、音声処理を扱いやすくする。現状は経路変更通知のみを中継しているため、他の通知も中継するイベントハンドラを追加する。

## 優先度根拠

- 音声まわりの制御性を高める利用者向けの機能追加であり、実用的な要望である。
- 緊急のバグ修正ではないため High ではなく Medium とする。

## 現状

実装されている音声セッション関連の中継は経路変更通知のみである。`SoraRTCAudioSessionDelegateAdapter` が `RTCAudioSessionDelegate` を実装し、`audioSessionDidChangeRoute(_:reason:previousRoute:)` のみを処理して `onChangeAudioRoute` を呼び出している。

```swift
private final class SoraRTCAudioSessionDelegateAdapter: NSObject, RTCAudioSessionDelegate {
  private let onChangeAudioRoute:
    (
      RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription
    ) -> Void
  ...
}
```

`Sora/Sora.swift:459` でアダプタを定義し、`Sora/Sora.swift:90` 付近で生成している。`RTCAudioSession` への登録・解除は `add` / `remove` で行っている。

```swift
RTCAudioSession.sharedInstance().add(audioSessionDelegateAdapter)
```

`Sora/Sora.swift:118` で登録し、`Sora/Sora.swift:122` で解除している。`RTCAudioSessionDelegate` には経路変更以外にも以下の通知が定義されているが、いずれも SDK 利用者へ公開されていない。

- `audioSessionDidBeginInterruption` / `audioSessionDidEndInterruption`
- `audioSessionDidStartPlayOrRecord` / `audioSessionDidStopPlayOrRecord`
- `audioSession(_:didChangeCanPlayOrRecord:)`
- `audioSessionMediaServerTerminated` / `audioSessionMediaServerReset`
- `audioSession(_:didSetActive:)`

## 設計方針

- `SoraRTCAudioSessionDelegateAdapter` を拡張し、経路変更以外の `RTCAudioSessionDelegate` メソッドを実装して各々を対応するクロージャへ転送する。
  - アダプタの初期化時に、各通知に対応するクロージャ（いずれも任意）を受け取れるようにする。
  - `Sora` クラス側に利用者へ公開する各イベントハンドラのプロパティを追加し、アダプタのクロージャへ接続する。
- `RTCAudioSession` 側の delegate 保持は weak であるため、proxy は SDK 側で強参照しておく。既存の `audioSessionDelegateAdapter` がこの役割を担っているため、これを拡張する。
- `addDelegate` は重複チェックをしていないため、proxy は 1 インスタンスのみ登録するよう注意する。
- 標準で提供される通知の中継に限定する。マイク起動通知や送受信のフレーム単位制御は libwebrtc 本体へのパッチが必要なため本 issue のスコープ外とする。
- 追加するクロージャはすべて任意（オプショナル）とし、既存の `onChangeAudioRoute` を壊さず後方互換性を保つ。

## 完了条件

- `RTCAudioSessionDelegate` が提供する主要な通知（割り込み開始・終了、再生録音の開始・停止、再生録音可否の変更、メディアサーバーの終了・リセット、アクティブ状態変更）を中継するクロージャが SDK 利用者へ公開されていること。
- proxy が `RTCAudioSession` へ重複登録されないことが保証されていること。
- 既存の `onChangeAudioRoute` の挙動が変わらないこと。
- ログメッセージ・エラーメッセージは英語、コメントは日本語で記述されていること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] 音声セッションのイベントハンドラを追加する
    - @担当者
  ```

## 解決方法
