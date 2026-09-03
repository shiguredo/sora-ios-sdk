# 音声セッションのイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-audio-session-event-handlers
- Polished: 2026-09-03

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

アダプタは `Sora/Sora.swift` の `SoraRTCAudioSessionDelegateAdapter` クラスとして定義し、`Sora` クラスの `lazy var audioSessionDelegateAdapter` で生成している。`RTCAudioSession` への登録は `Sora` の `init` 内で `RTCAudioSession.add(_:)` を呼ぶこと、解除は `Sora` の `deinit` 内で `RTCAudioSession.remove(_:)` を呼ぶことで行っている。`RTCAudioSessionDelegate` には経路変更以外にも以下の通知が定義されているが、いずれも SDK 利用者へ公開されていない。

- `audioSessionDidBeginInterruption(_:)`
- `audioSessionDidEndInterruption(_:shouldResumeSession:)`
- `audioSessionDidStartPlayOrRecord(_:)`
- `audioSessionDidStopPlayOrRecord(_:)`
- `audioSession(_:didChangeCanPlayOrRecord:)`
- `audioSessionMediaServerTerminated(_:)`
- `audioSessionMediaServerReset(_:)`
- `audioSession(_:didSetActive:)`
- `audioSession(_:willSetActive:)`
- `audioSession(_:failedToSetActive:error:)`
- `audioSession(_:didChangeOutputVolume:)`
- `audioSession(_:didDetectPlayoutGlitch:)`
- `audioSession(_:audioUnitStartFailedWithError:)`

上記は libwebrtc m150.7871.3.0（`Package.swift` の `libwebrtcVersion`）の `RTCAudioSession.h` で定義されているものである。`audioSessionDidChangeRoute` は既に中継済みのため対象外とする。

## 設計方針

- `SoraRTCAudioSessionDelegateAdapter` を拡張し、経路変更を除く `RTCAudioSessionDelegate` の全メソッドを実装して各々を対応するクロージャへ転送する。
  - アダプタの初期化時に、各通知に対応するクロージャ（いずれも任意）をパラメータとして追加する。このため `SoraRTCAudioSessionDelegateAdapter.init` のシグネチャは拡張され、引数追加後の `init` 呼び出しはラベル付き引数形式になる。
  - 新しいイベントハンドラは `SoraHandlers` クラス（`Sora/Sora.swift` の `SoraHandlers`）に公開プロパティとして追加する（`onChangeAudioRoute` が `SoraHandlers` に定義されていることに揃える）。
  - `SoraRTCAudioSessionDelegateAdapter` の `init` はラベル付き引数形式で定義されているが、`Sora` クラスの `lazy var audioSessionDelegateAdapter` では trailing closure を使った呼び出し形式になっているため、引数追加後は trailing closure を廃止してラベル付き呼び出し形式に変更する必要がある。
- `RTCAudioSession` 側の delegate 保持は weak であるため、proxy は SDK 側で強参照しておく。既存の `audioSessionDelegateAdapter` がこの役割を担っているため、これを拡張する。
- 追加するクロージャはすべて任意（オプショナル）とし、既存の `onChangeAudioRoute` を壊さず後方互換性を保つ。
- 各コールバックの呼び出しスレッドは `RTCAudioSessionDelegate` の実装によって異なる（割り込み通知はシステム通知スレッド、再生録音通知は WebRTC スレッド等）。既存の `onChangeAudioRoute` と同様に、 SDK ではスレッドを特定せずそのまま転送する。利用者に対してはコールバック内で UI 操作を行う場合は `DispatchQueue.main.async` でラップすることをコメントで注記する。
- ハンドラの命名は `on + AudioSession + 動作の説明` の形式に統一する（例: `onAudioSessionBeginInterruption`、`onAudioSessionMediaServerReset`）。音声セッション関連ハンドラをグルーピングして IDE の補完で一覧しやすくするため、既存の `on + 動詞 + 名詞` パターン（`onChangeAudioRoute` 等）とは逆順にする。
- 各ハンドラのシグネチャは対応するデリゲートメソッドのシグネチャに準じる。`RTCAudioSession` を第一引数に持つデリゲートメソッドはハンドラにも `RTCAudioSession` を含め、既存の `onChangeAudioRoute` と統一した設計にする。
- 標準で提供される通知の中継に限定する。`RTCAudioSessionDelegate` が定義する全メソッドを中継対象とし、除外するメソッドは設けない。マイク起動通知や送受信のフレーム単位制御は libwebrtc 本体へのパッチが必要なため本 issue のスコープ外とする。
- 新規ハンドラはデリゲートメソッドの引数をクロージャへそのまま転送する。既存の `audioSessionDidChangeRoute` のような条件フィルタリング（`routeConfigurationChange` を無視する処理）は新規ハンドラでは行わない。

