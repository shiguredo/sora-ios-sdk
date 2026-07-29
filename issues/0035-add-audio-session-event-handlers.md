# 音声セッションのイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-audio-session-event-handlers
- Polished: 2026-06-06

## 目的

libwebrtc の `RTCAudioSessionDelegate` が提供する各種通知（音声セッションの有効化・無効化、割り込みの開始・終了、メディアサーバーリセットなど）を SDK 利用者が受け取れるようにし、音声処理を扱いやすくする。現状は経路変更通知のみを中継しているため、他の通知も中継するイベントハンドラを追加する。

## 優先度根拠

- 電話着信やサイレントスイッチ等による音声セッション割り込み時に、アプリが音声処理を適切に停止・再開するためのイベントを受け取れず、利用者の実装に支障をきたすケースがある。
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

`Sora/Sora.swift:459` にアダプタを定義し、`Sora/Sora.swift:90` の `lazy var audioSessionDelegateAdapter` で生成している。`RTCAudioSession` への登録は `Sora/Sora.swift:118`、解除は `Sora/Sora.swift:122` で行っている。`RTCAudioSessionDelegate` には経路変更以外にも以下の通知が定義されているが、いずれも SDK 利用者へ公開されていない。

- `audioSessionDidBeginInterruption` / `audioSessionDidEndInterruption`
- `audioSessionDidStartPlayOrRecord` / `audioSessionDidStopPlayOrRecord`
- `audioSession(_:didChangeCanPlayOrRecord:)`
- `audioSessionMediaServerTerminated` / `audioSessionMediaServerReset`
- `audioSession(_:didSetActive:)`

## 設計方針

- `SoraRTCAudioSessionDelegateAdapter` を拡張し、経路変更以外の `RTCAudioSessionDelegate` メソッドを実装して各々を対応するクロージャへ転送する。
  - アダプタの初期化時に、各通知に対応するクロージャ（いずれも任意）をパラメータとして追加する。
  - 新しいイベントハンドラは `SoraHandlers` クラス（`Sora/Sora.swift:6`）に公開プロパティとして追加する（`onChangeAudioRoute` が `SoraHandlers` に定義されていることに揃える）。
  - `SoraRTCAudioSessionDelegateAdapter` の `init` はラベル付き引数形式で定義されているが、`Sora/Sora.swift:90` の `lazy var audioSessionDelegateAdapter` では trailing closure を使った呼び出し形式になっているため、引数追加後は trailing closure を廃止してラベル付き呼び出し形式に変更する必要がある。
- `RTCAudioSession` 側の delegate 保持は weak であるため、proxy は SDK 側で強参照しておく。既存の `audioSessionDelegateAdapter` がこの役割を担っているため、これを拡張する。
- 追加するクロージャはすべて任意（オプショナル）とし、既存の `onChangeAudioRoute` を壊さず後方互換性を保つ。
- 各コールバックの呼び出しスレッドは `RTCAudioSessionDelegate` の実装によって異なる（割り込み通知はシステム通知スレッド、再生録音通知は WebRTC スレッド等）。既存の `onChangeAudioRoute` と同様に、 SDK ではスレッドを特定せずそのまま転送する。利用者に対してはコールバック内で UI 操作を行う場合は `DispatchQueue.main.async` でラップすることをコメントで注記する。
- ハンドラの命名は `on + AudioSession + 動作の説明` の形式に統一する（例: `onAudioSessionBeginInterruption`、`onAudioSessionMediaServerReset`）。音声セッション関連ハンドラをグルーピングして IDE の補完で一覧しやすくするため、既存の `on + 動詞 + 名詞` パターン（`onChangeAudioRoute` 等）とは逆順にする。
- 各ハンドラのシグネチャは対応するデリゲートメソッドのシグネチャに準じる。`RTCAudioSession` を第一引数に持つデリゲートメソッドはハンドラにも `RTCAudioSession` を含め、既存の `onChangeAudioRoute` と統一した設計にする。
- 標準で提供される通知の中継に限定する。マイク起動通知や送受信のフレーム単位制御は libwebrtc 本体へのパッチが必要なため本 issue のスコープ外とする。
- 新規ハンドラはデリゲートメソッドの引数をクロージャへそのまま転送する。既存の `audioSessionDidChangeRoute` のような条件フィルタリング（`routeConfigurationChange` を無視する処理）は新規ハンドラでは行わない。

## テスト方針

モック・スタブは使用しない。

- `RTCAudioSessionDelegate` のコールバックは実機または Simulator での手動確認とする（割り込みシミュレーション等）。
- 既存のテストがすべてパスすること。

## 完了条件

- `SoraHandlers` に以下のイベントハンドラプロパティが追加されていること（ハンドラの正確なシグネチャは `WebRTC.xcframework` の `RTCAudioSessionDelegate` ヘッダーを確認して決定すること。現状セクションに列挙した以外のメソッドが存在する場合はそれらも含めるか除外するかを判断すること）:
  - `onAudioSessionBeginInterruption`
  - `onAudioSessionEndInterruption`（`shouldResumeSession` 等の引数をヘッダーで確認する）
  - `onAudioSessionStartPlayOrRecord`
  - `onAudioSessionStopPlayOrRecord`
  - `onAudioSessionChangeCanPlayOrRecord`
  - `onAudioSessionMediaServerTerminated`
  - `onAudioSessionMediaServerReset`
  - `onAudioSessionSetActive`
- `SoraRTCAudioSessionDelegateAdapter` が上記の各通知を対応するクロージャへ転送していること。
- `Sora/Sora.swift:90` の `lazy var audioSessionDelegateAdapter` が trailing closure を廃止してラベル付き呼び出し形式に変更されており、新しい引数を正しく渡していること（変更対象は呼び出し側のみ。`SoraRTCAudioSessionDelegateAdapter` の `init` シグネチャ自体は変更不要）。
- 既存の `onChangeAudioRoute` の挙動が変わらないこと。
- 各ハンドラの公開プロパティに DocC 形式のコメントを記載していること（既存の `onChangeAudioRoute` の `///` 形式と `/// - parameter` によるパラメータ説明に揃えること）。
- 各ハンドラのコメントに「UI 操作を行う場合は `DispatchQueue.main.async` を使用すること」旨を記載していること。
- `SoraRTCAudioSessionDelegateAdapter` のフローを説明するコメント（`Sora.swift:451` 付近）が新しいデリゲートメソッドを反映して更新されていること。
- ログメッセージ・エラーメッセージは英語、コメントは日本語で記述されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [ADD] 音声セッションのイベントハンドラを追加する
    - @voluntas
  ```

## 解決方法