## テスト方針

モック・スタブは使用しない。

- `RTCAudioSessionDelegate` のコールバックは実機または Simulator での手動確認とする（割り込みシミュレーション等）。
- 既存のテストがすべてパスすること。

## 完了条件

- `SoraHandlers` に以下のイベントハンドラプロパティが追加されていること（各シグネチャは `RTCAudioSessionDelegate` の対応メソッドに準じる）:
  - `onAudioSessionBeginInterruption: (RTCAudioSession) -> Void`
  - `onAudioSessionEndInterruption: (RTCAudioSession, Bool) -> Void`（`shouldResumeSession`）
  - `onAudioSessionStartPlayOrRecord: (RTCAudioSession) -> Void`
  - `onAudioSessionStopPlayOrRecord: (RTCAudioSession) -> Void`
  - `onAudioSessionChangeCanPlayOrRecord: (RTCAudioSession, Bool) -> Void`
  - `onAudioSessionMediaServerTerminated: (RTCAudioSession) -> Void`
  - `onAudioSessionMediaServerReset: (RTCAudioSession) -> Void`
  - `onAudioSessionSetActive: (RTCAudioSession, Bool) -> Void`
  - `onAudioSessionWillSetActive: (RTCAudioSession, Bool) -> Void`
  - `onAudioSessionFailedToSetActive: (RTCAudioSession, Bool, Error) -> Void`
  - `onAudioSessionChangeOutputVolume: (RTCAudioSession, Float) -> Void`
  - `onAudioSessionDetectPlayoutGlitch: (RTCAudioSession, Int64) -> Void`
  - `onAudioSessionAudioUnitStartFailedWithError: (RTCAudioSession, Error) -> Void`
- `SoraRTCAudioSessionDelegateAdapter` が上記の各通知を対応するクロージャへ転送していること。
- `Sora` クラスの `lazy var audioSessionDelegateAdapter` が trailing closure を廃止してラベル付き呼び出し形式に変更されており、追加された引数を正しく渡していること（`SoraRTCAudioSessionDelegateAdapter.init` のシグネチャはクロージャの追加により拡張される）。
- 既存の `onChangeAudioRoute` の挙動が変わらないこと。
- 各ハンドラの公開プロパティに DocC 形式のコメントを記載していること（既存の `onChangeAudioRoute` の `///` 形式と `/// - parameter` によるパラメータ説明に揃えること）。
- 各ハンドラのコメントに「UI 操作を行う場合は `DispatchQueue.main.async` を使用すること」旨を記載していること。
- `SoraRTCAudioSessionDelegateAdapter` クラス定義の直前に書かれているフロー説明コメントが、新しいデリゲートメソッドを反映して更新されていること。
- ログメッセージ・エラーメッセージは英語、コメントは日本語で記述されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` が存在しない場合は新設すること）:
  ```
  - [ADD] 音声セッションのイベントハンドラを追加する
    - @voluntas
  ```

## 解決方法
